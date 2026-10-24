-- ドノヘン？ v14: 任意の準備時間と本人限定のヒント自動保存。
-- Requires v13. Timers apply to newly started games; default is unlimited.
BEGIN;
do $$ begin if to_regprocedure('public.spectrum_v13_shuffle(jsonb,integer)') is null then raise exception '先にv13更新SQLを適用してください。'; end if; end $$;
alter table public.spectrum_prepared_hints add column if not exists draft text not null default '';
do $$ begin
 if not exists(select 1 from pg_constraint where conrelid='public.spectrum_prepared_hints'::regclass and conname='spectrum_prepared_hints_draft_length') then
  alter table public.spectrum_prepared_hints add constraint spectrum_prepared_hints_draft_length check(length(draft)<=100);
 end if;
end $$;

create or replace function public.spectrum_v14_hint_text(p_text text)
returns text language sql immutable strict set search_path=pg_catalog
as $$ select btrim(p_text,U&'\0009\000A\000B\000C\000D\0020\00A0\1680\2000\2001\2002\2003\2004\2005\2006\2007\2008\2009\200A\2028\2029\202F\205F\3000\FEFF') $$;

create or replace function public.spectrum_v14_save(p_room text,s jsonb,p_player text,p_payload jsonb)
returns void language plpgsql security definer set search_path=pg_catalog,public
as $$
declare own_count integer; h jsonb; num integer; seen integer[]:=array[]::integer[]; stored record;
begin
 if jsonb_typeof(p_payload->'matchId') is distinct from 'string' or p_payload->>'matchId' is distinct from s->>'matchId' then raise exception '前のゲームのヒントは保存できません。'; end if;
 if s->>'phase'<>'prepare' or s->>'hintBatchVersion'<>'1' then raise exception '今はヒントを保存できません。'; end if;
 if s->>'preparationDeadline' is null then raise exception '時間制限のある準備でのみ保存できます。'; end if;
 select count(*) into own_count from public.spectrum_prepared_hints where room_code=p_room and player_id=p_player;
 if jsonb_typeof(p_payload->'hints') is distinct from 'array' then raise exception 'ヒントの形式を確認してください。'; end if;
 if own_count not between 1 and 3 or jsonb_array_length(p_payload->'hints')<>own_count then raise exception '担当するヒントを確認してください。'; end if;
 for h in select value from jsonb_array_elements(p_payload->'hints') loop
  if jsonb_typeof(h)<>'object' or jsonb_typeof(h->'turnId') is distinct from 'number'
   or coalesce(h->>'turnId','') !~ '^[0-9]{1,2}$'
   or jsonb_typeof(h->'clue') is distinct from 'string' then raise exception 'ヒントの形式を確認してください。'; end if;
  num:=(h->>'turnId')::integer;
  if num=any(seen) or length(h->>'clue')>100 then raise exception 'ヒントは重複なく、100文字以内で入力してください。'; end if;
  select * into stored from public.spectrum_prepared_hints where room_code=p_room and turn_index=num and player_id=p_player;
  if not found then raise exception '自分のヒントだけ保存できます。'; end if;
  -- A late draft request cannot overwrite an explicit final submission.
  if stored.clue is null then
   update public.spectrum_prepared_hints set draft=h->>'clue' where room_code=p_room and turn_index=num and player_id=p_player;
  end if;
  seen:=array_append(seen,num);
 end loop;
end $$;

