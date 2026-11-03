-- PROFESSIONAL ESPORTS: Weekly MVP + Top 3
create table if not exists public.weekly_mvp_players (
  id uuid primary key default gen_random_uuid(),
  week_label text not null,
  rank_position integer not null check (rank_position between 1 and 3),
  player_name text not null,
  team_name text,
  photo_url text,
  eliminations integer not null default 0 check (eliminations >= 0),
  damage integer not null default 0 check (damage >= 0),
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint weekly_mvp_players_week_rank_unique unique (week_label, rank_position)
);

alter table public.weekly_mvp_players enable row level security;

grant select on public.weekly_mvp_players to anon, authenticated;
grant insert, update, delete on public.weekly_mvp_players to authenticated;

drop policy if exists "Public can read published weekly MVP" on public.weekly_mvp_players;
create policy "Public can read published weekly MVP"
on public.weekly_mvp_players for select
to anon, authenticated
using (is_published = true);

drop policy if exists "MVP managers can read all weekly MVP" on public.weekly_mvp_players;
create policy "MVP managers can read all weekly MVP"
on public.weekly_mvp_players for select
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role, '')) in ('founder', 'admin', 'results_manager')
  )
);

drop policy if exists "MVP managers can insert weekly MVP" on public.weekly_mvp_players;
create policy "MVP managers can insert weekly MVP"
on public.weekly_mvp_players for insert
to authenticated
with check (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role, '')) in ('founder', 'admin', 'results_manager')
  )
);

drop policy if exists "MVP managers can update weekly MVP" on public.weekly_mvp_players;
create policy "MVP managers can update weekly MVP"
on public.weekly_mvp_players for update
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role, '')) in ('founder', 'admin', 'results_manager')
  )
)
with check (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role, '')) in ('founder', 'admin', 'results_manager')
  )
);

drop policy if exists "MVP managers can delete weekly MVP" on public.weekly_mvp_players;
create policy "MVP managers can delete weekly MVP"
on public.weekly_mvp_players for delete
to authenticated
using (
  exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role, '')) in ('founder', 'admin', 'results_manager')
  )
);

-- Allow rank_position = 0 for the standalone Weekly MVP entry.
alter table public.weekly_mvp_players
  drop constraint if exists weekly_mvp_players_rank_position_check;

alter table public.weekly_mvp_players
  add constraint weekly_mvp_players_rank_position_check
  check (rank_position between 0 and 3);
