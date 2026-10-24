-- ドノヘン？ v10: opt-in public result cards; requires v9.
BEGIN;
do $$ begin
 if not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname='spectrum_game_action' and pg_get_functiondef(p.oid) like '%''finish''%') then
  raise exception '先にv9更新SQLを適用してください。';
 end if;
end $$;
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
  select p into player from jsonb_array_elements(s->'players') p where p->>'id'=p_player_id;
  select r into best from jsonb_array_elements(coalesce(s->'roundHistory','[]'::jsonb)) r
    where r->>'cluePlayerId'=p_player_id and jsonb_array_length(r->'results')>0
    order by (select avg((v->>'points')::numeric) from jsonb_array_elements(r->'results') v) desc,(r->>'round')::integer limit 1;
  if best is not null then select avg((r->>'points')::numeric) into average from jsonb_array_elements(best->'results') r; end if;
  insert into public.spectrum_result_shares(owner_id,match_key,metadata,png)
  values(caller,key,jsonb_build_object('name',player->>'name','score',(player->>'score')::integer,
    'rank',(select count(*)+1 from jsonb_array_elements(s->'players') p where (p->>'score')::integer>(player->>'score')::integer),
    'playerCount',jsonb_array_length(s->'players'),'rounds',coalesce((s->>'totalRounds')::integer,(s->>'round')::integer),
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
