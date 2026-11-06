-- Allow authorized staff to add a player from Messages even when public registration is closed.
-- Draft, completed, and cancelled scrims remain unavailable.
-- Only founder, admin, and organizer pass can_add_message_author_to_scrim().

CREATE OR REPLACE FUNCTION public.submit_team_application_from_message(
    p_scrim_id uuid,
    p_player_id uuid,
    p_team_name text,
    p_team_tag text,
    p_team_short_name text
)
RETURNS TABLE(access_code text)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    player_metadata jsonb;
    player_username text;
    scrim_status text;
    generated_code text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    IF NOT public.can_add_message_author_to_scrim() THEN
        RAISE EXCEPTION 'ليست لديك صلاحية إضافة صاحب الرسالة إلى السكريم';
    END IF;

    SELECT u.raw_user_meta_data
      INTO player_metadata
      FROM auth.users AS u
     WHERE u.id = p_player_id;

    IF NOT FOUND OR COALESCE(player_metadata ->> 'account_type', '') <> 'player' THEN
        RAISE EXCEPTION 'صاحب الرسالة ليس حساب لاعب صالحاً';
    END IF;

    player_username := NULLIF(trim(COALESCE(player_metadata ->> 'username', '')), '');
    IF player_username IS NULL THEN
        RAISE EXCEPTION 'تعذر العثور على اسم حساب اللاعب';
    END IF;

    IF length(trim(COALESCE(p_team_name, ''))) < 2
       OR length(trim(COALESCE(p_team_tag, ''))) < 2
       OR length(trim(COALESCE(p_team_short_name, ''))) < 1 THEN
        RAISE EXCEPTION 'يرجى إكمال اسم الفريق والتاق الكامل والاختصار';
    END IF;

    SELECT s.status
      INTO scrim_status
      FROM public.scrims AS s
     WHERE s.id = p_scrim_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'السكريم غير موجود';
    END IF;

    -- Staff override is allowed for published, open/closed, or live scrims.
    -- Never add teams to draft, completed, or cancelled scrims.
    IF scrim_status NOT IN ('registration_open', 'registration_closed', 'live') THEN
        RAISE EXCEPTION 'لا يمكن إضافة فريق إلى سكريم مسودة أو مكتمل أو ملغي';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.scrim_team_applications AS a
         WHERE a.scrim_id = p_scrim_id
           AND a.submitted_by = p_player_id
           AND a.status IN ('pending', 'accepted', 'reserve')
    ) THEN
        RAISE EXCEPTION 'لدى هذا اللاعب طلب قائم أو فريق مسجل في السكريم نفسه';
    END IF;

    INSERT INTO public.scrim_team_applications (
        scrim_id, team_name, team_tag, team_short_name,
        team_representative, submitted_by, status
    )
    VALUES (
        p_scrim_id, trim(p_team_name), trim(p_team_tag),
        trim(p_team_short_name), player_username, p_player_id, 'pending'
    )
    RETURNING access_code INTO generated_code;

    RETURN QUERY SELECT generated_code;
END;
$function$;

REVOKE ALL ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) TO service_role;
