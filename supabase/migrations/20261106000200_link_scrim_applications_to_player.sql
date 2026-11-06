-- Link new scrim team applications to the authenticated player account.
-- Existing applications are intentionally not backfilled or modified.

CREATE OR REPLACE FUNCTION public.submit_team_application(
    p_scrim_id uuid,
    p_team_name text,
    p_team_tag text,
    p_team_representative text
)
RETURNS TABLE(access_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    generated_code text;
    current_user_id uuid := auth.uid();
    current_account_type text;
    v_scrim_status text;
    v_registration_opens_at timestamptz;
    v_registration_closes_at timestamptz;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول بحساب لاعب لإرسال طلب الفريق';
    END IF;

    SELECT u.raw_user_meta_data ->> 'account_type'
      INTO current_account_type
      FROM auth.users AS u
     WHERE u.id = current_user_id;

    IF COALESCE(current_account_type, '') <> 'player' THEN
        RAISE EXCEPTION 'هذه الخدمة متاحة لحسابات اللاعبين فقط';
    END IF;

    IF length(trim(coalesce(p_team_name, ''))) < 2
       OR length(trim(coalesce(p_team_tag, ''))) < 2
       OR length(trim(coalesce(p_team_representative, ''))) < 2 THEN
        RAISE EXCEPTION 'يرجى إكمال بيانات الفريق';
    END IF;

    SELECT s.status, s.registration_opens_at, s.registration_closes_at
      INTO v_scrim_status, v_registration_opens_at, v_registration_closes_at
      FROM public.scrims AS s
     WHERE s.id = p_scrim_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'السكريم غير موجود';
    END IF;

    IF v_scrim_status <> 'registration_open'
       OR (v_registration_opens_at IS NOT NULL AND now() < v_registration_opens_at)
       OR (v_registration_closes_at IS NOT NULL AND now() > v_registration_closes_at) THEN
        RAISE EXCEPTION 'التسجيل في هذا السكريم غير متاح حالياً';
    END IF;

    INSERT INTO public.scrim_team_applications AS app (
        scrim_id,
        team_name,
        team_tag,
        team_short_name,
        team_representative,
        submitted_by,
        status
    )
    VALUES (
        p_scrim_id,
        trim(p_team_name),
        trim(p_team_tag),
        trim(p_team_tag),
        trim(p_team_representative),
        current_user_id,
        'pending'
    )
    RETURNING app.access_code
         INTO generated_code;

    RETURN QUERY SELECT generated_code;
END;
$function$;

-- Anonymous visitors must not be able to create applications.
REVOKE ALL ON FUNCTION public.submit_team_application(uuid, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_team_application(uuid, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_team_application(uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_team_application(uuid, text, text, text) TO service_role;
