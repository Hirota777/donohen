-- ドノヘン？ v6: anonymous Auth, private room data, rate limits and room expiry.
-- Existing legacy rooms are not trusted or claimed by their public IDs. Start a new room.
BEGIN;
-- Spectrum Party online backend
-- Run the entire file in Supabase Dashboard -> SQL Editor.
-- The public game state contains no unrevealed target. Targets are kept in a table
-- with RLS enabled and no client policies. All mutations happen through SECURITY DEFINER RPCs.

create table if not exists public.spectrum_rooms (
  room_code text primary key check (room_code ~ '^[A-Z0-9]{4,8}$'),
  public_state jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.spectrum_rooms enable row level security;
revoke all on public.spectrum_rooms from anon, authenticated;
drop policy if exists "public can read spectrum rooms" on public.spectrum_rooms;


create table if not exists public.spectrum_room_secrets (
  room_code text primary key references public.spectrum_rooms(room_code) on delete cascade,
  target integer not null check (target between 0 and 100),
  target_player_id text not null
);
alter table public.spectrum_room_secrets enable row level security;
revoke all on public.spectrum_room_secrets from anon, authenticated;

-- Each participant submits one independent answer per round.
-- Guesses cannot be read directly by browsers and remain secret until reveal.
create table if not exists public.spectrum_player_guesses (
  room_code text not null references public.spectrum_rooms(room_code) on delete cascade,
  round_number integer not null check (round_number between 1 and 36),
  player_id text not null,
  guess integer not null check (guess between 0 and 100),
  created_at timestamptz not null default now(),
  primary key (room_code, round_number, player_id)
);
alter table public.spectrum_player_guesses drop constraint if exists spectrum_player_guesses_round_number_check;
alter table public.spectrum_player_guesses add constraint spectrum_player_guesses_round_number_check check (round_number between 1 and 36);
alter table public.spectrum_player_guesses enable row level security;
revoke all on public.spectrum_player_guesses from anon, authenticated;


-- The public API is restricted to authenticated Supabase users (including anonymous Auth).
alter table public.spectrum_rooms add column if not exists security_version integer not null default 1;
alter table public.spectrum_rooms add column if not exists creator_id uuid;
alter table public.spectrum_rooms add column if not exists expires_at timestamptz not null default (now() + interval '2 hours');
create index if not exists spectrum_rooms_expiry_idx on public.spectrum_rooms(expires_at);

create table if not exists public.spectrum_memberships (
  room_code text not null references public.spectrum_rooms(room_code) on delete cascade,
  user_id uuid not null,
  primary key (room_code,user_id)
);
create index if not exists spectrum_memberships_user_idx on public.spectrum_memberships(user_id);
alter table public.spectrum_memberships enable row level security;

create table if not exists public.spectrum_request_limits (
  subject text not null,
  bucket text not null,
  window_start timestamptz not null,
  attempts integer not null default 0,
  primary key (subject,bucket)
);
alter table public.spectrum_request_limits enable row level security;

-- Private, atomic limiter. Denials are returned by wrappers, not raised, so failed
-- guesses/joins also consume their request budget after the RPC transaction commits.
create or replace function public.spectrum_take_limit(p_subject text,p_bucket text,p_max integer,p_seconds integer)
returns boolean language plpgsql security definer set search_path = pg_catalog,public
as $$
declare count_now integer; at_time timestamptz := clock_timestamp();
begin
  insert into public.spectrum_request_limits as limits(subject,bucket,window_start,attempts)
  values(p_subject,p_bucket,at_time,1)
  on conflict(subject,bucket) do update set
    window_start=case when limits.window_start <= at_time-make_interval(secs=>p_seconds) then at_time else limits.window_start end,
    attempts=case when limits.window_start <= at_time-make_interval(secs=>p_seconds) then 1 else least(limits.attempts+1,p_max+1) end
  returning attempts into count_now;
  return count_now <= p_max;
end $$;

create or replace function public.spectrum_cleanup_expired()
returns integer language plpgsql security definer set search_path = pg_catalog,public
as $$
declare removed integer;
begin
  delete from public.spectrum_rooms where expires_at <= clock_timestamp();
  get diagnostics removed = row_count;
  delete from public.spectrum_request_limits where window_start < clock_timestamp()-interval '1 day';
  return removed;
end $$;

create or replace function public.spectrum_check_identity(p_player_id text)
returns uuid language plpgsql stable security definer set search_path = pg_catalog,public
as $$
declare caller uuid := auth.uid();
begin
  if caller is null or p_player_id is distinct from caller::text then
    raise exception using errcode='42501',message='本人を確認できません。画面を再読み込みしてください。';
  end if;
  return caller;
end $$;

create or replace function public.spectrum_check_member(p_room_code text,p_user_id uuid)
returns void language plpgsql security definer set search_path = pg_catalog,public
as $$
begin
  if p_room_code is null or p_room_code !~ '^[A-Z2-9]{8}$' then
    raise exception using errcode='42501',message='この部屋には入れません。コードを確認してください。';
  end if;
  if not exists(
    select 1 from public.spectrum_rooms r join public.spectrum_memberships m using(room_code)
    where r.room_code=p_room_code and m.user_id=p_user_id
      and r.security_version=6 and r.expires_at>clock_timestamp()
      and r.created_at>clock_timestamp()-interval '24 hours'
  ) then
    raise exception using errcode='42501',message='この部屋には入れません。コードを確認して参加し直してください。';
  end if;
end $$;

create or replace function public.spectrum_valid_prompt(p_prompt jsonb)
returns boolean language sql immutable set search_path = pg_catalog,public
as $$
  select coalesce(jsonb_typeof(p_prompt)='object'
    and jsonb_typeof(p_prompt->'left')='string' and jsonb_typeof(p_prompt->'right')='string'
    and length(trim(p_prompt->>'left')) between 1 and 50
    and length(trim(p_prompt->>'right')) between 1 and 50
    and octet_length(p_prompt::text)<=1000,false)
$$;

create or replace function public.spectrum_protocol()
returns jsonb language sql stable security definer set search_path = pg_catalog,public
as $$ select jsonb_build_object('version',6,'authRequired',true) $$;

create or replace function public.spectrum_v6_create_impl(
  p_room_code text, p_player_id text, p_player_name text, p_prompt jsonb, p_target integer
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare s jsonb; server_target integer := floor(random()*71)::integer+15;
begin
  if p_room_code !~ '^[A-Z0-9]{4,8}$' then raise exception 'ルームコードが不正です'; end if;
  if p_player_id is null or length(p_player_id) > 80 then raise exception 'プレイヤーIDが不正です'; end if;
  if length(trim(p_player_name)) < 1 or length(p_player_name) > 18 then raise exception '名前は1〜18文字にしてください'; end if;
  -- p_target remains only for backwards-compatible RPC arguments.
  -- The actual target is generated server-side, not accepted from a client.
  s := jsonb_build_object(
    'room', p_room_code, 'hostId', p_player_id,
    'players', jsonb_build_array(jsonb_build_object('id',p_player_id,'name',trim(p_player_name),'score',0)),
    'securityVersion',6,'rulesVersion',2,'roundsPerPlayer',1,'round',1,'cluePlayerId',p_player_id,'prompt',p_prompt,'promptHistory','[]'::jsonb,'clue','','phase','lobby',
    'answeredPlayerIds','[]'::jsonb,'lastRoundResults','[]'::jsonb,'targetRevealed',null,'updatedAt',now()
  );
  insert into public.spectrum_rooms(room_code,public_state,security_version,creator_id,expires_at) values(p_room_code,s,6,auth.uid(),now()+interval '2 hours');
  insert into public.spectrum_room_secrets(room_code,target,target_player_id) values(p_room_code,server_target,p_player_id);
  return jsonb_build_object('state',s,'target',server_target,'ownGuess',null);
end $$;

create or replace function public.spectrum_v6_join_impl(
  p_room_code text, p_player_id text, p_player_name text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare s jsonb; ps jsonb; result_target integer := null;
begin
  select public_state into s from public.spectrum_rooms where room_code=upper(trim(p_room_code)) for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if length(trim(p_player_name)) < 1 or length(p_player_name) > 18 then raise exception '名前は1〜18文字にしてください'; end if;
  if s->>'phase' <> 'lobby' then raise exception 'ゲーム開始後は参加できません'; end if;
  ps := s->'players';
  if jsonb_array_length(ps) >= 12 then raise exception 'このルームは満員です（最大12人）'; end if;
  if exists(select 1 from jsonb_array_elements(ps) p where p->>'id'=p_player_id) then raise exception 'このプレイヤーIDは既に参加しています'; end if;
  ps := ps || jsonb_build_array(jsonb_build_object('id',p_player_id,'name',trim(p_player_name),'score',0));
  s := jsonb_set(s,'{players}',ps);
  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=upper(trim(p_room_code));
  if s->>'cluePlayerId'=p_player_id and s->>'phase'='clue' then
    select target into result_target from public.spectrum_room_secrets where room_code=upper(trim(p_room_code));
  end if;
  return jsonb_build_object('state',s,'target',result_target);
end $$;

create or replace function public.spectrum_v6_get_impl(
  p_room_code text, p_player_id text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare s jsonb; t integer := null; own_answer integer := null;
begin
  select public_state into s from public.spectrum_rooms where room_code=upper(trim(p_room_code));
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') p where p->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;
  if s->>'cluePlayerId'=p_player_id and s->>'phase'='clue' then
    select target into t from public.spectrum_room_secrets where room_code=upper(trim(p_room_code));
  end if;
  if s->>'phase' = 'guess' then
    select guess into own_answer from public.spectrum_player_guesses
      where room_code=upper(trim(p_room_code))
        and round_number=(s->>'round')::integer and player_id=p_player_id;
  end if;
  return jsonb_build_object('state',s,'target',t,'ownGuess',own_answer);
end $$;

create or replace function public.spectrum_v6_action_impl(
  p_room_code text, p_player_id text, p_action text, p_payload jsonb default '{}'::jsonb
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  s jsonb; ps jsonb; sec record; next_id text; next_target integer;
  g integer; dist integer; pts integer; item jsonb; new_players jsonb;
  t integer := null; own_answer integer := null;
  room text := upper(trim(p_room_code));
  results jsonb := '[]'::jsonb;
  answered_ids jsonb;
  eligible_count integer;
  total_guess_points integer := 0;
  hint_points integer := 0;
  guesser_count integer := 0;
  turns integer; schedule jsonb; match_rounds integer;
begin
  -- A row-level lock serializes room updates and prevents concurrent double submissions.
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') p where p->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;

  if p_action='settings' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが変更できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception '待機室で変更してください'; end if;
    if coalesce(p_payload->>'roundsPerPlayer','') !~ '^[1-3]$' then raise exception '回数は1〜3回です'; end if;
    s := jsonb_set(s,'{roundsPerPlayer}',to_jsonb((p_payload->>'roundsPerPlayer')::integer),true);
  elsif p_action='start' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが開始できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception 'ゲームはすでに始まっています'; end if;
    if jsonb_array_length(s->'players') < 2 then raise exception '2人以上で開始してください'; end if;
    -- Freeze the turn order at match start; every member is clue-giver 1–3 times.
    turns := coalesce((s->>'roundsPerPlayer')::integer,1);
    if turns not between 1 and 3 then raise exception '回数は1〜3回です'; end if;
    ps := '[]'::jsonb;
    for item in select value from jsonb_array_elements(s->'players') loop
      ps := ps || jsonb_build_array(jsonb_set(item,'{score}',to_jsonb(0)));
    end loop;
    select jsonb_agg(value->>'id' order by cycle,ord) into schedule
      from generate_series(1,turns) as cycles(cycle)
      cross join jsonb_array_elements(ps) with ordinality as members(value,ord);
    next_id := schedule->>0;
    s := jsonb_set(s,'{rulesVersion}',to_jsonb(2),true);
    s := jsonb_set(s,'{matchId}',to_jsonb(now()::text),true);
    s := jsonb_set(s,'{clueSchedule}',schedule,true);
    s := jsonb_set(s,'{totalRounds}',to_jsonb(jsonb_array_length(schedule)),true);
    s := jsonb_set(s,'{round}',to_jsonb(1));
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(next_id));
    s := jsonb_set(s,'{clue}',to_jsonb(''::text));
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    delete from public.spectrum_player_guesses where room_code=room;
    update public.spectrum_room_secrets set target=floor(random()*71)::integer+15,target_player_id=next_id where room_code=room;
    s := jsonb_set(s,'{players}',ps);
    s := jsonb_set(s,'{phase}',to_jsonb('clue'::text));
    s := jsonb_set(s,'{prompt}',coalesce(p_payload->'prompt',jsonb_build_object('left','冷たい','right','熱い')));
    s := jsonb_set(s,'{promptHistory}',jsonb_build_array(s->'prompt'),true);
  elsif p_action='clue' then
    if s->>'cluePlayerId' <> p_player_id or s->>'phase' <> 'clue' then raise exception '今はヒントを送信できません'; end if;
    if length(trim(coalesce(p_payload->>'clue',''))) < 1 or length(p_payload->>'clue') > 100 then raise exception 'ヒントは1〜100文字にしてください'; end if;
    s := jsonb_set(s,'{clue}',to_jsonb(trim(p_payload->>'clue')));
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{phase}',to_jsonb('guess'::text));
  elsif p_action='guess' then
    if s->>'phase' <> 'guess' then raise exception '今は予想できません'; end if;
    if s->>'cluePlayerId' = p_player_id then raise exception 'ヒント役は予想できません'; end if;
    if coalesce(p_payload->>'guess','') !~ '^(100|[1-9]?[0-9])$' then raise exception '予想値は0〜100の整数にしてください'; end if;
    g := (p_payload->>'guess')::integer;
    -- Database uniqueness allows one answer per person per round, even after refresh.
    insert into public.spectrum_player_guesses(room_code,round_number,player_id,guess)
      values (room,(s->>'round')::integer,p_player_id,g);
    answered_ids := coalesce(s->'answeredPlayerIds','[]'::jsonb) || to_jsonb(p_player_id);
    s := jsonb_set(s,'{answeredPlayerIds}',answered_ids,true);
    eligible_count := jsonb_array_length(s->'players')-1;
    if jsonb_array_length(answered_ids) = eligible_count then
      s := jsonb_set(s,'{phase}',to_jsonb('reveal'::text));
    end if;
    own_answer := g;
  elsif p_action='reveal' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが答えを公開できます'; end if;
    if s->>'phase' <> 'reveal' then raise exception '全員の回答を待ってください'; end if;
    if s->'targetRevealed' is distinct from 'null'::jsonb then raise exception '答えは公開済みです'; end if;
    select target,target_player_id into sec from public.spectrum_room_secrets where room_code=room;
    new_players := '[]'::jsonb;
    for item in select value from jsonb_array_elements(s->'players') loop
      if item->>'id' <> s->>'cluePlayerId' then
        select guess into g from public.spectrum_player_guesses
          where room_code=room and round_number=(s->>'round')::integer and player_id=item->>'id';
        if not found then raise exception '一部の回答がありません'; end if;
        dist := abs(sec.target - g);
        pts := case when dist=0 then 5 when dist<=2 then 4 when dist<=4 then 3 when dist<=6 then 2 when dist<=8 then 1 else 0 end;
        total_guess_points := total_guess_points + pts;
        guesser_count := guesser_count + 1;
        item := jsonb_set(item,'{score}',to_jsonb(coalesce((item->>'score')::integer,0)+pts));
        results := results || jsonb_build_array(jsonb_build_object('playerId',item->>'id','guess',g,'distance',dist,'points',pts));
      end if;
      new_players := new_players || jsonb_build_array(item);
    end loop;
    -- PostgreSQL round() rounds positive halves upward (e.g. 2.5 -> 3).
    hint_points := case when guesser_count > 0 then round(total_guess_points::numeric / guesser_count)::integer else 0 end;
    ps := '[]'::jsonb;
    for item in select value from jsonb_array_elements(new_players) loop
      if item->>'id' = s->>'cluePlayerId' then
        item := jsonb_set(item,'{score}',to_jsonb(coalesce((item->>'score')::integer,0)+hint_points));
      end if;
      ps := ps || jsonb_build_array(item);
    end loop;
    s := jsonb_set(s,'{players}',ps);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(hint_points),true);
    s := jsonb_set(s,'{lastRoundResults}',results,true);
    s := jsonb_set(s,'{targetRevealed}',to_jsonb(sec.target));
    if (s->>'round')::integer >= coalesce((s->>'totalRounds')::integer,5) then
      s := jsonb_set(s,'{phase}',to_jsonb('finished'::text));
    end if;
  elsif p_action='restart' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが再スタートできます'; end if;
    if s->>'phase' <> 'finished' then raise exception '終了後に再スタートできます'; end if;
    delete from public.spectrum_player_guesses where room_code=room;
    ps := '[]'::jsonb;
    for item in select value from jsonb_array_elements(s->'players') loop
      ps := ps || jsonb_build_array(jsonb_set(item,'{score}',to_jsonb(0)));
    end loop;
    next_id := ps->0->>'id';
    next_target := floor(random()*71)::integer + 15;
    update public.spectrum_room_secrets set target=next_target,target_player_id=next_id where room_code=room;
    s := jsonb_set(s,'{players}',ps);
    s := jsonb_set(s,'{round}',to_jsonb(1));
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(next_id));
    s := jsonb_set(s,'{prompt}',coalesce(p_payload->'prompt',jsonb_build_object('left','冷たい','right','熱い')));
    s := jsonb_set(s,'{clue}',to_jsonb(''::text));
    s := jsonb_set(s,'{phase}',to_jsonb('lobby'::text));
    s := s - 'totalRounds' - 'clueSchedule';
    s := jsonb_set(s,'{promptHistory}','[]'::jsonb,true);
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
  elsif p_action='next_round' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが次のラウンドを開始できます'; end if;
    if s->>'phase' <> 'reveal' or s->'targetRevealed' is not distinct from 'null'::jsonb then raise exception '答えを公開してから次へ進んでください'; end if;
    if (s->>'round')::integer >= coalesce((s->>'totalRounds')::integer,5) then raise exception '全ラウンドが終了しています'; end if;
    ps := s->'players';
    if s ? 'clueSchedule' and jsonb_array_length(s->'clueSchedule') > 0 then
      next_id := s->'clueSchedule'->>((s->>'round')::integer);
    else
      -- Existing matches from v4 retain their original round count.
      select (value->>'id') into next_id
        from jsonb_array_elements(ps) with ordinality as p(value,ord)
        where ord = ((select ord from jsonb_array_elements(ps) with ordinality as q(value,ord) where value->>'id'=s->>'cluePlayerId') % jsonb_array_length(ps)) + 1;
    end if;
    next_target := floor(random()*71)::integer + 15;
    update public.spectrum_room_secrets set target=next_target,target_player_id=next_id where room_code=room;
    s := jsonb_set(s,'{round}',to_jsonb((s->>'round')::integer+1));
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(next_id));
    if exists(select 1 from jsonb_array_elements(coalesce(s->'promptHistory','[]'::jsonb)) as used where used->>'left'=p_payload->'prompt'->>'left' and used->>'right'=p_payload->'prompt'->>'right') then
      raise exception 'このゲームですでに使われたお題です';
    end if;
    s := jsonb_set(s,'{prompt}',coalesce(p_payload->'prompt',jsonb_build_object('left','冷たい','right','熱い')));
    s := jsonb_set(s,'{promptHistory}',coalesce(s->'promptHistory','[]'::jsonb) || jsonb_build_array(s->'prompt'),true);
    s := jsonb_set(s,'{clue}',to_jsonb(''::text));
    s := jsonb_set(s,'{phase}',to_jsonb('clue'::text));
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
  else
    raise exception '不明な操作です';
  end if;

  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=room;
  if s->>'cluePlayerId'=p_player_id and s->>'phase'='clue' then
    select target into t from public.spectrum_room_secrets where room_code=room;
  end if;
  return jsonb_build_object('state',s,'target',t,'ownGuess',own_answer);
end $$;

create or replace function public.spectrum_v6_leave_impl(p_room_code text, p_player_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  room text := upper(trim(p_room_code)); s jsonb; ps jsonb := '[]'::jsonb;
  item jsonb; new_host text; new_clue text; remaining integer;
  did_clue_leave boolean; schedule jsonb; current_round integer; answered jsonb := '[]'::jsonb;
begin
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') v where v->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;
  did_clue_leave := s->>'cluePlayerId' = p_player_id;
  for item in select value from jsonb_array_elements(s->'players') loop
    if item->>'id' <> p_player_id then ps := ps || jsonb_build_array(item); end if;
  end loop;
  remaining := jsonb_array_length(ps);
  delete from public.spectrum_player_guesses where room_code=room and player_id=p_player_id;
  if remaining = 0 then
    delete from public.spectrum_rooms where room_code=room;
    return jsonb_build_object('left',true,'closed',true);
  end if;
  s := jsonb_set(s,'{players}',ps);
  new_host := ps->0->>'id';
  if s->>'hostId'=p_player_id then s := jsonb_set(s,'{hostId}',to_jsonb(new_host)); end if;

  -- Remove an exiting member's unplayed turns, retaining completed rounds.
  if s ? 'clueSchedule' and s->>'phase' not in ('lobby','finished') then
    current_round := (s->>'round')::integer;
    select coalesce(jsonb_agg(value order by ord),'[]'::jsonb) into schedule
      from jsonb_array_elements(s->'clueSchedule') with ordinality as turns(value,ord)
      where ord < current_round
        or (ord = current_round and s->>'phase' = 'reveal')
        or value #>> '{}' <> p_player_id;
    if jsonb_array_length(schedule) < current_round then
      schedule := schedule || jsonb_build_array(new_host);
    end if;
    s := jsonb_set(s,'{clueSchedule}',schedule,true);
    s := jsonb_set(s,'{totalRounds}',to_jsonb(jsonb_array_length(schedule)),true);
  end if;

  if remaining < 2 and s->>'phase' not in ('lobby','finished') then
    -- A match requires >=2 players. Pause by returning to the lobby and reset
    -- the incomplete match; scores are retained until host starts again.
    s := jsonb_set(s,'{phase}',to_jsonb('lobby'::text));
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(new_host));
    s := jsonb_set(s,'{round}',to_jsonb(1));
    s := jsonb_set(s,'{clue}',to_jsonb(''::text));
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
    s := jsonb_set(s,'{promptHistory}','[]'::jsonb);
    s := s - 'totalRounds' - 'clueSchedule';
    delete from public.spectrum_player_guesses where room_code=room;
    update public.spectrum_room_secrets set target=floor(random()*71)::integer+15,target_player_id=new_host where room_code=room;
  elsif did_clue_leave and s->>'phase' in ('clue','guess') then
    -- A round without a clue-giver cannot be completed. Restart only that round.
    new_clue := coalesce(s->'clueSchedule'->>((s->>'round')::integer-1),new_host);
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(new_clue));
    s := jsonb_set(s,'{phase}',to_jsonb('clue'::text));
    s := jsonb_set(s,'{clue}',to_jsonb(''::text));
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
    delete from public.spectrum_player_guesses where room_code=room and round_number=(s->>'round')::integer;
    update public.spectrum_room_secrets set target=floor(random()*71)::integer+15,target_player_id=new_clue where room_code=room;
  else
    if did_clue_leave then s := jsonb_set(s,'{cluePlayerId}',to_jsonb(new_host)); end if;
    for item in select value from jsonb_array_elements(coalesce(s->'answeredPlayerIds','[]'::jsonb)) loop
      if item #>> '{}' <> p_player_id then answered := answered || jsonb_build_array(item); end if;
    end loop;
    s := jsonb_set(s,'{answeredPlayerIds}',answered);
    if s->>'phase'='reveal' and s->'targetRevealed' is distinct from 'null'::jsonb
       and (s->>'round')::integer >= coalesce((s->>'totalRounds')::integer,5) then
      s := jsonb_set(s,'{phase}',to_jsonb('finished'::text));
    end if;
    if s->>'phase'='guess' and jsonb_array_length(answered)>=remaining-1 then
      s := jsonb_set(s,'{phase}',to_jsonb('reveal'::text));
    end if;
  end if;
  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=room;
  return jsonb_build_object('left',true,'closed',false);
