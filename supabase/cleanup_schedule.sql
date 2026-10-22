-- Run after the main security SQL. No application role can invoke cleanup.
create extension if not exists pg_cron;
select cron.schedule('donohen-expired-rooms','*/10 * * * *','select public.spectrum_cleanup_expired();');
