create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.tournament_application_ip_limits (
  ip inet primary key,
  window_started_at timestamptz not null default now(),
  minute_attempts integer not null default 0,
  day_started_at date not null default ((now() at time zone 'UTC')::date),
  daily_attempts integer not null default 0
);
create index if not exists tournament_application_ip_day_idx
  on private.tournament_application_ip_limits(day_started_at);

alter table private.tournament_application_ip_limits enable row level security;
revoke all on table private.tournament_application_ip_limits from public, anon, authenticated;

create or replace function public.submit_tournament_team_application(
  p_tournament_id uuid,
  p_team_name text,
  p_team_tag text,
  p_team_representative text
)
returns table(access_code text, status text)
language plpgsql
security definer
set search_path = ''
as $function$
declare
  t public.tournaments%rowtype;
  v_code text;
  v_attempts integer := 0;
  v_headers jsonb;
  v_ip_text text;
  v_ip inet;
  v_minute_attempts integer;
  v_daily_attempts integer;
begin
  if p_tournament_id is null then
    raise exception 'البطولة غير متاحة للتسجيل';
  end if;

  v_headers := coalesce(
    nullif(current_setting('request.headers', true), '')::jsonb,
    '{}'::jsonb
  );
  v_ip_text := split_part(
    coalesce(
      nullif(trim(v_headers ->> 'x-forwarded-for'), ''),
      nullif(trim(v_headers ->> 'x-real-ip'), ''),
      ''
    ),
    ',',
    1
  );

  if nullif(trim(v_ip_text), '') is null then
    raise exception 'تعذر التحقق من مصدر الاتصال. حاول مرة أخرى';
  end if;

  begin
    v_ip := trim(v_ip_text)::inet;
  exception when invalid_text_representation then
    raise exception 'تعذر التحقق من مصدر الاتصال. حاول مرة أخرى';
  end;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_tournament_id::text, 734922)
  );

  select tr.*
    into t
    from public.tournaments as tr
   where tr.id = p_tournament_id
     and tr.status = 'published'
   for update;

  if not found then
    raise exception 'البطولة غير متاحة للتسجيل';
  end if;

  if not coalesce(t.registration_enabled, false) then
    raise exception 'التسجيل غير مفتوح لهذه البطولة';
  end if;

  if t.registration_opens_at is not null
     and now() < t.registration_opens_at then
    raise exception 'لم يبدأ التسجيل بعد';
  end if;

  if t.registration_closes_at is not null
     and now() > t.registration_closes_at then
    raise exception 'انتهى التسجيل';
  end if;

  if length(trim(coalesce(p_team_name, ''))) < 2
     or length(trim(coalesce(p_team_tag, ''))) < 2
     or length(trim(coalesce(p_team_representative, ''))) < 2 then
    raise exception 'أكمل بيانات الفريق';
  end if;

  if char_length(trim(p_team_name)) > 80
     or char_length(trim(p_team_tag)) > 24
     or char_length(trim(p_team_representative)) > 60 then
    raise exception 'تأكد من طول اسم الفريق والاختصار واسم الممثل';
  end if;

  if exists (
    select 1
      from public.tournament_team_applications as a
     where a.tournament_id = p_tournament_id
       and lower(a.team_tag) = lower(trim(p_team_tag))
  ) then
    raise exception 'هذا الفريق أرسل طلباً لهذه البطولة من قبل';
  end if;

  if (
    select count(*)
      from public.tournament_team_applications as a
     where a.tournament_id = p_tournament_id
       and a.status in ('pending', 'accepted', 'backup')
  ) >= greatest(coalesce(t.max_teams, 25), 1) then
    raise exception 'اكتمل عدد طلبات الفرق لهذه البطولة';
  end if;

  delete from private.tournament_application_ip_limits
   where day_started_at < (now() at time zone 'UTC')::date - 2;

  insert into private.tournament_application_ip_limits (
    ip, window_started_at, minute_attempts, day_started_at, daily_attempts
  )
  values (v_ip, now(), 1, (now() at time zone 'UTC')::date, 1)
  on conflict (ip) do update
     set window_started_at = case
           when private.tournament_application_ip_limits.window_started_at < now() - interval '1 minute'
           then now()
           else private.tournament_application_ip_limits.window_started_at
         end,
         minute_attempts = case
           when private.tournament_application_ip_limits.window_started_at < now() - interval '1 minute'
           then 1
           else private.tournament_application_ip_limits.minute_attempts + 1
         end,
         day_started_at = case
           when private.tournament_application_ip_limits.day_started_at < (now() at time zone 'UTC')::date
           then (now() at time zone 'UTC')::date
           else private.tournament_application_ip_limits.day_started_at
         end,
         daily_attempts = case
           when private.tournament_application_ip_limits.day_started_at < (now() at time zone 'UTC')::date
           then 1
           else private.tournament_application_ip_limits.daily_attempts + 1
         end
  returning minute_attempts, daily_attempts
       into v_minute_attempts, v_daily_attempts;

  if v_minute_attempts > 10 then
    raise exception 'طلبات كثيرة من نفس الشبكة. انتظر دقيقة ثم حاول مرة أخرى';
  end if;

  if v_daily_attempts > 50 then
    raise exception 'تم الوصول إلى الحد اليومي لطلبات التسجيل من هذه الشبكة';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(734922, 1);

  loop
    v_attempts := v_attempts + 1;

    if v_attempts > 10000 then
      raise exception 'لا توجد أكواد رباعية متاحة';
    end if;

    v_code := pg_catalog.lpad(
      pg_catalog.floor(pg_catalog.random() * 10000)::integer::text,
      4,
      '0'
    );

    exit when not exists (
      select 1
        from public.tournament_team_applications as a
       where a.access_code = v_code
    );
  end loop;

  insert into public.tournament_team_applications (
    tournament_id, team_name, team_tag, team_representative, access_code
  )
  values (
    p_tournament_id, trim(p_team_name), upper(trim(p_team_tag)),
    trim(p_team_representative), v_code
  );

  return query select v_code, 'pending'::text;
