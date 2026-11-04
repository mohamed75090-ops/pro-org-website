-- PROFESSIONAL ESPORTS: Founder-controlled role management and organizer access
-- Additive migration. Run in Supabase SQL Editor after publishing the matching website update.

-- The role column is already used by the website's profiles table.
-- This trigger prevents authenticated non-founders from changing anyone's role,
-- even if a permissive profiles UPDATE policy exists.
create or replace function public.guard_profile_role_changes()
returns trigger
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor_role text;
  v_founders integer;
begin
  if tg_op = 'INSERT' then
    -- Permit normal signup profiles, but never let a client create an elevated role.
    if auth.uid() is null then
      if coalesce(auth.role(),'') in ('anon','authenticated')
         and lower(trim(coalesce(new.role,''))) in
           ('founder','admin','organizer','results_manager','tournament_manager') then
        raise exception 'إنشاء صلاحيات إدارية متاح للمؤسس فقط';
      end if;
      return new;
    end if;
    select lower(trim(coalesce(p.role,''))) into v_actor_role
    from public.profiles p where p.id = auth.uid();
    if lower(trim(coalesce(new.role,''))) in
       ('founder','admin','organizer','results_manager','tournament_manager')
       and coalesce(v_actor_role,'') <> 'founder' then
      raise exception 'إنشاء صلاحيات إدارية متاح للمؤسس فقط';
    end if;
    if coalesce(v_actor_role,'') = 'founder'
       and lower(trim(coalesce(new.role,''))) not in
         ('founder','admin','organizer','results_manager','tournament_manager','player') then
      raise exception 'الرول المحدد غير معتمد';
    end if;
    return new;
  end if;

  if new.role is not distinct from old.role then
    return new;
  end if;

  -- Trusted server-side maintenance calls may have no auth.uid(); API clients may not bypass this.
  if auth.uid() is null then
    if coalesce(auth.role(),'') in ('anon','authenticated') then
      raise exception 'تغيير الرولات متاح للمؤسس فقط';
    end if;
    return new;
  end if;

  select lower(trim(coalesce(p.role,''))) into v_actor_role
  from public.profiles p where p.id = auth.uid();

  if coalesce(v_actor_role,'') <> 'founder' then
    raise exception 'تغيير الرولات متاح للمؤسس فقط';
  end if;

  if lower(trim(coalesce(old.role,''))) = 'founder'
     and lower(trim(coalesce(new.role,''))) <> 'founder' then
    perform pg_advisory_xact_lock(72390411);
    select count(*) into v_founders
    from public.profiles p where lower(trim(coalesce(p.role,''))) = 'founder';
    if v_founders <= 1 then
      raise exception 'لا يمكن إزالة صلاحية آخر مؤسس في النظام';
    end if;
  end if;

  if lower(trim(coalesce(new.role,''))) not in
    ('founder','admin','organizer','results_manager','tournament_manager','player') then
    raise exception 'الرول المحدد غير معتمد';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_guard_role_changes on public.profiles;
create trigger profiles_guard_role_changes
before update of role on public.profiles
for each row execute function public.guard_profile_role_changes();
drop trigger if exists profiles_guard_role_inserts on public.profiles;
create trigger profiles_guard_role_inserts
before insert on public.profiles
for each row execute function public.guard_profile_role_changes();

create table if not exists public.role_change_audit (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null references auth.users(id),
  target_user_id uuid not null references auth.users(id),
  old_role text,
  new_role text not null,
  created_at timestamptz not null default now()
);
alter table public.role_change_audit enable row level security;
revoke all on public.role_change_audit from anon, authenticated;

create or replace function public.get_role_management_users()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_role text;
  v_users jsonb;
begin
  if auth.uid() is null then raise exception 'غير مصرح'; end if;
  select lower(trim(coalesce(p.role,''))) into v_role
  from public.profiles p where p.id=auth.uid();
  if coalesce(v_role,'') <> 'founder' then raise exception 'إدارة الرولات للمؤسس فقط'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id',u.id,
    'display_name',coalesce(nullif(trim(p.display_name),''),nullif(pa.username,''),nullif(split_part(coalesce(u.email,''),'@',1),''),'مستخدم'),
    'role',coalesce(nullif(trim(p.role),''),'player')
  ) order by u.created_at desc),'[]'::jsonb)
  into v_users
  from auth.users u
  left join public.profiles p on p.id=u.id
  left join public.player_account_profiles pa on pa.user_id=u.id;
  return v_users;
end;
$$;
revoke all on function public.get_role_management_users() from public, anon;
grant execute on function public.get_role_management_users() to authenticated;

create or replace function public.set_user_role(p_user_id uuid,p_role text)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_actor_role text;
  v_old_role text;
  v_new_role text := lower(trim(coalesce(p_role,'')));
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  select lower(trim(coalesce(p.role,''))) into v_actor_role
  from public.profiles p where p.id=auth.uid();
  if coalesce(v_actor_role,'') <> 'founder' then raise exception 'تغيير الرولات للمؤسس فقط'; end if;
  if p_user_id is null then raise exception 'الحساب المحدد غير صالح'; end if;
  if v_new_role not in ('founder','admin','organizer','results_manager','tournament_manager','player') then
    raise exception 'الرول المحدد غير معتمد';
  end if;
  select lower(trim(coalesce(p.role,''))) into v_old_role
  from public.profiles p where p.id=p_user_id for update;
  if not found then raise exception 'لا يوجد ملف صلاحيات لهذا الحساب'; end if;
  update public.profiles set role=v_new_role where id=p_user_id;
  insert into public.role_change_audit(actor_user_id,target_user_id,old_role,new_role)
  values(auth.uid(),p_user_id,v_old_role,v_new_role);
end;
$$;
revoke all on function public.set_user_role(uuid,text) from public, anon;
grant execute on function public.set_user_role(uuid,text) to authenticated;

-- Organizer may manage tournament announcements, matches, applications and poster files.
drop policy if exists "Organizers manage tournaments" on public.tournaments;
create policy "Organizers manage tournaments" on public.tournaments
for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers manage tournament matches" on public.matches;
create policy "Organizers manage tournament matches" on public.matches
for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers manage tournament applications" on public.tournament_team_applications;
create policy "Organizers manage tournament applications" on public.tournament_team_applications
for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers upload tournament posters" on storage.objects;
create policy "Organizers upload tournament posters" on storage.objects
for insert to authenticated
with check (bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers update tournament posters" on storage.objects;
create policy "Organizers update tournament posters" on storage.objects
for update to authenticated
using (bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers delete tournament posters" on storage.objects;
create policy "Organizers delete tournament posters" on storage.objects
for delete to authenticated
using (bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

-- Organizer access to the existing scrim/team/room workflow.
drop policy if exists "Organizers manage scrims" on public.scrims;
create policy "Organizers manage scrims" on public.scrims for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers manage teams" on public.teams;
create policy "Organizers manage teams" on public.teams for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers manage scrim applications" on public.scrim_team_applications;
create policy "Organizers manage scrim applications" on public.scrim_team_applications for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers manage scrim registrations" on public.scrim_registrations;
create policy "Organizers manage scrim registrations" on public.scrim_registrations for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers manage scrim rooms" on public.scrim_matches;
create policy "Organizers manage scrim rooms" on public.scrim_matches for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));

drop policy if exists "Organizers manage scrim team access" on public.scrim_team_access;
create policy "Organizers manage scrim team access" on public.scrim_team_access for all to authenticated
using (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'))
with check (exists(select 1 from public.profiles p where p.id=auth.uid() and lower(trim(coalesce(p.role,'')))='organizer'));
