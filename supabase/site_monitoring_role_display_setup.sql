-- PROFESSIONAL ESPORTS: expose each account's current role in site monitoring.
-- Keeps the existing authorization check and account fields.

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
    'login_today', (select count(*) from public.site_login_events where created_at >= date_trunc('day', now())),
    'anonymous_visits_total', (select count(*) from public.site_visitor_daily),
    'anonymous_visits_today', (select count(*) from public.site_visitor_daily where visit_date = timezone('utc', now())::date),
    'accounts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', u.id,
        'display_name', coalesce(pa.username, nullif(trim(p.display_name),''), 'حساب مشرف'),
        'username', pa.username,
        'role', coalesce(nullif(trim(p.role),''), 'player'),
        'whatsapp_number', c.whatsapp_number,
        'whatsapp_verified', c.whatsapp_verified_at is not null,
        'created_at', u.created_at
      ) order by u.created_at desc)
      from auth.users u
      left join public.profiles p on p.id=u.id
      left join public.player_account_profiles pa on pa.user_id=u.id
      left join public.user_contact_details c on c.user_id=u.id
    ), '[]'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function public.get_site_analytics() from public, anon;
grant execute on function public.get_site_analytics() to authenticated;
