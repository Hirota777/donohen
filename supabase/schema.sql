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

create or replace function public.spectrum_expire_round(p_room_code text)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare s jsonb; missing jsonb;
begin
 select public_state into s from public.spectrum_rooms where room_code=p_room_code for update;
 if s->>'phase'='guess' and (s->>'answerDeadline') is not null
    and (s->>'answerDeadline')::numeric<=extract(epoch from clock_timestamp())*1000 then
   select coalesce(jsonb_agg(p->>'id'),'[]'::jsonb) into missing
   from jsonb_array_elements(s->'players') p
   where p->>'id'<>s->>'cluePlayerId'
     and not exists(select 1 from public.spectrum_player_guesses g where g.room_code=p_room_code
       and g.round_number=(s->>'round')::integer and g.player_id=p->>'id');
   s:=jsonb_set(s,'{timedOutPlayerIds}',missing,true);
   s:=jsonb_set(s,'{phase}','"reveal"'::jsonb);
   update public.spectrum_rooms set public_state=s,updated_at=clock_timestamp() where room_code=p_room_code;
 end if;
end $$;

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
    'endFlowVersion',1,'featuresVersion',1,'answerSeconds',0,'securityVersion',6,'rulesVersion',4,'roundsPerPlayer',1,'round',1,'cluePlayerId',p_player_id,'prompt',p_prompt,'promptHistory','[]'::jsonb,'clue','','phase','lobby',
    'answeredPlayerIds','[]'::jsonb,'lastRoundResults','[]'::jsonb,'targetRevealed',null,'updatedAt',now()
  );
  insert into public.spectrum_rooms(room_code,public_state,security_version,creator_id,expires_at) values(p_room_code,s,6,auth.uid(),now()+interval '2 hours');
  insert into public.spectrum_room_secrets(room_code,target,target_player_id) values(p_room_code,server_target,p_player_id);
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s,'target',server_target,'ownGuess',null);
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
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s,'target',result_target);
end $$;

create or replace function public.spectrum_v6_get_impl(
  p_room_code text, p_player_id text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare s jsonb; t integer := null; own_answer integer := null;
begin
  perform public.spectrum_expire_round(upper(trim(p_room_code)));
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
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s,'target',t,'ownGuess',own_answer);
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
  turns integer; schedule jsonb; match_rounds integer; stats jsonb; st jsonb; missed boolean;
begin
  perform public.spectrum_expire_round(room);
  -- A row-level lock serializes room updates and prevents concurrent double submissions.
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') p where p->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;

  if p_action='guess' and s->>'phase'='reveal' and coalesce(s->'timedOutPlayerIds','[]'::jsonb) ? p_player_id then
    return public.spectrum_v6_get_impl(room,p_player_id);
  end if;
  if p_action='settings' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが変更できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception '待機室で変更してください'; end if;
    if p_payload ? 'roundsPerPlayer' then
      if coalesce(p_payload->>'roundsPerPlayer','') !~ '^[1-3]$' then raise exception '回数は1〜3回です'; end if;
      s:=jsonb_set(s,'{roundsPerPlayer}',to_jsonb((p_payload->>'roundsPerPlayer')::integer),true);
    end if;
    if p_payload ? 'answerSeconds' then
      if coalesce(p_payload->>'answerSeconds','') not in ('0','30','60') then raise exception '回答時間はなし・30秒・60秒です'; end if;
      s:=jsonb_set(s,'{answerSeconds}',to_jsonb((p_payload->>'answerSeconds')::integer),true);
    end if;
  elsif p_action='start' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが開始できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception 'ゲームはすでに始まっています'; end if;
    if jsonb_array_length(s->'players') < 2 then raise exception '2人以上で開始してください'; end if;
    s := s - 'resultPlayers';
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
    s := jsonb_set(s,'{endFlowVersion}',to_jsonb(1),true);
    s := jsonb_set(s,'{rulesVersion}',to_jsonb(4),true);
    s := jsonb_set(s,'{awardsEnabled}','true'::jsonb,true);
    s := jsonb_set(s,'{matchStats}','{}'::jsonb,true);
    s := jsonb_set(s,'{roundHistory}','[]'::jsonb,true);
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds';
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
    s := jsonb_set(s,'{timedOutPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{answerDeadline}',case when coalesce((s->>'answerSeconds')::integer,0)>0
      then to_jsonb(extract(epoch from clock_timestamp())*1000+(s->>'answerSeconds')::integer*1000) else 'null'::jsonb end,true);
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
    stats := coalesce(s->'matchStats','{}'::jsonb);
    for item in select value from jsonb_array_elements(s->'players') loop
      if item->>'id' <> s->>'cluePlayerId' then
        select guess into g from public.spectrum_player_guesses
          where room_code=room and round_number=(s->>'round')::integer and player_id=item->>'id';
        missed := not found;
        if missed and not (coalesce(s->'timedOutPlayerIds','[]'::jsonb) ? (item->>'id')) then raise exception '一部の回答がありません'; end if;
        dist := case when missed then null else abs(sec.target - g) end;
        -- Keep the scoring rule frozen for matches already in progress.
        pts := case when coalesce((s->>'rulesVersion')::integer,2)>=4 and dist=0 then 15
          when coalesce((s->>'rulesVersion')::integer,2)>=3
          then greatest(0,10-((dist+1)/2))
          else case when dist=0 then 5 when dist<=2 then 4 when dist<=4 then 3 when dist<=6 then 2 when dist<=8 then 1 else 0 end end;
        if missed then pts:=0; g:=null; end if;
        st:=coalesce(stats->(item->>'id'),'{}'::jsonb);
        st:=st||jsonb_build_object('guessRounds',coalesce((st->>'guessRounds')::integer,0)+1,
          'answeredRounds',coalesce((st->>'answeredRounds')::integer,0)+case when missed then 0 else 1 end,
          'totalDistance',coalesce((st->>'totalDistance')::integer,0)+coalesce(dist,0),
          'exactHits',coalesce((st->>'exactHits')::integer,0)+case when dist=0 then 1 else 0 end);
        stats:=jsonb_set(stats,array[item->>'id'],st,true);
        total_guess_points := total_guess_points + pts;
        guesser_count := guesser_count + 1;
        item := jsonb_set(item,'{score}',to_jsonb(coalesce((item->>'score')::integer,0)+pts));
        results := results || jsonb_build_array(jsonb_build_object('playerId',item->>'id','guess',g,'distance',dist,'points',pts,'timedOut',missed));
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
    st:=coalesce(stats->(s->>'cluePlayerId'),'{}'::jsonb);
    st:=st||jsonb_build_object('hintRounds',coalesce((st->>'hintRounds')::integer,0)+1,
      'hintPoints',coalesce((st->>'hintPoints')::integer,0)+hint_points);
    stats:=jsonb_set(stats,array[s->>'cluePlayerId'],st,true);
    s := jsonb_set(s,'{matchStats}',stats,true);
    s := jsonb_set(s,'{players}',ps);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(hint_points),true);
    s := jsonb_set(s,'{lastRoundResults}',results,true);
    s := jsonb_set(s,'{targetRevealed}',to_jsonb(sec.target));
    -- Only append after the host's reveal, inside the same locked scoring transaction.
    s := jsonb_set(s,'{roundHistory}',coalesce(s->'roundHistory','[]'::jsonb)||jsonb_build_array(jsonb_build_object(
      'round',(s->>'round')::integer,'prompt',s->'prompt','clue',s->>'clue',
      'cluePlayerId',s->>'cluePlayerId','cluePlayerName',coalesce((select p->>'name' from jsonb_array_elements(s->'players') p where p->>'id'=s->>'cluePlayerId'),'ヒント役'),
      'target',sec.target,'hintPoints',hint_points,'results',(select jsonb_agg(r||jsonb_build_object('name',coalesce((select p->>'name' from jsonb_array_elements(s->'players') p where p->>'id'=r->>'playerId'),'プレイヤー'))) from jsonb_array_elements(results) r)
    )),true);
    if (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5) then
      s := jsonb_set(s,'{resultPlayers}',s->'players',true);
    end if;
  elsif p_action='finish' then
    if s->>'hostId'<>p_player_id then raise exception 'ホストだけが結果発表へ進めます'; end if;
    if s->>'phase'<>'reveal' or s->'targetRevealed' is not distinct from 'null'::jsonb
      or (s->>'round')::integer<coalesce((s->>'totalRounds')::integer,5) then
      raise exception '最終ラウンドの答え合わせを終えてから進んでください';
    end if;
    s := jsonb_set(s,'{resultPlayers}',coalesce(s->'resultPlayers',s->'players'),true);
    s := jsonb_set(s,'{phase}',to_jsonb('finished'::text));
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory' - 'resultPlayers';
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds';
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
  else
    raise exception '不明な操作です';
  end if;

  s := jsonb_set(s,'{featuresVersion}',to_jsonb(1),true);
  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=room;
  if s->>'cluePlayerId'=p_player_id and s->>'phase'='clue' then
    select target into t from public.spectrum_room_secrets where room_code=room;
  end if;
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s,'target',t,'ownGuess',own_answer);
end $$;

