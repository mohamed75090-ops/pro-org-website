-- Use the same secure staff-role check for scrim application review.
-- This avoids direct profiles reads being blocked by profiles RLS for Founder/Organizer.

CREATE OR REPLACE FUNCTION public.review_scrim_team_application(
    p_application_id bigint,
    p_status text,
    p_slot_number integer DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    current_user_id uuid := auth.uid();
    app_scrim_id uuid;
    app_status text;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    IF NOT public.can_add_message_author_to_scrim() THEN
        RAISE EXCEPTION 'ليست لديك صلاحية مراجعة طلبات الفرق';
    END IF;

    IF p_status NOT IN ('accepted', 'rejected', 'reserve') THEN
        RAISE EXCEPTION 'حالة الطلب غير صحيحة';
    END IF;

    PERFORM pg_advisory_xact_lock(734921, 1);

    SELECT a.scrim_id, a.status
      INTO app_scrim_id, app_status
      FROM public.scrim_team_applications AS a
     WHERE a.id = p_application_id
     FOR UPDATE;

    IF NOT FOUND OR (
        app_status NOT IN ('pending', 'reserve')
        AND NOT (app_status = 'accepted' AND p_status = 'reserve')
    ) THEN
        RAISE EXCEPTION 'الطلب غير موجود أو لم يعد قابلاً للمراجعة';
    END IF;

    IF p_status = 'accepted' THEN
        IF p_slot_number IS NULL OR p_slot_number < 3 THEN
            RAISE EXCEPTION 'يجب تحديد خانة صحيحة للفريق';
        END IF;

        IF EXISTS (
            SELECT 1
              FROM public.scrim_team_applications AS a
             WHERE a.scrim_id = app_scrim_id
               AND a.slot_number = p_slot_number
               AND a.id <> p_application_id
               AND a.status = 'accepted'
        ) THEN
            RAISE EXCEPTION 'هذه الخانة مستخدمة بالفعل. حدّث القائمة واختر خانة أخرى';
        END IF;
    END IF;

    UPDATE public.scrim_team_applications AS a
       SET status = p_status,
           slot_number = CASE WHEN p_status = 'accepted' THEN p_slot_number ELSE NULL END,
           reviewed_by = current_user_id,
           reviewed_at = now()
     WHERE a.id = p_application_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.review_scrim_team_application(bigint, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.review_scrim_team_application(bigint, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.review_scrim_team_application(bigint, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_scrim_team_application(bigint, text, integer) TO service_role;
