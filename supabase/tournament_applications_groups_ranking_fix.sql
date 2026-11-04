-- PROFESSIONAL ESPORTS
-- Tournament application visibility, secure review, and automatic group ranking.
-- Group numbering starts at 3 independently in every group (A/B/C/D).

alter table public.tournament_team_applications
  add column if not exists group_name text;

grant select, update on public.tournament_team_applications to authenticated;

drop policy if exists "Tournament managers read applications" on public.tournament_team_applications;
create policy "Tournament managers read applications"
on public.tournament_team_applications
for select to authenticated
using (
  exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in
          ('founder', 'admin', 'organizer', 'tournament_manager')
  )
);

drop policy if exists "Tournament managers update applications" on public.tournament_team_applications;
create policy "Tournament managers update applications"
on public.tournament_team_applications
for update to authenticated
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

create or replace function public.review_tournament_team_application(
  p_application_id uuid,
  p_action text,
  p_group_name text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_app public.tournament_team_applications%rowtype;
begin
  if not exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and lower(trim(coalesce(p.role, ''))) in
          ('founder', 'admin', 'organizer', 'tournament_manager')
  ) then
    raise exception 'ليس لديك صلاحية إدارة طلبات البطولة';
  end if;

  if p_action not in ('accepted', 'backup', 'rejected', 'move') then
    raise exception 'إجراء غير صالح';
  end if;

  if p_action in ('accepted', 'move')
     and p_group_name not in ('A', 'B', 'C', 'D') then
    raise exception 'اختر المجموعة A أو B أو C أو D';
  end if;

  select a.*
    into v_app
  from public.tournament_team_applications a
  where a.id = p_application_id
  for update;

  if not found then
    raise exception 'طلب التسجيل غير موجود';
  end if;

  -- Serialize changes for the same tournament to prevent duplicate ranks.
  perform 1
  from public.tournaments t
  where t.id = v_app.tournament_id
  for update;

  if p_action = 'accepted' then
    if v_app.status not in ('pending', 'backup') then
      raise exception 'لا يمكن قبول هذا الطلب بحالته الحالية';
    end if;

    update public.tournament_team_applications
    set status = 'accepted',
        group_name = p_group_name,
        slot_number = null,
        updated_at = now()
    where id = p_application_id;

  elsif p_action = 'move' then
    if v_app.status <> 'accepted' then
      raise exception 'يمكن نقل الفرق المقبولة فقط';
    end if;

    update public.tournament_team_applications
    set group_name = p_group_name,
        slot_number = null,
        updated_at = now()
    where id = p_application_id;

  else
    update public.tournament_team_applications
    set status = p_action,
        group_name = null,
        slot_number = null,
        updated_at = now()
    where id = p_application_id;
  end if;

  -- Recalculate each group separately. Every group's first team is rank 3.
  with ranked as (
    select
      a.id,
      row_number() over (
        partition by a.group_name
        order by a.slot_number nulls last, a.created_at, a.id
      ) + 2 as new_slot
    from public.tournament_team_applications a
    where a.tournament_id = v_app.tournament_id
      and a.status = 'accepted'
      and a.group_name in ('A', 'B', 'C', 'D')
  )
  update public.tournament_team_applications a
  set slot_number = ranked.new_slot
  from ranked
  where a.id = ranked.id;
end;
$$;

revoke all on function public.review_tournament_team_application(uuid, text, text) from public;
grant execute on function public.review_tournament_team_application(uuid, text, text)
  to authenticated;
