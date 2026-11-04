-- PROFESSIONAL ESPORTS: Tournament registration card stats + accepted-team visibility
-- Additive migration. Does not modify scrim tables or existing scrim registration behavior.

alter table public.tournaments
  add column if not exists accepted_teams_visible boolean not null default true;

create or replace function public.get_public_tournament_registration_stats(p_tournament_id uuid)
returns table(
  registered_count bigint,
  accepted_count bigint,
  accepted_teams_visible boolean,
  accepted_teams jsonb
)
language sql
security definer
set search_path = public
as $$
  select
    count(a.id) filter (where a.status in ('pending','accepted','backup')) as registered_count,
    count(a.id) filter (where a.status = 'accepted') as accepted_count,
    coalesce(t.accepted_teams_visible, true) as accepted_teams_visible,
    case
      when coalesce(t.accepted_teams_visible, true) then
        coalesce(
          jsonb_agg(
            jsonb_build_object(
              'team_name', a.team_name,
              'team_tag', a.team_tag,
              'slot_number', a.slot_number,
              'group_name', a.group_name
            )
            order by a.slot_number nulls last, a.team_tag
          ) filter (where a.status = 'accepted'),
          '[]'::jsonb
        )
      else '[]'::jsonb
    end as accepted_teams
  from public.tournaments t
  left join public.tournament_team_applications a
    on a.tournament_id = t.id
  where t.id = p_tournament_id
    and t.status in ('published','completed')
  group by t.id, t.accepted_teams_visible;
$$;

revoke all on function public.get_public_tournament_registration_stats(uuid) from public;
grant execute on function public.get_public_tournament_registration_stats(uuid) to anon, authenticated;

comment on column public.tournaments.accepted_teams_visible is
  'Controls whether accepted tournament teams are displayed on public tournament pages. Does not delete applications.';