end $$;
create or replace function public.spectrum_create_room(
 p_room_code text,p_player_id text,p_player_name text,p_prompt jsonb,p_target integer
) returns jsonb language plpgsql security definer set search_path = pg_catalog,public
as $$
declare caller uuid; result jsonb;
begin
  caller := public.spectrum_check_identity(p_player_id);
  if not public.spectrum_take_limit(caller::text,'create',5,600)
     or not public.spectrum_take_limit('global','create',40,60) then
    return jsonb_build_object('error',jsonb_build_object('code','RATE_LIMIT','message','部屋を作る回数が多くなっています。少し待って試してください。'));
  end if;
  perform public.spectrum_cleanup_expired();
  begin
    if p_room_code is null or p_room_code !~ '^[A-Z2-9]{8}$'
      or p_player_name is null or length(trim(p_player_name)) not between 1 and 18
      or not public.spectrum_valid_prompt(p_prompt) then
      raise exception '入力内容を確認してください。';
    end if;
    -- Global capacity limits bound room growth even across newly created identities.
    perform pg_advisory_xact_lock(hashtextextended(caller::text,0));
    perform pg_advisory_xact_lock(604063);
    if (select count(*) from public.spectrum_rooms where security_version=6 and expires_at>clock_timestamp())>=500 then
      raise exception '部屋が混み合っています。時間をおいて試してください。';
    end if;
    if (select count(*) from public.spectrum_memberships m join public.spectrum_rooms r using(room_code)
        where m.user_id=caller and r.expires_at>clock_timestamp())>=3 then
      raise exception '参加中の部屋を退出してから試してください。';
    end if;
    result := public.spectrum_v6_create_impl(p_room_code,p_player_id,p_player_name,p_prompt,p_target);
    insert into public.spectrum_memberships(room_code,user_id) values(p_room_code,caller);
    return result;
  exception when unique_violation then
    return jsonb_build_object('error',jsonb_build_object('code','ROOM_CODE_COLLISION','message','部屋を作り直してください。'));
  when others then
    return jsonb_build_object('error',jsonb_build_object('code','CREATE_FAILED','message',case
      when sqlstate='P0001' then sqlerrm else '部屋を作れませんでした。もう一度試してください。' end));
  end;