create or replace function public.spectrum_v6_leave_impl(p_room_code text, p_player_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  room text := upper(trim(p_room_code)); s jsonb; ps jsonb := '[]'::jsonb;
  item jsonb; prior_players jsonb; new_host text; new_clue text; remaining integer;
  did_clue_leave boolean; schedule jsonb; current_round integer; answered jsonb := '[]'::jsonb;
begin
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') v where v->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;
  prior_players := s->'players';
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

  -- Keep the scored roster separate from live room membership.
  if s->>'phase'='finished' or (s->>'phase'='reveal'
    and s->'targetRevealed' is distinct from 'null'::jsonb
    and (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5)) then
    s := jsonb_set(s,'{resultPlayers}',coalesce(s->'resultPlayers',prior_players),true);
  end if;

  if remaining < 2 and s->>'phase' not in ('lobby','finished') and not (
    s->>'phase'='reveal' and s->'targetRevealed' is distinct from 'null'::jsonb
    and (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5)) then
    -- A match requires >=2 players. Pause by returning to the lobby and reset
    -- the incomplete match; scores are retained until host starts again.
    s := jsonb_set(s,'{phase}',to_jsonb('lobby'::text));
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory' - 'resultPlayers';
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds';
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
    if p_action is null or p_action not in ('settings','start','clue','guess','reveal','finish','restart','next_round')
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

update public.spectrum_rooms set public_state=jsonb_set(public_state,'{featuresVersion}',to_jsonb(1),true) where security_version=6;
update public.spectrum_rooms set public_state=jsonb_set(public_state,'{endFlowVersion}',to_jsonb(1),true) where security_version=6;
COMMIT;

BEGIN;
-- Only an explicit share action publishes this player's card, for seven days.
create table if not exists public.spectrum_result_shares(
 token uuid primary key default gen_random_uuid(), owner_id uuid not null, match_key text not null,
 metadata jsonb not null, png bytea not null check(octet_length(png)<=450000),
 created_at timestamptz not null default clock_timestamp(),expires_at timestamptz not null default(clock_timestamp()+interval '7 days'),
 unique(owner_id,match_key)
);
create index if not exists spectrum_result_shares_expiry on public.spectrum_result_shares(expires_at);
alter table public.spectrum_result_shares enable row level security;
revoke all on public.spectrum_result_shares from public,anon,authenticated;

create or replace function public.spectrum_sanitize_share_png(p_image bytea)
returns bytea language plpgsql immutable set search_path=pg_catalog,public
as $$
declare at integer:=8; length bigint; kind text; cleaned bytea; chunks integer:=0; saw_data boolean:=false;
begin
 if octet_length(p_image)<40 or octet_length(p_image)>450000 then return null; end if;
 cleaned:=substring(p_image from 1 for 8);
 while at+12<=octet_length(p_image) loop
  chunks:=chunks+1;if chunks>1024 then return null; end if;
  length:=get_byte(p_image,at)::bigint*16777216+get_byte(p_image,at+1)*65536+get_byte(p_image,at+2)*256+get_byte(p_image,at+3);
  if length>450000 or at+12+length>octet_length(p_image) then return null; end if;
  kind:=convert_from(substring(p_image from at+5 for 4),'SQL_ASCII');
  if at=8 and (kind<>'IHDR' or length<>13) then return null; end if;
  if kind='IHDR' and at<>8 then return null; end if;
  if kind='IDAT' then saw_data:=true; end if;
  if kind in ('IHDR','IDAT','IEND','PLTE','tRNS','sRGB','sBIT','pHYs','gAMA','cHRM') then
   cleaned:=cleaned||substring(p_image from at+1 for (length+12)::integer);
  elsif get_byte(p_image,at+4) between 65 and 90 then return null;
  end if;
  at:=at+12+length;
  if kind='IEND' then
   if length<>0 or not saw_data or at<>octet_length(p_image) then return null; end if;
   return cleaned;
  end if;
 end loop;
 return null;
exception when others then return null;
end $$;

create or replace function public.spectrum_create_result_share(p_room_code text,p_player_id text,p_png text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare caller uuid; room text:=upper(trim(p_room_code)); s jsonb; player jsonb; best jsonb; average numeric; image bytea; share_token uuid; share_expires timestamptz; key text;
begin
 caller:=public.spectrum_check_identity(p_player_id);
 if not public.spectrum_take_limit(caller::text,'share',5,600) then return jsonb_build_object('error',jsonb_build_object('code','RATE_LIMIT','message','共有が続いています。少し待ってから試してください。')); end if;
 begin
  perform public.spectrum_check_member(room,caller);
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s->>'phase'<>'finished' then raise exception '最終結果を確認してから共有してください。'; end if;
  key:=room||':'||coalesce(s->>'matchId','');
  select token,expires_at into share_token,share_expires from public.spectrum_result_shares where owner_id=caller and match_key=key and expires_at>clock_timestamp();
  if found then return jsonb_build_object('token',share_token,'expiresAt',share_expires); end if;
  if p_png is null or length(p_png)>600000 or p_png !~ '^[A-Za-z0-9+/]*={0,2}$' then raise exception '共有画像を作成し直してください。'; end if;
  image:=decode(p_png,'base64');
  if octet_length(image)<40 or octet_length(image)>450000 or substring(image from 1 for 8)<>decode('89504e470d0a1a0a','hex')
    or substring(image from 13 for 4)<>decode('49484452','hex')
    or substring(image from 17 for 4)<>decode('000004b0','hex') or substring(image from 21 for 4)<>decode('00000276','hex') then
    raise exception '共有画像を作成し直してください。';
  end if;
  if get_byte(image,24)<>8 or get_byte(image,25) not in (2,6) or get_byte(image,26)<>0 or get_byte(image,27)<>0 or get_byte(image,28)<>0 then raise exception '共有画像を作成し直してください。'; end if;
  image:=public.spectrum_sanitize_share_png(image);
  if image is null then raise exception '共有画像を作成し直してください。'; end if;
  delete from public.spectrum_result_shares where expires_at<=clock_timestamp();
  perform pg_advisory_xact_lock(hashtext('donohen-public-shares'));
  if (select count(*) from public.spectrum_result_shares)>=200 then raise exception '共有が混み合っています。時間をおいて試してください。'; end if;
  if (select count(*) from public.spectrum_result_shares where owner_id=caller and created_at>clock_timestamp()-interval '1 day')>=3 then raise exception '今日の共有回数の上限です。また明日試してください。'; end if;
  select p into player from jsonb_array_elements(coalesce(s->'resultPlayers',s->'players')) p where p->>'id'=p_player_id;
  select r into best from jsonb_array_elements(coalesce(s->'roundHistory','[]'::jsonb)) r
    where r->>'cluePlayerId'=p_player_id and jsonb_array_length(r->'results')>0
    order by (select avg((v->>'points')::numeric) from jsonb_array_elements(r->'results') v) desc,(r->>'round')::integer limit 1;
  if best is not null then select avg((r->>'points')::numeric) into average from jsonb_array_elements(best->'results') r; end if;
  insert into public.spectrum_result_shares(owner_id,match_key,metadata,png)
  values(caller,key,jsonb_build_object('name',player->>'name','score',(player->>'score')::integer,
    'rank',(select count(*)+1 from jsonb_array_elements(coalesce(s->'resultPlayers',s->'players')) p where (p->>'score')::integer>(player->>'score')::integer),
    'playerCount',jsonb_array_length(coalesce(s->'resultPlayers',s->'players')),'rounds',coalesce((s->>'totalRounds')::integer,(s->>'round')::integer),
    'bestHint',case when best is null then null else jsonb_build_object('prompt',best->'prompt','clue',best->>'clue','target',best->'target','average',round(average,1)) end),image)
  on conflict(owner_id,match_key) do update set metadata=excluded.metadata,png=excluded.png,created_at=clock_timestamp(),expires_at=clock_timestamp()+interval '7 days'
  returning token,expires_at into share_token,share_expires;
  return jsonb_build_object('token',share_token,'expiresAt',share_expires);
 exception when others then
  return jsonb_build_object('error',jsonb_build_object('code','SHARE_FAILED','message',case when sqlstate='P0001' then sqlerrm else '共有を準備できませんでした。もう一度試してください。' end));
 end;
end $$;

create or replace function public.spectrum_get_result_share(p_token uuid,p_image boolean default false)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare result jsonb;
begin
 if not public.spectrum_take_limit('public-result-shares','read',1200,60) then return null; end if;
 select metadata||jsonb_build_object('expiresAt',expires_at,'image',case when p_image then encode(png,'base64') else null end)
 into result from public.spectrum_result_shares where token=p_token and expires_at>clock_timestamp();
 return result;
end $$;

create or replace function public.spectrum_cleanup_expired()
returns integer language plpgsql security definer set search_path=pg_catalog,public
as $$
declare removed integer;
begin
 delete from public.spectrum_rooms where expires_at<=clock_timestamp();get diagnostics removed=row_count;
 delete from public.spectrum_result_shares where expires_at<=clock_timestamp();
 delete from public.spectrum_request_limits where window_start<clock_timestamp()-interval '1 day';return removed;
end $$;
revoke all on function public.spectrum_sanitize_share_png(bytea),public.spectrum_create_result_share(text,text,text),public.spectrum_get_result_share(uuid,boolean),public.spectrum_cleanup_expired() from public,anon,authenticated;
grant execute on function public.spectrum_create_result_share(text,text,text) to authenticated;
grant execute on function public.spectrum_get_result_share(uuid,boolean) to anon,authenticated;


COMMIT;

BEGIN;
create table if not exists public.spectrum_prepared_hints (
 room_code text not null references public.spectrum_rooms(room_code) on delete cascade,
 turn_index integer not null check(turn_index between 1 and 36),
 player_id text not null,
 prompt jsonb not null,
 target integer not null check(target between 0 and 100),
 clue text check(clue is null or length(trim(clue)) between 1 and 100),
 primary key(room_code,turn_index)
);
alter table public.spectrum_prepared_hints enable row level security;
revoke all on public.spectrum_prepared_hints from public,anon,authenticated;

create or replace function public.spectrum_v12_prompt_pool() returns jsonb language sql immutable set search_path=pg_catalog,public as $pool$ select '[{"left":"冷たい","right":"熱い"},{"left":"静か","right":"うるさい"},{"left":"簡単","right":"難しい"},{"left":"ありふれた","right":"珍しい"},{"left":"便利じゃない","right":"とても便利"},{"left":"散らかっている","right":"片付いている"},{"left":"短く感じる","right":"長く感じる"},{"left":"落ち着かない","right":"落ち着く"},{"left":"時間がかかる","right":"すぐ終わる"},{"left":"毎日は無理","right":"毎日でもできる"},{"left":"お金がかからない","right":"お金がかかる"},{"left":"一人向き","right":"大人数向き"},{"left":"屋内向き","right":"屋外向き"},{"left":"冬向き","right":"夏向き"},{"left":"眠くなる","right":"目が覚める"},{"left":"気軽にできる","right":"覚悟が必要"},{"left":"甘くない","right":"とても甘い"},{"left":"辛くない","right":"激辛"},{"left":"薄味","right":"濃い味"},{"left":"さっぱり","right":"こってり"},{"left":"軽食向き","right":"がっつり食事向き"},{"left":"朝食向き","right":"夕食向き"},{"left":"健康的","right":"不健康"},{"left":"見た目が地味","right":"見た目が華やか"},{"left":"安い","right":"高い"},{"left":"食べやすい","right":"食べにくい"},{"left":"子ども向け","right":"大人向け"},{"left":"万人受けしない","right":"万人受けする"},{"left":"手軽に作れる","right":"調理が大変"},{"left":"冷やしたい","right":"熱々で食べたい"},{"left":"香りが弱い","right":"香りが強い"},{"left":"食感が柔らかい","right":"食感が硬い"},{"left":"子どもっぽい","right":"大人っぽい"},{"left":"地味","right":"派手"},{"left":"慎重","right":"大胆"},{"left":"人見知り","right":"社交的"},{"left":"マイペース","right":"せっかち"},{"left":"現実的","right":"夢見がち"},{"left":"優柔不断","right":"決断が早い"},{"left":"温厚","right":"短気"},{"left":"感情が顔に出ない","right":"感情が顔に出る"},{"left":"計画的","right":"行き当たりばったり"},{"left":"論理的","right":"感覚的"},{"left":"クール","right":"情熱的"},{"left":"自分に厳しい","right":"自分に甘い"},{"left":"信用できない","right":"信用できる"},{"left":"運要素が強い","right":"実力要素が強い"},{"left":"初心者向け","right":"上級者向け"},{"left":"短時間で遊べる","right":"長時間遊べる"},{"left":"協力向き","right":"対戦向き"},{"left":"操作が簡単","right":"操作が複雑"},{"left":"怖くない","right":"めちゃくちゃ怖い"},{"left":"何も考えず遊べる","right":"頭を使う"},{"left":"自由度が低い","right":"自由度が高い"},{"left":"テンポが遅い","right":"テンポが速い"},{"left":"平和","right":"殺伐"},{"left":"準備が不要","right":"準備が大変"},{"left":"暗記が重要","right":"ひらめきが重要"},{"left":"初心者でもできる","right":"専門知識が必要"},{"left":"失敗しても平気","right":"失敗できない"},{"left":"リモート向き","right":"対面向き"},{"left":"ルーティン","right":"毎回違う"},{"left":"目立たない仕事","right":"目立つ仕事"},{"left":"自由な服装向き","right":"フォーマル向き"},{"left":"日帰り向き","right":"宿泊向き"},{"left":"観光客が少ない","right":"観光客が多い"},{"left":"写真映えしない","right":"写真映えする"},{"left":"計画なしで行ける","right":"綿密な計画が必要"},{"left":"都会的","right":"自然豊か"},{"left":"雨でも楽しめる","right":"晴れじゃないと厳しい"},{"left":"朝が楽しい","right":"夜が楽しい"},{"left":"歩かなくていい","right":"たくさん歩く"},{"left":"ダサい","right":"おしゃれ"},{"left":"ありがち","right":"斬新"},{"left":"予想通り","right":"予想外"},{"left":"明るい雰囲気","right":"暗い雰囲気"},{"left":"現実的","right":"ファンタジー"},{"left":"わかりやすい","right":"解釈が難しい"},{"left":"何も残らない","right":"余韻が強い"},{"left":"小規模な作品","right":"超大作"},{"left":"知名度が低い","right":"知名度が高い"},{"left":"距離感が遠い","right":"距離感が近い"},{"left":"さりげない好意","right":"わかりやすい好意"},{"left":"連絡が少ない","right":"連絡が多い"},{"left":"関係が浅い","right":"関係が深い"},{"left":"束縛しない","right":"束縛が強い"},{"left":"思い出に残らない","right":"一生の思い出"},{"left":"現実に起こりそう","right":"絶対に起こらなそう"},{"left":"欲しくない能力","right":"欲しい能力"},{"left":"小さな変化","right":"世界が変わる変化"},{"left":"リスクが低い","right":"リスクが高い"},{"left":"使い道が少ない","right":"使い道が多い"},{"left":"安っぽい","right":"高級感がある"},{"left":"許せる失敗","right":"許せない失敗"},{"left":"ちょっと恥ずかしい","right":"かなり恥ずかしい"},{"left":"弱そう","right":"強そう"},{"left":"かわいくない","right":"めちゃくちゃかわいい"},{"left":"面白くない","right":"爆笑もの"},{"left":"日常の事件","right":"大事件"},{"left":"普通の言い訳","right":"苦しい言い訳"}]'::jsonb $pool$;

create or replace function public.spectrum_v12_prepared_hints(p_room text,p_player text)
returns jsonb language sql stable security definer set search_path=pg_catalog,public
as $$
 select coalesce(jsonb_agg(jsonb_build_object('turnId',h.turn_index,'prompt',h.prompt,
  'target',h.target,'clue',h.clue) order by h.turn_index),'[]'::jsonb)
 from public.spectrum_prepared_hints h join public.spectrum_rooms r using(room_code)
 where h.room_code=p_room and h.player_id=p_player and r.public_state->>'phase'='prepare'
$$;

create or replace function public.spectrum_v12_activate(p_room text,s jsonb,p_round integer)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare h record; seconds integer;
begin
 select * into h from public.spectrum_prepared_hints
 where room_code=p_room and turn_index=(s->'preparedTurnOrder'->>(p_round-1))::integer;
 if not found or h.clue is null then raise exception '全員のヒントがそろっていません。'; end if;
 if not exists(select 1 from jsonb_array_elements(s->'players') p where p->>'id'=h.player_id) then
  raise exception 'このヒント役は退出しています。';
 end if;
 update public.spectrum_room_secrets set target=h.target,target_player_id=h.player_id where room_code=p_room;
 s:=s||jsonb_build_object('phase','guess','round',p_round,'cluePlayerId',h.player_id,
  'prompt',h.prompt,'clue',h.clue,'answeredPlayerIds','[]'::jsonb,'lastRoundResults','[]'::jsonb,
  'hintPoints',0,'targetRevealed',null,'promptHistory',coalesce(s->'promptHistory','[]'::jsonb)||jsonb_build_array(h.prompt));
 s:=s-'timedOutPlayerIds'-'answerDeadline';
 seconds:=coalesce((s->>'answerSeconds')::integer,0);
 if seconds>0 then s:=jsonb_set(s,'{answerDeadline}',to_jsonb(extract(epoch from clock_timestamp())*1000+seconds*1000),true); end if;
 return s;
end $$;

create or replace function public.spectrum_v12_ready(p_room text,s jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare ready jsonb;
begin
 select coalesce(jsonb_agg(p->>'id'),'[]'::jsonb) into ready from jsonb_array_elements(s->'players') p
 where exists(select 1 from public.spectrum_prepared_hints h where h.room_code=p_room and h.player_id=p->>'id')
 and not exists(select 1 from public.spectrum_prepared_hints h where h.room_code=p_room and h.player_id=p->>'id' and h.clue is null);
 s:=jsonb_set(s,'{preparedPlayerIds}',ready,true);
 if jsonb_array_length(ready)=jsonb_array_length(s->'players') and jsonb_array_length(ready)>=2 then
  s:=public.spectrum_v12_activate(p_room,s,1);
 end if;
 return s;
end $$;

create or replace function public.spectrum_v12_prepare(p_room text,s jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare pool jsonb; turn record; turn_order jsonb:='[]'::jsonb; total integer;
begin
 delete from public.spectrum_prepared_hints where room_code=p_room;
 total:=jsonb_array_length(s->'clueSchedule');
 select jsonb_agg(prompt) into pool from (select value as prompt from jsonb_array_elements(public.spectrum_v12_prompt_pool()) order by random() limit total) p;
 if jsonb_array_length(pool)<>total then raise exception 'お題を用意できませんでした。'; end if;
 for turn in select value #>> '{}' as player,ord::integer as num from jsonb_array_elements(s->'clueSchedule') with ordinality a(value,ord) loop
  insert into public.spectrum_prepared_hints(room_code,turn_index,player_id,prompt,target)
   values(p_room,turn.num,turn.player,pool->(turn.num-1),floor(random()*71)::integer+15);
  turn_order:=turn_order||jsonb_build_array(turn.num);
 end loop;
 return (s-'answerDeadline'-'timedOutPlayerIds')||jsonb_build_object('phase','prepare','hintBatchVersion',1,
  'preparedTurnOrder',turn_order,'preparedPlayerIds','[]'::jsonb,'prompt',jsonb_build_object('left','','right',''),
  'promptHistory','[]'::jsonb,'clue','','targetRevealed',null);
end $$;

create or replace function public.spectrum_v12_submit(p_room text,s jsonb,p_player text,p_payload jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare own_count integer; h jsonb; num integer; seen integer[]:=array[]::integer[]; stored record;
begin
 if s->>'phase'<>'prepare' or s->>'hintBatchVersion'<>'1' then raise exception '今はヒントを提出できません。'; end if;
 select count(*) into own_count from public.spectrum_prepared_hints where room_code=p_room and player_id=p_player;
 if jsonb_typeof(p_payload->'hints') is distinct from 'array' then raise exception '担当するヒントをすべて入力してください。'; end if;
 if own_count not between 1 and 3 or jsonb_array_length(p_payload->'hints')<>own_count then raise exception '担当するヒントをすべて入力してください。'; end if;
 for h in select value from jsonb_array_elements(p_payload->'hints') loop
  if jsonb_typeof(h)<>'object' or jsonb_typeof(h->'turnId') is distinct from 'number'
   or coalesce(h->>'turnId','') !~ '^[0-9]{1,2}$'
   or jsonb_typeof(h->'clue') is distinct from 'string' then raise exception 'ヒントの形式を確認してください。'; end if;
  num:=(h->>'turnId')::integer;
  if num=any(seen) or length(trim(h->>'clue')) not between 1 and 100 then raise exception 'ヒントは重複なく、1〜100文字で入力してください。'; end if;
  select * into stored from public.spectrum_prepared_hints where room_code=p_room and turn_index=num and player_id=p_player;
  if not found then raise exception '自分が担当するヒントだけ提出できます。'; end if;
  if stored.clue is not null and stored.clue<>trim(h->>'clue') then raise exception '提出したヒントは変更できません。'; end if;
  update public.spectrum_prepared_hints set clue=trim(h->>'clue') where room_code=p_room and turn_index=num and player_id=p_player;
  seen:=array_append(seen,num);
 end loop;
 return public.spectrum_v12_ready(p_room,s);
end $$;

create or replace function public.spectrum_v12_leave(p_room text,s jsonb,p_player text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare prior_players jsonb:=s->'players'; ps jsonb; new_host text; current_round integer:=(s->>'round')::integer;
 was_preparing boolean:=s->>'phase'='prepare'; current_done boolean:=s->'targetRevealed' is distinct from 'null'::jsonb;
 current_leaves boolean; kept_order jsonb; kept_schedule jsonb; total integer; old jsonb; before_count integer;
begin
 select coalesce(jsonb_agg(p),'[]'::jsonb) into ps from jsonb_array_elements(s->'players') p where p->>'id'<>p_player;
 delete from public.spectrum_player_guesses where room_code=p_room and player_id=p_player;
 if jsonb_array_length(ps)=0 then delete from public.spectrum_rooms where room_code=p_room; return jsonb_build_object('left',true,'closed',true); end if;
 new_host:=ps->0->>'id';s:=jsonb_set(s,'{players}',ps);
 if s->>'hostId'=p_player then s:=jsonb_set(s,'{hostId}',to_jsonb(new_host)); end if;
 current_leaves:=not was_preparing and not current_done and s->>'cluePlayerId'=p_player;
 select coalesce(jsonb_agg(turn.value order by turn.ord),'[]'::jsonb),coalesce(jsonb_agg(h.player_id order by turn.ord),'[]'::jsonb)
 into kept_order,kept_schedule
 from jsonb_array_elements(s->'preparedTurnOrder') with ordinality turn(value,ord)
 join public.spectrum_prepared_hints h on h.room_code=p_room and h.turn_index=(turn.value #>> '{}')::integer
 where (not was_preparing and (turn.ord<current_round or (turn.ord=current_round and current_done))) or h.player_id<>p_player;
 total:=jsonb_array_length(kept_order);
 s:=s||jsonb_build_object('preparedTurnOrder',kept_order,'clueSchedule',kept_schedule,'totalRounds',total);
 delete from public.spectrum_prepared_hints h where h.room_code=p_room
  and not exists(select 1 from jsonb_array_elements(kept_order) k where (k #>> '{}')::integer=h.turn_index);
 -- A last scored round can still finish with one remaining player.
 if jsonb_array_length(ps)<2 and not (not was_preparing and current_done and current_round>=total) then
  delete from public.spectrum_prepared_hints where room_code=p_room;
  delete from public.spectrum_player_guesses where room_code=p_room;
  s:=s-'answerDeadline'-'timedOutPlayerIds'-'matchStats'-'awardsEnabled'-'roundHistory'-'resultPlayers'
   -'totalRounds'-'clueSchedule'-'hintBatchVersion'-'preparedTurnOrder'-'preparedPlayerIds';
  s:=s||jsonb_build_object('phase','lobby','round',1,'cluePlayerId',new_host,'clue','','targetRevealed',null,
   'answeredPlayerIds','[]'::jsonb,'lastRoundResults','[]'::jsonb,'hintPoints',0,'promptHistory','[]'::jsonb);
  update public.spectrum_room_secrets set target=floor(random()*71)::integer+15,target_player_id=new_host where room_code=p_room;
 elsif was_preparing then
  s:=public.spectrum_v12_ready(p_room,s);
 elsif current_leaves then
  delete from public.spectrum_player_guesses where room_code=p_room and round_number=current_round;
  if current_round<=total then s:=public.spectrum_v12_activate(p_room,s,current_round);
  else
   -- No future assigned turns remain: keep the last scored answer before final results.
   before_count:=jsonb_array_length(coalesce(s->'roundHistory','[]'::jsonb));
   if before_count=0 then raise exception '続けられるラウンドがありません。'; end if;
   old:=s->'roundHistory'->(before_count-1);
   s:=s||jsonb_build_object('phase','reveal','round',before_count,'totalRounds',before_count,
    'cluePlayerId',old->>'cluePlayerId','prompt',old->'prompt','clue',old->>'clue','targetRevealed',old->'target',
    'hintPoints',old->'hintPoints','lastRoundResults',old->'results','resultPlayers',prior_players);
   s:=s-'answerDeadline'-'timedOutPlayerIds';
  end if;
 else
  s:=jsonb_set(s,'{answeredPlayerIds}',coalesce((select jsonb_agg(a) from jsonb_array_elements(coalesce(s->'answeredPlayerIds','[]'::jsonb)) a where a #>> '{}'<>p_player),'[]'::jsonb));
  if s->>'phase'='guess' and jsonb_array_length(s->'answeredPlayerIds')>=jsonb_array_length(ps)-1 then s:=jsonb_set(s,'{phase}','"reveal"'::jsonb); end if;
 end if;
 if s->>'phase'='reveal' and s->'targetRevealed' is distinct from 'null'::jsonb
  and (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5) then
  s:=jsonb_set(s,'{resultPlayers}',coalesce(s->'resultPlayers',prior_players),true);
 end if;
 s:=jsonb_set(s,'{updatedAt}',to_jsonb(now()));
 update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=p_room;
 return jsonb_build_object('left',true,'closed',false);
end $$;


create or replace function public.spectrum_v6_get_impl(
  p_room_code text, p_player_id text
) returns jsonb
language plpgsql security definer set search_path = public, pg_temp
as $$
declare s jsonb; t integer := null; own_answer integer := null;
begin
  perform public.spectrum_expire_round(upper(trim(p_room_code)));
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
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s,'target',t,'ownGuess',own_answer,'preparedHints',public.spectrum_v12_prepared_hints(upper(trim(p_room_code)),p_player_id));
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
  turns integer; schedule jsonb; match_rounds integer; stats jsonb; st jsonb; missed boolean;
begin
  perform public.spectrum_expire_round(room);
  -- A row-level lock serializes room updates and prevents concurrent double submissions.
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') p where p->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;

  if p_action='guess' and s->>'phase'='reveal' and coalesce(s->'timedOutPlayerIds','[]'::jsonb) ? p_player_id then
    return public.spectrum_v6_get_impl(room,p_player_id);
  end if;
  if p_action='settings' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが変更できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception '待機室で変更してください'; end if;
    if p_payload ? 'roundsPerPlayer' then
      if coalesce(p_payload->>'roundsPerPlayer','') !~ '^[1-3]$' then raise exception '回数は1〜3回です'; end if;
      s:=jsonb_set(s,'{roundsPerPlayer}',to_jsonb((p_payload->>'roundsPerPlayer')::integer),true);
    end if;
    if p_payload ? 'answerSeconds' then
      if coalesce(p_payload->>'answerSeconds','') not in ('0','30','60') then raise exception '回答時間はなし・30秒・60秒です'; end if;
      s:=jsonb_set(s,'{answerSeconds}',to_jsonb((p_payload->>'answerSeconds')::integer),true);
    end if;
  elsif p_action='start' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが開始できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception 'ゲームはすでに始まっています'; end if;
    if jsonb_array_length(s->'players') < 2 then raise exception '2人以上で開始してください'; end if;
    delete from public.spectrum_prepared_hints where room_code=room;
    s := s - 'resultPlayers' - 'hintBatchVersion' - 'preparedTurnOrder' - 'preparedPlayerIds';
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
    s := jsonb_set(s,'{endFlowVersion}',to_jsonb(1),true);
    s := jsonb_set(s,'{rulesVersion}',to_jsonb(4),true);
    s := jsonb_set(s,'{awardsEnabled}','true'::jsonb,true);
    s := jsonb_set(s,'{matchStats}','{}'::jsonb,true);
    s := jsonb_set(s,'{roundHistory}','[]'::jsonb,true);
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds';
    s := jsonb_set(s,'{prompt}',coalesce(p_payload->'prompt',jsonb_build_object('left','冷たい','right','熱い')));
    s := jsonb_set(s,'{promptHistory}',jsonb_build_array(s->'prompt'),true);
    if p_payload->'prepareHints'='true'::jsonb then s:=public.spectrum_v12_prepare(room,s); end if;
  elsif p_action='prepare_clues' then
    s:=public.spectrum_v12_submit(room,s,p_player_id,p_payload);
  elsif p_action='clue' then
    if s->>'cluePlayerId' <> p_player_id or s->>'phase' <> 'clue' then raise exception '今はヒントを送信できません'; end if;
    if length(trim(coalesce(p_payload->>'clue',''))) < 1 or length(p_payload->>'clue') > 100 then raise exception 'ヒントは1〜100文字にしてください'; end if;
    s := jsonb_set(s,'{clue}',to_jsonb(trim(p_payload->>'clue')));
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{phase}',to_jsonb('guess'::text));
    s := jsonb_set(s,'{timedOutPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{answerDeadline}',case when coalesce((s->>'answerSeconds')::integer,0)>0
      then to_jsonb(extract(epoch from clock_timestamp())*1000+(s->>'answerSeconds')::integer*1000) else 'null'::jsonb end,true);
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
    stats := coalesce(s->'matchStats','{}'::jsonb);
    for item in select value from jsonb_array_elements(s->'players') loop
      if item->>'id' <> s->>'cluePlayerId' then
        select guess into g from public.spectrum_player_guesses
          where room_code=room and round_number=(s->>'round')::integer and player_id=item->>'id';
        missed := not found;
        if missed and not (coalesce(s->'timedOutPlayerIds','[]'::jsonb) ? (item->>'id')) then raise exception '一部の回答がありません'; end if;
        dist := case when missed then null else abs(sec.target - g) end;
        -- Keep the scoring rule frozen for matches already in progress.
        pts := case when coalesce((s->>'rulesVersion')::integer,2)>=4 and dist=0 then 15
          when coalesce((s->>'rulesVersion')::integer,2)>=3
          then greatest(0,10-((dist+1)/2))
          else case when dist=0 then 5 when dist<=2 then 4 when dist<=4 then 3 when dist<=6 then 2 when dist<=8 then 1 else 0 end end;
        if missed then pts:=0; g:=null; end if;
        st:=coalesce(stats->(item->>'id'),'{}'::jsonb);
        st:=st||jsonb_build_object('guessRounds',coalesce((st->>'guessRounds')::integer,0)+1,
          'answeredRounds',coalesce((st->>'answeredRounds')::integer,0)+case when missed then 0 else 1 end,
          'totalDistance',coalesce((st->>'totalDistance')::integer,0)+coalesce(dist,0),
          'exactHits',coalesce((st->>'exactHits')::integer,0)+case when dist=0 then 1 else 0 end);
        stats:=jsonb_set(stats,array[item->>'id'],st,true);
        total_guess_points := total_guess_points + pts;
        guesser_count := guesser_count + 1;
        item := jsonb_set(item,'{score}',to_jsonb(coalesce((item->>'score')::integer,0)+pts));
        results := results || jsonb_build_array(jsonb_build_object('playerId',item->>'id','guess',g,'distance',dist,'points',pts,'timedOut',missed));
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
    st:=coalesce(stats->(s->>'cluePlayerId'),'{}'::jsonb);
    st:=st||jsonb_build_object('hintRounds',coalesce((st->>'hintRounds')::integer,0)+1,
      'hintPoints',coalesce((st->>'hintPoints')::integer,0)+hint_points);
    stats:=jsonb_set(stats,array[s->>'cluePlayerId'],st,true);
    s := jsonb_set(s,'{matchStats}',stats,true);
    s := jsonb_set(s,'{players}',ps);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(hint_points),true);
    s := jsonb_set(s,'{lastRoundResults}',results,true);
    s := jsonb_set(s,'{targetRevealed}',to_jsonb(sec.target));
    -- Only append after the host's reveal, inside the same locked scoring transaction.
    s := jsonb_set(s,'{roundHistory}',coalesce(s->'roundHistory','[]'::jsonb)||jsonb_build_array(jsonb_build_object(
      'round',(s->>'round')::integer,'prompt',s->'prompt','clue',s->>'clue',
      'cluePlayerId',s->>'cluePlayerId','cluePlayerName',coalesce((select p->>'name' from jsonb_array_elements(s->'players') p where p->>'id'=s->>'cluePlayerId'),'ヒント役'),
      'target',sec.target,'hintPoints',hint_points,'results',(select jsonb_agg(r||jsonb_build_object('name',coalesce((select p->>'name' from jsonb_array_elements(s->'players') p where p->>'id'=r->>'playerId'),'プレイヤー'))) from jsonb_array_elements(results) r)
    )),true);
    if (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5) then
      s := jsonb_set(s,'{resultPlayers}',s->'players',true);
    end if;
  elsif p_action='finish' then
    if s->>'hostId'<>p_player_id then raise exception 'ホストだけが結果発表へ進めます'; end if;
    if s->>'phase'<>'reveal' or s->'targetRevealed' is not distinct from 'null'::jsonb
      or (s->>'round')::integer<coalesce((s->>'totalRounds')::integer,5) then
      raise exception '最終ラウンドの答え合わせを終えてから進んでください';
    end if;
    s := jsonb_set(s,'{resultPlayers}',coalesce(s->'resultPlayers',s->'players'),true);
    s := jsonb_set(s,'{phase}',to_jsonb('finished'::text));
  elsif p_action='restart' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが再スタートできます'; end if;
    if s->>'phase' <> 'finished' then raise exception '終了後に再スタートできます'; end if;
    delete from public.spectrum_prepared_hints where room_code=room;
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory' - 'resultPlayers' - 'hintBatchVersion' - 'preparedTurnOrder' - 'preparedPlayerIds';
    s := s - 'totalRounds' - 'clueSchedule';
    s := jsonb_set(s,'{promptHistory}','[]'::jsonb,true);
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
  elsif p_action='next_round' then
    if s->>'hintBatchVersion'='1' then
      if s->>'hostId'<>p_player_id then raise exception 'ホストだけが次のラウンドを開始できます'; end if;
      if s->>'phase'<>'reveal' or s->'targetRevealed' is not distinct from 'null'::jsonb then raise exception '答えを公開してから次へ進んでください'; end if;
      if (s->>'round')::integer>=(s->>'totalRounds')::integer then raise exception '全ラウンドが終了しています'; end if;
      s:=public.spectrum_v12_activate(room,s,(s->>'round')::integer+1);
    else
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds';
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
    end if;
  else
    raise exception '不明な操作です';
  end if;

  s := jsonb_set(s,'{featuresVersion}',to_jsonb(1),true);
  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=room;
  if s->>'cluePlayerId'=p_player_id and s->>'phase'='clue' then
    select target into t from public.spectrum_room_secrets where room_code=room;
  end if;
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s,'target',t,'ownGuess',own_answer,'preparedHints',public.spectrum_v12_prepared_hints(room,p_player_id));
end $$;

create or replace function public.spectrum_v6_leave_impl(p_room_code text, p_player_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  room text := upper(trim(p_room_code)); s jsonb; ps jsonb := '[]'::jsonb;
  item jsonb; prior_players jsonb; new_host text; new_clue text; remaining integer;
  did_clue_leave boolean; schedule jsonb; current_round integer; answered jsonb := '[]'::jsonb;
begin
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') v where v->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;
  if s->>'hintBatchVersion'='1' and s->>'phase'<>'finished' then return public.spectrum_v12_leave(room,s,p_player_id); end if;
  prior_players := s->'players';
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

  -- Keep the scored roster separate from live room membership.
  if s->>'phase'='finished' or (s->>'phase'='reveal'
    and s->'targetRevealed' is distinct from 'null'::jsonb
    and (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5)) then
    s := jsonb_set(s,'{resultPlayers}',coalesce(s->'resultPlayers',prior_players),true);
  end if;

  if remaining < 2 and s->>'phase' not in ('lobby','finished') and not (
    s->>'phase'='reveal' and s->'targetRevealed' is distinct from 'null'::jsonb
    and (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5)) then
    -- A match requires >=2 players. Pause by returning to the lobby and reset
    -- the incomplete match; scores are retained until host starts again.
    s := jsonb_set(s,'{phase}',to_jsonb('lobby'::text));
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory' - 'resultPlayers';
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds';
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

    if s->>'phase'='guess' and jsonb_array_length(answered)>=remaining-1 then
      s := jsonb_set(s,'{phase}',to_jsonb('reveal'::text));
    end if;
  end if;
  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=room;
  return jsonb_build_object('left',true,'closed',false);
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
    if p_action is null or p_action not in ('settings','start','prepare_clues','clue','guess','reveal','finish','restart','next_round')
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
    if p_action='start' and p_payload ? 'prepareHints' and jsonb_typeof(p_payload->'prepareHints') is distinct from 'boolean' then raise exception '開始方法を確認してください。'; end if;
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

create or replace function public.spectrum_protocol() returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$ select jsonb_build_object('version',6,'authRequired',true,'preparationVersion',1) $$;

do $$ declare f record; begin
 for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and left(p.proname,13)='spectrum_v12_' loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
 end loop;
end $$;
COMMIT;
