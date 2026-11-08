-- Keep the match status constraint aligned with the admin UI pause action.
alter table public.matches
drop constraint if exists matches_status_check;

alter table public.matches
add constraint matches_status_check
check (status = any (array['draft'::text, 'published'::text, 'paused'::text, 'completed'::text]));
