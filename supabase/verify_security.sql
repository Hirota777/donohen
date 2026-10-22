-- Run in Supabase SQL Editor after the security update. No player data is selected.
select public.spectrum_protocol() as protocol;
select exists(select 1 from pg_publication_tables where pubname='supabase_realtime'
 and schemaname='public' and tablename='spectrum_rooms') as room_realtime_published;
select role_name,table_name,has_table_privilege(role_name,'public.'||table_name,'SELECT') as can_select
from (values('anon'),('authenticated')) roles(role_name)
cross join (values('spectrum_rooms'),('spectrum_room_secrets'),('spectrum_player_guesses'),('spectrum_memberships'),('spectrum_request_limits')) tables(table_name);

do $$
declare f record; allowed_auth oid[] := array[
 'public.spectrum_protocol()'::regprocedure::oid,
 'public.spectrum_create_room(text,text,text,jsonb,integer)'::regprocedure::oid,
 'public.spectrum_join_room(text,text,text)'::regprocedure::oid,
 'public.spectrum_get_room(text,text)'::regprocedure::oid,
 'public.spectrum_game_action(text,text,text,jsonb)'::regprocedure::oid,
 'public.spectrum_leave_room(text,text)'::regprocedure::oid];
begin
  for f in select p.oid,p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and left(p.proname,9)='spectrum_' loop
    if has_function_privilege('anon',f.oid,'EXECUTE') and f.oid <> 'public.spectrum_protocol()'::regprocedure::oid then
      raise exception 'FAIL: anon can execute %',f.signature;
    end if;
    if has_function_privilege('authenticated',f.oid,'EXECUTE') and not (f.oid=any(allowed_auth)) then
      raise exception 'FAIL: authenticated can execute private helper %',f.signature;
    end if;
  end loop;
end $$;

-- If cron is enabled, this must return one active job with a ten-minute schedule.
select jobname,schedule,active from cron.job where jobname='donohen-expired-rooms';