create or replace function public.spectrum_v14_timeout(p_room text,s jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare kept_order jsonb; kept_schedule jsonb; ready jsonb; original_count integer:=jsonb_array_length(s->'preparedTurnOrder'); total integer;
begin
 update public.spectrum_prepared_hints set clue=nullif(public.spectrum_v14_hint_text(draft),'') where room_code=p_room and clue is null;
 select coalesce(jsonb_agg(t.value order by t.ord),'[]'::jsonb),coalesce(jsonb_agg(h.player_id order by t.ord),'[]'::jsonb)
 into kept_order,kept_schedule
 from jsonb_array_elements(s->'preparedTurnOrder') with ordinality t(value,ord)
 join public.spectrum_prepared_hints h on h.room_code=p_room and h.turn_index=(t.value #>> '{}')::integer
 where h.clue is not null and exists(select 1 from jsonb_array_elements(s->'players') p where p->>'id'=h.player_id);
 total:=jsonb_array_length(kept_order);
 delete from public.spectrum_prepared_hints h where h.room_code=p_room and not exists(select 1 from jsonb_array_elements(kept_order) t where (t #>> '{}')::integer=h.turn_index);
 s:=s-'preparationDeadline';
 if total=0 then
  s:=s-'answerDeadline'-'countdownEndsAt'-'timedOutPlayerIds'-'matchStats'-'awardsEnabled'-'roundHistory'-'resultPlayers'
   -'totalRounds'-'clueSchedule'-'hintBatchVersion'-'preparedTurnOrder'-'preparedPlayerIds'-'preparationTimedOut'-'preparationSkippedCount';
  return s||jsonb_build_object('phase','lobby','round',1,'cluePlayerId',s->>'hostId','clue','','targetRevealed',null,
   'answeredPlayerIds','[]'::jsonb,'lastRoundResults','[]'::jsonb,'hintPoints',0,'promptHistory','[]'::jsonb,'preparationNotice','empty');
 end if;
 select coalesce(jsonb_agg(p->>'id'),'[]'::jsonb) into ready from jsonb_array_elements(s->'players') p
 where exists(select 1 from public.spectrum_prepared_hints h where h.room_code=p_room and h.player_id=p->>'id');
 return s||jsonb_build_object('phase','countdown','round',1,'totalRounds',total,'preparedTurnOrder',kept_order,
  'clueSchedule',kept_schedule,'cluePlayerId',kept_schedule->>0,'preparedPlayerIds',ready,'preparationTimedOut',true,
  'preparationSkippedCount',original_count-total,'countdownEndsAt',extract(epoch from clock_timestamp())*1000+3000);
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
  if num=any(seen) or length(public.spectrum_v14_hint_text(h->>'clue')) not between 1 and 100 then raise exception 'ヒントは重複なく、1〜100文字で入力してください。'; end if;
  select * into stored from public.spectrum_prepared_hints where room_code=p_room and turn_index=num and player_id=p_player;
  if not found then raise exception '自分が担当するヒントだけ提出できます。'; end if;
  if stored.clue is not null and stored.clue<>public.spectrum_v14_hint_text(h->>'clue') then raise exception '提出したヒントは変更できません。'; end if;
  update public.spectrum_prepared_hints set clue=public.spectrum_v14_hint_text(h->>'clue') where room_code=p_room and turn_index=num and player_id=p_player;
  seen:=array_append(seen,num);
 end loop;
 return public.spectrum_v12_ready(p_room,s);
end $$;

create or replace function public.spectrum_v12_prepared_hints(p_room text,p_player text)
returns jsonb language sql stable security definer set search_path=pg_catalog,public
as $$
 select coalesce(jsonb_agg(jsonb_build_object('turnId',h.turn_index,'prompt',h.prompt,
  'target',h.target,'clue',h.clue,'draft',h.draft) order by h.turn_index),'[]'::jsonb)
 from public.spectrum_prepared_hints h join public.spectrum_rooms r using(room_code)
 where h.room_code=p_room and h.player_id=p_player and r.public_state->>'phase'='prepare'
$$;

create or replace function public.spectrum_v12_prepare(p_room text,s jsonb)
returns jsonb language plpgsql security definer set search_path=pg_catalog,public
as $$
declare pool jsonb; turn record; turn_order jsonb:='[]'::jsonb; total integer;
begin
 s:=jsonb_set(s,'{clueSchedule}',public.spectrum_v13_shuffle(s->'players',coalesce((s->>'roundsPerPlayer')::integer,1)),true);
 s:=jsonb_set(s,'{cluePlayerId}',s->'clueSchedule'->0,true);
 s:=s-'countdownEndsAt'-'preparationDeadline'-'preparationTimedOut'-'preparationSkippedCount'-'preparationNotice';
 delete from public.spectrum_prepared_hints where room_code=p_room;
 total:=jsonb_array_length(s->'clueSchedule');
 select jsonb_agg(prompt) into pool from (select value as prompt from jsonb_array_elements(public.spectrum_v12_prompt_pool()) order by random() limit total) p;
 if jsonb_array_length(pool)<>total then raise exception 'お題を用意できませんでした。'; end if;
 for turn in select value #>> '{}' as player,ord::integer as num from jsonb_array_elements(s->'clueSchedule') with ordinality a(value,ord) loop
  insert into public.spectrum_prepared_hints(room_code,turn_index,player_id,prompt,target)
   values(p_room,turn.num,turn.player,pool->(turn.num-1),floor(random()*71)::integer+15);
  turn_order:=turn_order||jsonb_build_array(turn.num);
 end loop;
 s:=(s-'answerDeadline'-'timedOutPlayerIds')||jsonb_build_object('phase','prepare','hintBatchVersion',1,
  'preparedTurnOrder',turn_order,'preparedPlayerIds','[]'::jsonb,'prompt',jsonb_build_object('left','','right',''),
  'promptHistory','[]'::jsonb,'clue','','targetRevealed',null);
 if coalesce((s->>'preparationSeconds')::integer,0)>0 then
  s:=jsonb_set(s,'{preparationDeadline}',to_jsonb(extract(epoch from clock_timestamp())*1000+(s->>'preparationSeconds')::integer*1000),true);
 end if;
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
  if s->>'phase'<>'countdown' then
   s:=(s-'preparationDeadline')||jsonb_build_object('phase','countdown','countdownEndsAt',extract(epoch from clock_timestamp())*1000+3000);
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
 s:=s-'timedOutPlayerIds'-'answerDeadline'-'countdownEndsAt'-'preparationDeadline';
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
 if s->>'phase'='prepare' and s->>'preparationDeadline' is not null
  and (s->>'preparationDeadline')::numeric<=extract(epoch from clock_timestamp())*1000 then
  s:=public.spectrum_v14_timeout(p_room_code,s);
  s:=jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=clock_timestamp() where room_code=p_room_code;
  return;
 end if;
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
  s:=s-'preparationDeadline'-'preparationTimedOut'-'preparationSkippedCount'-'preparationNotice'-'countdownEndsAt'-'answerDeadline'-'timedOutPlayerIds'-'matchStats'-'awardsEnabled'-'roundHistory'-'resultPlayers'
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

create or replace function public.spectrum_v6_leave_impl(p_room_code text, p_player_id text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp
as $$
declare
  room text := upper(trim(p_room_code)); s jsonb; ps jsonb := '[]'::jsonb;
  item jsonb; prior_players jsonb; new_host text; new_clue text; remaining integer;
  did_clue_leave boolean; schedule jsonb; current_round integer; answered jsonb := '[]'::jsonb;
begin
  perform public.spectrum_expire_round(room);
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
  if p_action in ('save_hints','prepare_clues') and p_payload ? 'matchId' and p_payload->>'matchId' is distinct from s->>'matchId' then raise exception '前のゲームのヒントは送信できません。'; end if;
  if p_action in ('save_hints','prepare_clues') and s->>'phase'<>'prepare' and (s->>'preparationTimedOut'='true' or s->>'preparationNotice'='empty') then return public.spectrum_v6_get_impl(room,p_player_id); end if;
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
    if p_payload ? 'preparationSeconds' then
      if jsonb_typeof(p_payload->'preparationSeconds') is distinct from 'number' or coalesce(p_payload->>'preparationSeconds','') not in ('0','180','300') then raise exception '準備時間は制限なし・3分・5分です。'; end if;
      s:=jsonb_set(s,'{preparationSeconds}',to_jsonb((p_payload->>'preparationSeconds')::integer),true);
    end if;
  elsif p_action='start' then
    if s->>'hostId' <> p_player_id then raise exception 'ホストだけが開始できます'; end if;
    if s->>'phase' <> 'lobby' then raise exception 'ゲームはすでに始まっています'; end if;
    if jsonb_array_length(s->'players') < 2 then raise exception '2人以上で開始してください'; end if;
    delete from public.spectrum_prepared_hints where room_code=room;
    s := s - 'preparationDeadline' - 'preparationTimedOut' - 'preparationSkippedCount' - 'preparationNotice' - 'countdownEndsAt' - 'resultPlayers' - 'hintBatchVersion' - 'preparedTurnOrder' - 'preparedPlayerIds';
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
  elsif p_action='save_hints' then
    perform public.spectrum_v14_save(room,s,p_player_id,p_payload);
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
    s := s - 'answerDeadline' - 'timedOutPlayerIds' - 'matchStats' - 'awardsEnabled' - 'roundHistory' - 'preparationDeadline' - 'preparationTimedOut' - 'preparationSkippedCount' - 'preparationNotice' - 'countdownEndsAt' - 'resultPlayers' - 'hintBatchVersion' - 'preparedTurnOrder' - 'preparedPlayerIds';
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
  s := jsonb_set(s,'{preparationTimeVersion}',to_jsonb(1),true);
  s := jsonb_set(s,'{updatedAt}',to_jsonb(now()));
  update public.spectrum_rooms set public_state=s,updated_at=now() where room_code=room;
  if s->>'cluePlayerId'=p_player_id and s->>'phase'='clue' then
    select target into t from public.spectrum_room_secrets where room_code=room;
  end if;
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s,'target',t,'ownGuess',own_answer,'preparedHints',public.spectrum_v12_prepared_hints(room,p_player_id));
end $$;

create or replace function public.spectrum_game_action(
 p_room_code text,p_player_id text,p_action text,p_payload jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer set search_path = pg_catalog,public
as $$
declare caller uuid; room text := upper(trim(p_room_code)); result jsonb;
begin
  caller := public.spectrum_check_identity(p_player_id);
  if not public.spectrum_take_limit(caller::text,case when p_action='save_hints' then 'draft' else 'action' end,case when p_action='save_hints' then 90 else 60 end,60) then
    return jsonb_build_object('error',jsonb_build_object('code','RATE_LIMIT','message','操作が続いています。少し待って試してください。'));
  end if;
  begin
    perform public.spectrum_check_member(room,caller);
    if p_action is null or p_action not in ('settings','start','save_hints','prepare_clues','clue','guess','reveal','finish','restart','next_round')
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
    'preparationTimeVersion',1,'preparationSeconds',0,'endFlowVersion',1,'featuresVersion',1,'answerSeconds',0,'securityVersion',6,'rulesVersion',4,'roundsPerPlayer',1,'round',1,'cluePlayerId',p_player_id,'prompt',p_prompt,'promptHistory','[]'::jsonb,'clue','','phase','lobby',
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
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s||jsonb_build_object('preparationTimeVersion',1),'target',t,'ownGuess',own_answer,'preparedHints',public.spectrum_v12_prepared_hints(upper(trim(p_room_code)),p_player_id));
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
  return jsonb_build_object('serverNow',extract(epoch from clock_timestamp())*1000,'state',s||jsonb_build_object('preparationTimeVersion',1),'target',result_target);
end $$;

create or replace function public.spectrum_protocol() returns jsonb language sql stable security definer set search_path=pg_catalog,public as $$ select jsonb_build_object('version',6,'authRequired',true,'preparationVersion',1,'countdownVersion',1,'shuffleVersion',1,'preparationTimeVersion',1) $$;

revoke all on function public.spectrum_v14_save(text,jsonb,text,jsonb),public.spectrum_v14_timeout(text,jsonb),public.spectrum_v14_hint_text(text) from public,anon,authenticated;
COMMIT;
