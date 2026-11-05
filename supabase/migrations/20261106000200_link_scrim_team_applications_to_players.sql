-- Link every new scrim team application to the authenticated player account.
-- Existing applications and their access codes are intentionally left unchanged.

create or replace function public.submit_team_application(
    p_scrim_id uuid,
    p_team_name text,
    p_team_tag text,
    p_team_representative text
)
returns table(access_code text)
language plpgsql
security definer
set search_path = ''
as $function$
declare
    generated_code text;
    v_user_id uuid;
    v_account_type text;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'يجب تسجيل الدخول بحساب لاعب لإرسال طلب الفريق';
    end if;

    select lower(coalesce(u.raw_user_meta_data ->> 'account_type', ''))
      into v_account_type
      from auth.users as u
     where u.id = v_user_id;

    if v_account_type is distinct from 'player' then
        raise exception 'تسجيل الفرق متاح لحسابات اللاعبين فقط';
    end if;

    if length(btrim(coalesce(p_team_name, ''))) < 2
       or length(btrim(coalesce(p_team_tag, ''))) < 2
       or length(btrim(coalesce(p_team_representative, ''))) < 2 then
        raise exception 'يرجى إكمال بيانات الفريق';
    end if;

    if p_scrim_id is null then
        raise exception 'يرجى تحديد السكريم';
    end if;

    insert into public.scrim_team_applications (
        scrim_id,
        team_name,
        team_tag,
        team_short_name,
        team_representative,
        submitted_by,
        status
    )
    values (
        p_scrim_id,
        btrim(p_team_name),
        btrim(p_team_tag),
        btrim(p_team_tag),
        btrim(p_team_representative),
        v_user_id,
        'pending'
    )
    returning public.scrim_team_applications.access_code
         into generated_code;

    return query select generated_code;
end;
$function$;

revoke all on function public.submit_team_application(uuid, text, text, text)
    from public, anon;
grant execute on function public.submit_team_application(uuid, text, text, text)
    to authenticated, service_role;
