-- Add a secure path from a community message to a pending scrim team application.
-- Existing team rows, slot numbers, and access codes are preserved.

CREATE OR REPLACE FUNCTION public.generate_scrim_team_access_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    candidate_code text;
BEGIN
    IF NEW.access_code IS NULL OR NEW.access_code !~ '^[0-9]{3}$' THEN
        PERFORM pg_advisory_xact_lock(734921, 1);
        LOOP
            candidate_code := lpad(floor(random() * 1000)::integer::text, 3, '0');
            EXIT WHEN NOT EXISTS (
                SELECT 1
                FROM public.scrim_team_applications AS existing
                WHERE existing.access_code = candidate_code
                  AND existing.id IS DISTINCT FROM NEW.id
            );
        END LOOP;
        NEW.access_code := candidate_code;
    END IF;

    -- Pending/reserve/rejected applications do not occupy a team slot.
    IF NEW.status = 'accepted' AND NEW.slot_number IS NULL THEN
        PERFORM pg_advisory_xact_lock(734921, 1);
        SELECT COALESCE(MAX(a.slot_number), 2) + 1
          INTO NEW.slot_number
          FROM public.scrim_team_applications AS a
         WHERE a.scrim_id = NEW.scrim_id
           AND a.status = 'accepted'
           AND a.slot_number IS NOT NULL;
    END IF;

    RETURN NEW;
END;
$function$;

-- Keep the trigger attached, but stop the old chronological slot compaction.
CREATE OR REPLACE FUNCTION public.reorder_slots_after_accept()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
BEGIN
    RETURN NEW;
END;
$function$;

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
    current_user_id uuid := auth.uid();
    current_role text;
    player_metadata jsonb;
    player_username text;
    scrim_status text;
    opens_at timestamptz;
    closes_at timestamptz;
    generated_code text;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    SELECT lower(COALESCE(p.role, ''))
      INTO current_role
      FROM public.profiles AS p
     WHERE p.id = current_user_id;

    IF current_role NOT IN ('founder', 'admin', 'organizer') THEN
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

    SELECT s.status, s.registration_opens_at, s.registration_closes_at
      INTO scrim_status, opens_at, closes_at
      FROM public.scrims AS s
     WHERE s.id = p_scrim_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'السكريم غير موجود';
    END IF;

    IF scrim_status <> 'registration_open'
       OR (opens_at IS NOT NULL AND now() < opens_at)
       OR (closes_at IS NOT NULL AND now() > closes_at) THEN
        RAISE EXCEPTION 'التسجيل في هذا السكريم غير متاح حالياً';
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
    current_role text;
    app_scrim_id uuid;
    app_status text;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    SELECT lower(COALESCE(p.role, ''))
      INTO current_role
      FROM public.profiles AS p
     WHERE p.id = current_user_id;

    IF current_role NOT IN ('founder', 'admin', 'organizer') THEN
        RAISE EXCEPTION 'ليست لديك صلاحية مراجعة طلبات الفرق';
    END IF;

    IF p_status NOT IN ('accepted', 'reserve', 'rejected') THEN
        RAISE EXCEPTION 'حالة الطلب غير صحيحة';
    END IF;

    PERFORM pg_advisory_xact_lock(734921, 1);

    SELECT a.scrim_id, a.status
      INTO app_scrim_id, app_status
      FROM public.scrim_team_applications AS a
     WHERE a.id = p_application_id
     FOR UPDATE;

    IF NOT FOUND OR app_status NOT IN ('pending', 'reserve') THEN
        RAISE EXCEPTION 'الطلب غير موجود أو لم يعد قابلاً للمراجعة';
    END IF;

    IF p_status = 'accepted' THEN
        IF p_slot_number IS NULL OR p_slot_number < 1 THEN
            RAISE EXCEPTION 'يجب تحديد خانة صحيحة للفريق';
        END IF;

        IF EXISTS (
            SELECT 1
              FROM public.scrim_team_applications AS a
             WHERE a.scrim_id = app_scrim_id
               AND a.slot_number = p_slot_number
               AND a.id <> p_application_id
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

REVOKE ALL ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) FROM anon;
GRANT EXECUTE ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.submit_team_application_from_message(uuid, uuid, text, text, text) TO service_role;

REVOKE ALL ON FUNCTION public.review_scrim_team_application(bigint, text, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.review_scrim_team_application(bigint, text, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.review_scrim_team_application(bigint, text, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.review_scrim_team_application(bigint, text, integer) TO service_role;


-- Only accepted teams reserve a unique slot. Legacy pending rows may carry
-- an old provisional slot from the previous trigger and must not block it.
DROP INDEX IF EXISTS public.scrim_team_applications_scrim_slot_unique;
CREATE UNIQUE INDEX scrim_team_applications_scrim_slot_unique
    ON public.scrim_team_applications (scrim_id, slot_number)
    WHERE status = 'accepted' AND slot_number IS NOT NULL;