end $$;

create or replace function public.spectrum_join_room(p_room_code text,p_player_id text,p_player_name text)
returns jsonb language plpgsql security definer set search_path = pg_catalog,public
as $$
declare caller uuid; room text := upper(trim(p_room_code)); result jsonb;
begin
  caller := public.spectrum_check_identity(p_player_id);
  if not public.spectrum_take_limit(caller::text,'join',10,60)
     or not public.spectrum_take_limit('global','join',300,60) then
    return jsonb_build_object('error',jsonb_build_object('code','RATE_LIMIT','message','参加を試す回数が多くなっています。少し待って試してください。'));
  end if;
  perform public.spectrum_cleanup_expired();
  begin
    if room is null or room !~ '^[A-Z2-9]{8}$' or p_player_name is null
       or length(trim(p_player_name)) not between 1 and 18 then raise exception '入力内容を確認してください。'; end if;
    -- Serialize membership changes for this identity to keep the 3-room quota atomic.
    perform pg_advisory_xact_lock(hashtextextended(caller::text,0));
    perform 1 from public.spectrum_rooms where room_code=room and security_version=6
      and expires_at>clock_timestamp() and created_at>clock_timestamp()-interval '24 hours' for update;
    if not found then raise exception 'この部屋には入れません。コードを確認してください。'; end if;
    if exists(select 1 from public.spectrum_memberships where room_code=room and user_id=caller) then
      return public.spectrum_v6_get_impl(room,p_player_id);
    end if;
    if (select count(*) from public.spectrum_memberships m join public.spectrum_rooms r using(room_code)
        where m.user_id=caller and r.expires_at>clock_timestamp())>=3 then
      raise exception '参加中の部屋を退出してから試してください。';
    end if;
    result := public.spectrum_v6_join_impl(room,p_player_id,p_player_name);
    insert into public.spectrum_memberships(room_code,user_id) values(room,caller);
    return result;
  exception when others then
    return jsonb_build_object('error',jsonb_build_object('code','JOIN_FAILED','message',case
      when sqlstate='P0001' then sqlerrm else '参加できませんでした。もう一度試してください。' end));
  end;
