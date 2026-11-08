-- Align the tournament status constraint with the admin pause action.
alter table public.tournaments
drop constraint if exists tournaments_status_check;

alter table public.tournaments
add constraint tournaments_status_check
check (status = any (array['draft'::text, 'published'::text, 'paused'::text, 'completed'::text]));