end;
$function$;

alter function public.can_manage_mvp_photos() set search_path = '';
alter function public.ensure_player_profile_on_signup() set search_path = '';
alter function public.get_public_scrim_accepted_teams() set search_path = '';
alter function public.get_public_tournament_registration_stats(uuid) set search_path = '';
alter function public.get_role_management_users() set search_path = '';
alter function public.get_site_analytics() set search_path = '';
alter function public.guard_profile_role_changes() set search_path = '';
alter function public.record_site_login() set search_path = '';
alter function public.save_my_player_profile(text, text) set search_path = '';
alter function public.scrim_team_center_by_code(text) set search_path = '';
alter function public.set_user_role(uuid, text) set search_path = '';

create or replace function public.review_tournament_team_application(
  p_application_id uuid,
  p_action text,
  p_group_name text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_app public.tournament_team_applications%rowtype;
begin
  if auth.uid() is null then
    raise exception 'يجب تسجيل الدخول أولاً';
  end if;

  if not exists (
    select 1
      from public.profiles as p
     where p.id = auth.uid()
       and lower(trim(coalesce(p.role, ''))) in (
         'founder', 'admin', 'organizer', 'tournament_manager'
       )
  ) then
    raise exception 'ليس لديك صلاحية إدارة طلبات البطولة';
  end if;

  if p_action not in ('accepted', 'backup', 'rejected', 'move') then
    raise exception 'إجراء غير صالح';
  end if;

  if p_action in ('accepted', 'move')
     and (p_group_name is null or p_group_name not in ('A', 'B', 'C', 'D')) then
    raise exception 'اختر المجموعة A أو B أو C أو D';
  end if;

  select *
    into v_app
    from public.tournament_team_applications
   where id = p_application_id
   for update;

  if not found then
    raise exception 'طلب التسجيل غير موجود';
  end if;

  perform 1
    from public.tournaments
   where id = v_app.tournament_id
   for update;

  if p_action = 'accepted' then
    if v_app.status not in ('pending', 'backup') then
      raise exception 'لا يمكن قبول الطلب بحالته الحالية';
    end if;

    update public.tournament_team_applications
       set status = 'accepted',
           group_name = p_group_name,
           slot_number = null,
           updated_at = pg_catalog.now()
     where id = p_application_id;

  elsif p_action = 'move' then
    if v_app.status <> 'accepted' then
      raise exception 'يمكن نقل الفرق المقبولة فقط';
    end if;

    update public.tournament_team_applications
       set group_name = p_group_name,
           slot_number = null,
           updated_at = pg_catalog.now()
     where id = p_application_id;

  else
    update public.tournament_team_applications
       set status = p_action,
           group_name = null,
           slot_number = null,
           updated_at = pg_catalog.now()
     where id = p_application_id;
  end if;

  with ranked as (
    select
      id,
      row_number() over (
        partition by group_name
        order by created_at asc, id asc
      ) + 2 as new_slot
    from public.tournament_team_applications
    where tournament_id = v_app.tournament_id
      and status = 'accepted'
      and group_name in ('A', 'B', 'C', 'D')
  )
  update public.tournament_team_applications as a
     set slot_number = ranked.new_slot
    from ranked
   where a.id = ranked.id;
end;
$function$;
