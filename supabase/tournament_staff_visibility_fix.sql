-- PROFESSIONAL ESPORTS: Ensure founder and authorized tournament staff can see/manage announcements
-- Run this migration in Supabase SQL Editor.

drop policy if exists "Tournament staff manage tournament announcements" on public.tournaments;
create policy "Tournament staff manage tournament announcements"
on public.tournaments
for all
to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in
        ('founder', 'admin', 'organizer', 'tournament_manager')
  )
)
with check (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in
        ('founder', 'admin', 'organizer', 'tournament_manager')
  )
);

drop policy if exists "Tournament staff manage tournament matches" on public.matches;
create policy "Tournament staff manage tournament matches"
on public.matches
for all
to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in
        ('founder', 'admin', 'organizer', 'tournament_manager')
  )
)
with check (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in
        ('founder', 'admin', 'organizer', 'tournament_manager')
  )
);

grant select, insert, update, delete on public.tournaments to authenticated;
grant select, insert, update, delete on public.matches to authenticated;
