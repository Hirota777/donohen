-- ドノヘン？ v13: 全員提出後3秒待ってから公開し、ヒント役順を周回ごとにシャッフル。
-- Requires v12. Existing assigned turns are retained; shuffle applies to new games.
BEGIN;
do $$ begin if to_regclass('public.spectrum_prepared_hints') is null then raise exception '先にv12更新SQLを適用してください。'; end if; end $$;
create or replace function public.spectrum_v13_shuffle(p_players jsonb,p_turns integer)
returns jsonb language plpgsql volatile security definer set search_path=pg_catalog,public
as $$
declare schedule jsonb:='[]'::jsonb; cycle jsonb; last_player text; i integer;
begin
 if p_turns not between 1 and 3 or jsonb_array_length(p_players) not between 2 and 12 then raise exception '人数と回数を確認してください。'; end if;
 for i in 1..p_turns loop
  select jsonb_agg(p->>'id' order by random()) into cycle from jsonb_array_elements(p_players) p;
  -- Every player gets one turn per cycle; avoid repeating an author across cycles.
  if cycle->>0=last_player then
   select jsonb_agg(value order by case when ord=1 then jsonb_array_length(cycle)+1 else ord end)
   into cycle from jsonb_array_elements(cycle) with ordinality a(value,ord);
  end if;
  schedule:=schedule||cycle;last_player:=cycle->>(jsonb_array_length(cycle)-1);
 end loop;
 return schedule;
end $$;

create or replace function public.spectrum_v12_prepare(p_room text,s jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare pool jsonb; turn record; turn_order jsonb:='[]'::jsonb; total integer;
begin
 s:=jsonb_set(s,'{clueSchedule}',public.spectrum_v13_shuffle(s->'players',coalesce((s->>'roundsPerPlayer')::integer,1)),true);
 s:=jsonb_set(s,'{cluePlayerId}',s->'clueSchedule'->0,true);
 s:=s-'countdownEndsAt';
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
  if s->>'phase'<>'countdown' then
   s:=s||jsonb_build_object('phase','countdown','countdownEndsAt',extract(epoch from clock_timestamp())*1000+3000);
  end if;
 end if;
 return s;
end $$;

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
 s:=s-'timedOutPlayerIds'-'answerDeadline'-'countdownEndsAt';
 seconds:=coalesce((s->>'answerSeconds')::integer,0);
 if seconds>0 then s:=jsonb_set(s,'{answerDeadline}',to_jsonb(extract(epoch from clock_timestamp())*1000+seconds*1000),true); end if;
 return s;
end $$;

create or replace function public.spectrum_expire_round(p_room_code text)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare s jsonb; missing jsonb;
begin
 select public_state into s from public.spectrum_rooms where room_code=p_room_code for update;
 if s->>'phase'='countdown' and s->>'countdownEndsAt' is not null
  and (s->>'countdownEndsAt')::numeric<=extract(epoch from clock_timestamp())*1000 then
  s:=public.spectrum_v12_activate(p_room_code,s,1);
  s:=jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=clock_timestamp() where room_code=p_room_code;
  return;
 end if;
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

create or replace function public.spectrum_v12_leave(p_room text,s jsonb,p_player text)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare prior_players jsonb:=s->'players'; ps jsonb; new_host text; current_round integer:=(s->>'round')::integer;
 was_preparing boolean:=s->>'phase' in ('prepare','countdown'); current_done boolean:=s->'targetRevealed' is distinct from 'null'::jsonb;
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
  s:=s-'countdownEndsAt'-'answerDeadline'-'timedOutPlayerIds'-'matchStats'-'awardsEnabled'-'roundHistory'-'resultPlayers'
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
    s := s - 'countdownEndsAt' - 'resultPlayers' - 'hintBatchVersion' - 'preparedTurnOrder' - 'preparedPlayerIds';
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory' - 'countdownEndsAt' - 'resultPlayers' - 'hintBatchVersion' - 'preparedTurnOrder' - 'preparedPlayerIds';
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

create or replace function public.spectrum_protocol() returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$ select jsonb_build_object('version',6,'authRequired',true,'preparationVersion',1,'countdownVersion',1,'shuffleVersion',1) $$;

revoke all on function public.spectrum_v13_shuffle(jsonb,integer) from public,anon,authenticated;
COMMIT;
