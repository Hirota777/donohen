-- ドノヘン？ v7: server deadlines, awards and updated scoring. Requires v6 security.
BEGIN;
do $$ begin
 if to_regprocedure('public.spectrum_protocol()') is null then raise exception '先にv6セキュリティ更新SQLを適用してください。'; end if;
 if public.spectrum_protocol()->>'version' is distinct from '6' then raise exception '先にv6セキュリティ更新SQLを適用してください。'; end if;
end $$;
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
  elsif p_action='finish' then
    if s->>'hostId'<>p_player_id then raise exception 'ホストだけが結果発表へ進めます'; end if;
    if s->>'phase'<>'reveal' or s->'targetRevealed' is not distinct from 'null'::jsonb
      or (s->>'round')::integer<coalesce((s->>'totalRounds')::integer,5) then
      raise exception '最終ラウンドの答え合わせを終えてから進んでください';
    end if;
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory';
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

  if remaining < 2 and s->>'phase' not in ('lobby','finished') and not (
    s->>'phase'='reveal' and s->'targetRevealed' is distinct from 'null'::jsonb
    and (s->>'round')::integer>=coalesce((s->>'totalRounds')::integer,5)) then
    -- A match requires >=2 players. Pause by returning to the lobby and reset
    -- the incomplete match; scores are retained until host starts again.
    s := jsonb_set(s,'{phase}',to_jsonb('lobby'::text));
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory';
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
revoke all on function public.spectrum_expire_round(text),public.spectrum_v6_create_impl(text,text,text,jsonb,integer),
 public.spectrum_v6_get_impl(text,text),public.spectrum_v6_action_impl(text,text,text,jsonb),public.spectrum_v6_leave_impl(text,text) from public,anon,authenticated;
update public.spectrum_rooms set public_state=jsonb_set(public_state,'{featuresVersion}',to_jsonb(1),true) where security_version=6;
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
revoke all on function public.spectrum_game_action(text,text,text,jsonb) from public,anon;
grant execute on function public.spectrum_game_action(text,text,text,jsonb) to authenticated;
COMMIT;
