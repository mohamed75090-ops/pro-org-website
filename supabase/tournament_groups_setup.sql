-- PROFESSIONAL ESPORTS: Tournament-only groups A-D
-- Adds group assignment to tournament applications only. Scrim tables are untouched.

alter table public.tournament_team_applications
  add column if not exists group_name text;

-- Preserve previously accepted tournament teams by placing them in Group A.
update public.tournament_team_applications
set group_name = 'A'
where status = 'accepted'
  and (group_name is null or group_name not in ('A','B','C','D'));

-- Ensure only the four predefined groups can be stored, and every accepted
-- tournament team must belong to one of them.
alter table public.tournament_team_applications
  drop constraint if exists tournament_team_applications_group_name_check;

alter table public.tournament_team_applications
  add constraint tournament_team_applications_group_name_check
  check (
    (group_name is null or group_name in ('A','B','C','D'))
    and (status <> 'accepted' or coalesce(group_name in ('A','B','C','D'), false))
  );

create index if not exists tournament_team_apps_group_idx
  on public.tournament_team_applications(tournament_id, group_name, status, slot_number);

comment on column public.tournament_team_applications.group_name
  is 'Tournament-only group assignment: A, B, C, or D. Scrim registrations are not affected.';
