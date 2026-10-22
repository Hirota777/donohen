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
grant select on public.spectrum_rooms to anon, authenticated;
drop policy if exists "public can read spectrum rooms" on public.spectrum_rooms;
create policy "public can read spectrum rooms" on public.spectrum_rooms
  for select to anon, authenticated using (true);

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
  round_number integer not null check (round_number between 1 and 5),
  player_id text not null,
  guess integer not null check (guess between 0 and 100),
  created_at timestamptz not null default now(),
  primary key (room_code, round_number, player_id)
);
alter table public.spectrum_player_guesses enable row level security;
revoke all on public.spectrum_player_guesses from anon, authenticated;

create or replace function public.spectrum_create_room(
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
    'round',1,'cluePlayerId',p_player_id,'prompt',p_prompt,'promptHistory','[]'::jsonb,'clue','','phase','lobby',
    'answeredPlayerIds','[]'::jsonb,'lastRoundResults','[]'::jsonb,'targetRevealed',null,'updatedAt',now()
  );
  insert into public.spectrum_rooms(room_code,public_state) values(p_room_code,s);
  insert into public.spectrum_room_secrets(room_code,target,target_player_id) values(p_room_code,server_target,p_player_id);
  return jsonb_build_object('state',s,'target',server_target,'ownGuess',null);
end $$;

create or replace function public.spectrum_join_room(
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

create or replace function public.spectrum_get_room(
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

create or replace function public.spectrum_game_action(
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
begin
  -- A row-level lock serializes room updates and prevents concurrent double submissions.
  select public_state into s from public.spectrum_rooms where room_code=room for update;
  if s is null then raise exception 'ルームが見つかりません'; end if;
  if not exists(select 1 from jsonb_array_elements(s->'players') p where p->>'id'=p_player_id) then
    raise exception 'このルームの参加者ではありません';
  end if;

  if p_action='start' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが開始できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception 'ゲームはすでに始まっています'; end if;
    if jsonb_array_length(s->'players') < 2 then raise exception '2人以上で開始してください'; end if;
    -- A lobby start is always a clean five-round match.
    ps := '[]'::jsonb;
    for item in select value from jsonb_array_elements(s->'players') loop
      ps := ps || jsonb_build_array(jsonb_set(item,'{score}',to_jsonb(0)));
    end loop;
    s := jsonb_set(s,'{players}',ps);
    s := jsonb_set(s,'{phase}',to_jsonb('clue'));
    s := jsonb_set(s,'{prompt}',coalesce(p_payload->'prompt',jsonb_build_object('left','冷たい','right','熱い')));
    s := jsonb_set(s,'{promptHistory}',jsonb_build_array(s->'prompt'),true);
  elsif p_action='clue' then
    if s->>'cluePlayerId' <> p_player_id or s->>'phase' <> 'clue' then raise exception '今はヒントを送信できません'; end if;
    if length(trim(coalesce(p_payload->>'clue',''))) < 1 or length(p_payload->>'clue') > 100 then raise exception 'ヒントは1〜100文字にしてください'; end if;
    s := jsonb_set(s,'{clue}',to_jsonb(trim(p_payload->>'clue')));
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{phase}',to_jsonb('guess'));
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
      s := jsonb_set(s,'{phase}',to_jsonb('reveal'));
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
        pts := case when dist=0 then 5 when dist<=3 then 4 when dist<=7 then 3 when dist<=12 then 2 when dist<=20 then 1 else 0 end;
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
    if (s->>'round')::integer >= 5 then
      s := jsonb_set(s,'{phase}',to_jsonb('finished'));
    end if;
  elsif p_action='restart' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが再スタートできます'; end if;
    if s->>'phase' <> 'finished' then raise exception '5戦終了後に再スタートできます'; end if;
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
    s := jsonb_set(s,'{clue}',to_jsonb(''));
    s := jsonb_set(s,'{phase}',to_jsonb('lobby'));
    s := jsonb_set(s,'{promptHistory}','[]'::jsonb,true);
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb,true);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb,true);
    s := jsonb_set(s,'{hintPoints}',to_jsonb(0),true);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
  elsif p_action='next_round' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが次のラウンドを開始できます'; end if;
    if s->>'phase' <> 'reveal' or s->'targetRevealed' is not distinct from 'null'::jsonb then raise exception '答えを公開してから次へ進んでください'; end if;
    if (s->>'round')::integer >= 5 then raise exception '全5戦が終了しています'; end if;
    ps := s->'players';
    select (value->>'id') into next_id
      from jsonb_array_elements(ps) with ordinality as p(value,ord)
      where ord = ((select ord from jsonb_array_elements(ps) with ordinality as q(value,ord) where value->>'id'=s->>'cluePlayerId') % jsonb_array_length(ps)) + 1;
    next_target := floor(random()*71)::integer + 15;
    update public.spectrum_room_secrets set target=next_target,target_player_id=next_id where room_code=room;
    s := jsonb_set(s,'{round}',to_jsonb((s->>'round')::integer+1));
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(next_id));
    if exists(select 1 from jsonb_array_elements(coalesce(s->'promptHistory','[]'::jsonb)) as used where used->>'left'=p_payload->'prompt'->>'left' and used->>'right'=p_payload->'prompt'->>'right') then
      raise exception 'この5戦ですでに使われたお題です';
    end if;
    s := jsonb_set(s,'{prompt}',coalesce(p_payload->'prompt',jsonb_build_object('left','冷たい','right','熱い')));
    s := jsonb_set(s,'{promptHistory}',coalesce(s->'promptHistory','[]'::jsonb) || jsonb_build_array(s->'prompt'),true);
    s := jsonb_set(s,'{clue}',to_jsonb(''));
    s := jsonb_set(s,'{phase}',to_jsonb('clue'));
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