end $$;

create or replace function public.spectrum_get_room(p_room_code text,p_player_id text)
returns jsonb language plpgsql security definer set search_path = pg_catalog,public
as $$
declare caller uuid; room text := upper(trim(p_room_code));
begin
  caller := public.spectrum_check_identity(p_player_id);
  if not public.spectrum_take_limit(caller::text,'read',180,60) then
    return jsonb_build_object('error',jsonb_build_object('code','RATE_LIMIT','message','少し待ってから画面を開き直してください。'));
  end if;
  begin
    perform public.spectrum_check_member(room,caller);
    -- Touch at most once per ten minutes, never on every poll. Finished rooms expire in 30m.
    update public.spectrum_rooms set expires_at=least(created_at+interval '24 hours',clock_timestamp()+interval '2 hours')
      where room_code=room and public_state->>'phase'<>'finished'
        and expires_at<clock_timestamp()+interval '110 minutes';
    return public.spectrum_v6_get_impl(room,p_player_id);
  exception when insufficient_privilege then
    return jsonb_build_object('error',jsonb_build_object('code','ROOM_UNAVAILABLE','message','この部屋には戻れません。参加し直してください。'));
  end;
end $$;

create or replace function public.spectrum_game_action(
 p_room_code text,p_player_id text,p_action text,p_payload jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = pg_catalog,public
as $$
declare caller uuid; room text := upper(trim(p_room_code)); result jsonb;
begin
  caller := public.spectrum_check_identity(p_player_id);
  if not public.spectrum_take_limit(caller::text,'action',60,60) then
    return jsonb_build_object('error',jsonb_build_object('code','RATE_LIMIT','message','操作が続いています。少し待って試してください。'));
  end if;
  begin
    perform public.spectrum_check_member(room,caller);
    if p_action is null or p_action not in ('settings','start','clue','guess','reveal','restart','next_round')
      or p_payload is null or jsonb_typeof(p_payload)<>'object' or octet_length(p_payload::text)>2000 then
      raise exception '入力内容を確認してください。';
    end if;
    if p_action in ('start','restart','next_round') and not public.spectrum_valid_prompt(p_payload->'prompt') then
      raise exception 'お題の形式が正しくありません。画面を再読み込みしてください。';
    end if;
    if p_action='clue' and (jsonb_typeof(p_payload->'clue') is distinct from 'string'
      or length(trim(p_payload->>'clue')) not between 1 and 100) then
      raise exception 'ヒントは1〜100文字で入力してください。';
    end if;
    result := public.spectrum_v6_action_impl(room,p_player_id,p_action,p_payload);
    update public.spectrum_rooms set expires_at=least(created_at+interval '24 hours',clock_timestamp()+case
      when result->'state'->>'phase'='finished' then interval '30 minutes' else interval '2 hours' end)
      where room_code=room;
    return result;
  exception when others then
    return jsonb_build_object('error',jsonb_build_object('code',case when sqlstate='42501' then 'ROOM_UNAVAILABLE' else 'ACTION_FAILED' end,
      'message',case when sqlstate in ('P0001','42501') then sqlerrm else 'うまくいきませんでした。もう一度試してください。' end));
  end;
end $$;

create or replace function public.spectrum_leave_room(p_room_code text,p_player_id text)
returns jsonb language plpgsql security definer set search_path = pg_catalog,public
as $$
declare caller uuid; room text := upper(trim(p_room_code)); result jsonb;
begin
  caller := public.spectrum_check_identity(p_player_id);
  if not public.spectrum_take_limit(caller::text,'leave',30,60) then
    return jsonb_build_object('error',jsonb_build_object('code','RATE_LIMIT','message','少し待ってから退出してください。'));
  end if;
  begin
    perform public.spectrum_check_member(room,caller);
    result := public.spectrum_v6_leave_impl(room,p_player_id);
    delete from public.spectrum_memberships where room_code=room and user_id=caller;
    return result;
  exception when others then
    return jsonb_build_object('error',jsonb_build_object('code','ROOM_UNAVAILABLE','message','部屋が見つからないか、すでに退出しています。'));
  end;
end $$;

-- No direct table access, including by authenticated anonymous users.
revoke all on public.spectrum_rooms,public.spectrum_room_secrets,public.spectrum_player_guesses,
 public.spectrum_memberships,public.spectrum_request_limits from public,anon,authenticated;
drop policy if exists "public can read spectrum rooms" on public.spectrum_rooms;

-- The client polls the protected RPC; there is no need for a public change feed.
do $$ begin
  if exists(select 1 from pg_publication_tables where pubname='supabase_realtime'
    and schemaname='public' and tablename='spectrum_rooms') then
    alter publication supabase_realtime drop table public.spectrum_rooms;
  end if;
end $$;

-- Revoke legacy entry points and every helper before allow-listing only the wrappers.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and left(p.proname,9)='spectrum_' loop
    execute format('revoke all on function %s from public, anon, authenticated',f.signature);
  end loop;
end $$;
grant execute on function public.spectrum_protocol() to anon,authenticated;
grant execute on function public.spectrum_create_room(text,text,text,jsonb,integer),
 public.spectrum_join_room(text,text,text),public.spectrum_get_room(text,text),
 public.spectrum_game_action(text,text,text,jsonb),public.spectrum_leave_room(text,text) to authenticated;

COMMIT;
