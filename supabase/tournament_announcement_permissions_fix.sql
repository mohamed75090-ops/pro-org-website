-- PROFESSIONAL ESPORTS: Repair tournament announcement permissions
-- Allows tournament managers to create/read/update/delete tournaments.
-- Public visitors can read published and completed announcements only.
alter table public.tournaments enable row level security;

grant select on public.tournaments to anon, authenticated;
grant insert, update, delete on public.tournaments to authenticated;

drop policy if exists "Public can read published tournaments" on public.tournaments;
create policy "Public can read published tournaments"
on public.tournaments for select
to anon, authenticated
using (status in ('published','completed'));

drop policy if exists "Tournament staff manage tournaments" on public.tournaments;
create policy "Tournament staff manage tournaments"
on public.tournaments for all
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role,''))) in ('founder','admin','organizer','tournament_manager')
  )
)
with check (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role,''))) in ('founder','admin','organizer','tournament_manager')
  )
);

-- RLS remains the authority for row-level access.
grant select, insert, update, delete on public.tournaments to authenticated;
