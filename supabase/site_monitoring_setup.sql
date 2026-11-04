-- PROFESSIONAL ESPORTS: Site monitoring and WhatsApp profile groundwork
-- Additive only. WhatsApp verification will be connected in a later phase.

create table if not exists public.user_contact_details (
  user_id uuid primary key references auth.users(id) on delete cascade,
  whatsapp_number text not null unique,
  whatsapp_verified_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint user_contact_details_whatsapp_length check (length(whatsapp_number) between 8 and 15)
);
alter table public.user_contact_details enable row level security;
revoke all on public.user_contact_details from anon, authenticated;

create or replace function public.save_my_whatsapp_number(p_number text)
returns void
language plpgsql
security definer
set search_path = public, auth
as $
declare v_number text;
begin
  if auth.uid() is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  v_number := regexp_replace(coalesce(p_number,''), '[^0-9]', '', 'g');
  if length(v_number) < 8 or length(v_number) > 15 then
    raise exception 'أدخل رقم واتساب دولياً مع مفتاح الدولة';
  end if;
  insert into public.user_contact_details(user_id, whatsapp_number, whatsapp_verified_at, updated_at)
  values(auth.uid(), v_number, null, now())
  on conflict(user_id) do update
    set whatsapp_number=excluded.whatsapp_number,
        whatsapp_verified_at=null,
        updated_at=now();
exception when unique_violation then
  raise exception 'رقم الواتساب مرتبط بحساب آخر';
end;
$;
revoke all on function public.save_my_whatsapp_number(text) from public, anon;
grant execute on function public.save_my_whatsapp_number(text) to authenticated;

create table if not exists public.site_login_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create index if not exists site_login_events_created_at_idx
  on public.site_login_events(created_at desc);
create index if not exists site_login_events_user_id_idx
  on public.site_login_events(user_id);

create table if not exists public.site_visitor_daily (
  id uuid primary key default gen_random_uuid(),
  visitor_id uuid not null,
  visit_date date not null default (timezone('utc', now())::date),
  created_at timestamptz not null default now(),
  constraint site_visitor_daily_visitor_date_unique unique(visitor_id, visit_date)
);
create index if not exists site_visitor_daily_visit_date_idx
  on public.site_visitor_daily(visit_date desc);

alter table public.site_login_events enable row level security;
alter table public.site_visitor_daily enable row level security;
revoke all on public.site_login_events from anon, authenticated;
revoke all on public.site_visitor_daily from anon, authenticated;

create or replace function public.record_site_login()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;
  insert into public.site_login_events(user_id) values(auth.uid());
end;
$$;
revoke all on function public.record_site_login() from public, anon;
grant execute on function public.record_site_login() to authenticated;

create or replace function public.record_anonymous_site_visit(p_visitor_id uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is not null then return; end if;
  if p_visitor_id is null then raise exception 'معرّف الزيارة غير صالح'; end if;
  insert into public.site_visitor_daily(visitor_id, visit_date)
  values(p_visitor_id, timezone('utc', now())::date)
  on conflict(visitor_id, visit_date) do nothing;
end;
$$;
revoke all on function public.record_anonymous_site_visit(uuid) from public;
grant execute on function public.record_anonymous_site_visit(uuid) to anon, authenticated;

create or replace function public.get_site_analytics()
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_role text;
  v_result jsonb;
begin
  if auth.uid() is null then raise exception 'غير مصرح'; end if;

  select lower(trim(coalesce(p.role,''))) into v_role
  from public.profiles p where p.id=auth.uid();

  if coalesce(v_role,'') not in ('founder','admin','results_manager','tournament_manager') then
    raise exception 'ليس لديك صلاحية متابعة الموقع';
  end if;

  select jsonb_build_object(
    'registered_accounts', (select count(*) from auth.users),
    'login_total', (select count(*) from public.site_login_events),
    'login_today', (select count(*) from public.site_login_events
                    where created_at >= date_trunc('day', now())),
    'anonymous_visits_total', (select count(*) from public.site_visitor_daily),
    'anonymous_visits_today', (select count(*) from public.site_visitor_daily
                               where visit_date = timezone('utc', now())::date),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', u.id,
        'email', u.email,
        'display_name', coalesce(nullif(trim(p.display_name),''), nullif(split_part(coalesce(u.email,''),'@',1),''), 'مستخدم'),
        'whatsapp_number', c.whatsapp_number,
        'whatsapp_verified', c.whatsapp_verified_at is not null,
        'created_at', u.created_at
      ) order by u.created_at desc)
      from auth.users u
      left join public.profiles p on p.id=u.id
      left join public.user_contact_details c on c.user_id=u.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;
revoke all on function public.get_site_analytics() from public, anon;
grant execute on function public.get_site_analytics() to authenticated;