revoke all on function public.spectrum_create_room(text,text,text,jsonb,integer) from public;
revoke all on function public.spectrum_join_room(text,text,text) from public;
revoke all on function public.spectrum_get_room(text,text) from public;
revoke all on function public.spectrum_game_action(text,text,text,jsonb) from public;
grant execute on function public.spectrum_create_room(text,text,text,jsonb,integer) to anon, authenticated;
grant execute on function public.spectrum_join_room(text,text,text) to anon, authenticated;
grant execute on function public.spectrum_get_room(text,text) to anon, authenticated;
grant execute on function public.spectrum_game_action(text,text,text,jsonb) to anon, authenticated;

-- Realtime sends public_state updates to all clients; no secret target is stored in this table.
do $$ begin
  alter publication supabase_realtime add table public.spectrum_rooms;
exception when duplicate_object then null;
when undefined_object then null;
end $$;


-- Explicit exit is different from closing the tab. Closing/reloading preserves membership.
-- The room row is locked, so exit and guesses cannot race.
create or replace function public.spectrum_leave_room(p_room_code text, p_player_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  room text := upper(trim(p_room_code)); s jsonb; ps jsonb := '[]'::jsonb;
  item jsonb; new_host text; new_clue text; remaining integer;
  did_clue_leave boolean; answered jsonb := '[]'::jsonb;
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

  if remaining < 2 and s->>'phase' not in ('lobby','finished') then
    -- A match requires >=2 players. Pause by returning to the lobby and reset
    -- the incomplete match; scores are retained until host starts again.
    s := jsonb_set(s,'{phase}',to_jsonb('lobby'));
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(new_host));
    s := jsonb_set(s,'{round}',to_jsonb(1));
    s := jsonb_set(s,'{clue}',to_jsonb(''));
    s := jsonb_set(s,'{answeredPlayerIds}','[]'::jsonb);
    s := jsonb_set(s,'{lastRoundResults}','[]'::jsonb);
    s := jsonb_set(s,'{targetRevealed}','null'::jsonb);
    s := jsonb_set(s,'{promptHistory}','[]'::jsonb);
    delete from public.spectrum_player_guesses where room_code=room;
    update public.spectrum_room_secrets set target=floor(random()*71)::integer+15,target_player_id=new_host where room_code=room;
  elsif did_clue_leave and s->>'phase' in ('clue','guess') then
    -- A round without a clue-giver cannot be completed. Restart only that round.
    new_clue := new_host;
    s := jsonb_set(s,'{cluePlayerId}',to_jsonb(new_clue));
    s := jsonb_set(s,'{phase}',to_jsonb('clue'));
    s := jsonb_set(s,'{clue}',to_jsonb(''));
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
      s := jsonb_set(s,'{phase}',to_jsonb('reveal'));
    end if;
  end if;
  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=room;
  return jsonb_build_object('left',true,'closed',false);
end $$;
revoke all on function public.spectrum_leave_room(text,text) from public;
grant execute on function public.spectrum_leave_room(text,text) to anon, authenticated;
