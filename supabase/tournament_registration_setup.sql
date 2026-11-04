-- PROFESSIONAL ESPORTS: Independent tournament announcements and team applications
-- Safe additive migration: keeps existing tournaments, scrims, teams and registrations intact.

alter table public.tournaments
  add column if not exists poster_url text,
  add column if not exists registration_opens_at timestamptz,
  add column if not exists registration_closes_at timestamptz,
  add column if not exists max_teams integer not null default 25,
  add column if not exists registration_enabled boolean not null default false;

create table if not exists public.tournament_team_applications (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references public.tournaments(id) on delete cascade,
  team_name text not null,
  team_tag text not null,
  team_representative text not null,
  access_code text not null unique,
  status text not null default 'pending' check (status in ('pending','accepted','backup','rejected')),
  slot_number integer,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists tournament_team_apps_tournament_idx
  on public.tournament_team_applications(tournament_id, created_at desc);

alter table public.tournament_team_applications enable row level security;
grant select, update on public.tournament_team_applications to authenticated;
drop policy if exists "Tournament managers read applications" on public.tournament_team_applications;
create policy "Tournament managers read applications"
on public.tournament_team_applications for select to authenticated
using (exists (select 1 from public.profiles p where p.id=auth.uid()
  and lower(trim(coalesce(p.role,''))) in ('founder','admin','tournament_manager')));
drop policy if exists "Tournament managers update applications" on public.tournament_team_applications;
create policy "Tournament managers update applications"
on public.tournament_team_applications for update to authenticated
using (exists (select 1 from public.profiles p where p.id=auth.uid()
  and lower(trim(coalesce(p.role,''))) in ('founder','admin','tournament_manager')))
with check (exists (select 1 from public.profiles p where p.id=auth.uid()
  and lower(trim(coalesce(p.role,''))) in ('founder','admin','tournament_manager')));

create or replace function public.submit_tournament_team_application(
  p_tournament_id uuid, p_team_name text, p_team_tag text, p_team_representative text
) returns table(access_code text, status text)
language plpgsql security definer set search_path=public
as $$
declare t public.tournaments%rowtype; v_code text;
begin
  select * into t from public.tournaments where id=p_tournament_id and status='published';
  if not found then raise exception 'البطولة غير متاحة للتسجيل'; end if;
  if not coalesce(t.registration_enabled,false) then raise exception 'التسجيل غير مفتوح لهذه البطولة'; end if;
  if t.registration_opens_at is not null and now()<t.registration_opens_at then raise exception 'لم يبدأ التسجيل بعد'; end if;
  if t.registration_closes_at is not null and now()>t.registration_closes_at then raise exception 'انتهى التسجيل'; end if;
  if length(trim(coalesce(p_team_name,'')))<2 or length(trim(coalesce(p_team_tag,'')))<2
     or length(trim(coalesce(p_team_representative,'')))<2 then raise exception 'أكمل بيانات الفريق'; end if;
  if exists(select 1 from public.tournament_team_applications a where a.tournament_id=p_tournament_id and lower(a.team_tag)=lower(trim(p_team_tag))) then
    raise exception 'هذا الفريق أرسل طلباً لهذه البطولة من قبل';
  end if;
  if (select count(*) from public.tournament_team_applications a where a.tournament_id=p_tournament_id and a.status in ('pending','accepted','backup')) >= greatest(coalesce(t.max_teams,25),1) then
    raise exception 'اكتمل عدد طلبات الفرق لهذه البطولة';
  end if;
  v_code := upper(substr(encode(gen_random_bytes(6),'hex'),1,10));
  insert into public.tournament_team_applications(tournament_id,team_name,team_tag,team_representative,access_code)
  values(p_tournament_id,trim(p_team_name),upper(trim(p_team_tag)),trim(p_team_representative),v_code);
  return query select v_code,'pending'::text;
end; $$;
revoke all on function public.submit_tournament_team_application(uuid,text,text,text) from public;
grant execute on function public.submit_tournament_team_application(uuid,text,text,text) to anon, authenticated;

create or replace function public.get_tournament_application_status(p_access_code text)
returns table(status text,tournament_name text,team_name text,team_tag text,team_representative text,slot_number integer)
language sql security definer set search_path=public
as $$
 select a.status,t.name,a.team_name,a.team_tag,a.team_representative,a.slot_number
 from public.tournament_team_applications a
 join public.tournaments t on t.id=a.tournament_id
 where upper(a.access_code)=upper(trim(p_access_code))
 limit 1;
$$;
revoke all on function public.get_tournament_application_status(text) from public;
grant execute on function public.get_tournament_application_status(text) to anon, authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('tournament-posters','tournament-posters',true,10485760,array['image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=true,file_size_limit=10485760,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "Tournament managers upload posters" on storage.objects;
create policy "Tournament managers upload posters" on storage.objects for insert to authenticated
with check(bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid()
and lower(trim(coalesce(p.role,''))) in ('founder','admin','tournament_manager')));
drop policy if exists "Tournament managers update posters" on storage.objects;
create policy "Tournament managers update posters" on storage.objects for update to authenticated
using(bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid()
and lower(trim(coalesce(p.role,''))) in ('founder','admin','tournament_manager')))
with check(bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid()
and lower(trim(coalesce(p.role,''))) in ('founder','admin','tournament_manager')));
drop policy if exists "Tournament managers delete posters" on storage.objects;
create policy "Tournament managers delete posters" on storage.objects for delete to authenticated
using(bucket_id='tournament-posters' and exists(select 1 from public.profiles p where p.id=auth.uid()
and lower(trim(coalesce(p.role,''))) in ('founder','admin','tournament_manager')));
