create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.tournament_status_lookup_ip_limits (
  ip inet primary key,
  window_started_at timestamptz not null default now(),
  attempts integer not null default 0
);
create index if not exists tournament_status_lookup_ip_window_idx
  on private.tournament_status_lookup_ip_limits(window_started_at);

alter table private.tournament_status_lookup_ip_limits enable row level security;
revoke all on table private.tournament_status_lookup_ip_limits from public, anon, authenticated;

create or replace function public.get_tournament_application_status(p_access_code text)
returns table(status text, tournament_name text, team_name text, team_tag text, team_representative text, slot_number integer)
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_user_id uuid := auth.uid();
  v_attempts integer;
  v_ip_attempts integer;
  v_headers jsonb;
  v_ip_text text;
  v_ip inet;
begin
  if v_user_id is null then raise exception 'يجب تسجيل الدخول أولاً'; end if;
  if p_access_code is null or p_access_code !~ '^[0-9]{4}$' then
    raise exception 'كود المتابعة غير صالح';
  end if;

  v_headers := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb);
  v_ip_text := split_part(coalesce(v_headers ->> 'x-forwarded-for', ''), ',', 1);
  if nullif(trim(v_ip_text), '') is not null then
    begin v_ip := trim(v_ip_text)::inet;
    exception when invalid_text_representation then v_ip := null;
    end;
  end if;

  if v_ip is not null then
    delete from private.tournament_status_lookup_ip_limits
    where window_started_at < now() - interval '24 hours';

    insert into private.tournament_status_lookup_ip_limits(ip, window_started_at, attempts)
    values (v_ip, now(), 1)
    on conflict (ip) do update
      set window_started_at = case
            when private.tournament_status_lookup_ip_limits.window_started_at < now() - interval '1 minute' then now()
            else private.tournament_status_lookup_ip_limits.window_started_at
          end,
          attempts = case
            when private.tournament_status_lookup_ip_limits.window_started_at < now() - interval '1 minute' then 1
            else private.tournament_status_lookup_ip_limits.attempts + 1
          end
    returning attempts into v_ip_attempts;

    if v_ip_attempts > 20 then
      raise exception 'تم تجاوز عدد محاولات المتابعة من الشبكة. انتظر دقيقة ثم حاول مرة أخرى';
    end if;
  end if;

  insert into public.tournament_status_lookup_limits(user_id, window_started_at, attempts)
  values (v_user_id, now(), 1)
  on conflict (user_id) do update
    set window_started_at = case
          when public.tournament_status_lookup_limits.window_started_at < now() - interval '1 minute' then now()
          else public.tournament_status_lookup_limits.window_started_at
        end,
        attempts = case
          when public.tournament_status_lookup_limits.window_started_at < now() - interval '1 minute' then 1
          else public.tournament_status_lookup_limits.attempts + 1
        end
  returning attempts into v_attempts;

  if v_attempts > 8 then
    raise exception 'محاولات كثيرة. انتظر دقيقة ثم حاول مرة أخرى';
  end if;

  return query
  select a.status, t.name, a.team_name, a.team_tag, null::text, a.slot_number
  from public.tournament_team_applications a
  join public.tournaments t on t.id = a.tournament_id
  where a.access_code = p_access_code
  limit 1;
end;
$function$;
