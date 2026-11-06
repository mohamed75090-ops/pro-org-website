-- Correct and harden the message-to-team workflow, and add team withdrawal.
-- Existing accepted teams, their slots, and their access codes are not rewritten.

CREATE OR REPLACE FUNCTION public.generate_scrim_team_access_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    candidate_code text;
    attempts integer := 0;
BEGIN
    IF NEW.access_code IS NULL OR NEW.access_code !~ '^[0-9]{3}$' THEN
        PERFORM pg_advisory_xact_lock(734921, 1);
        LOOP
            attempts := attempts + 1;
            IF attempts > 1000 THEN
                RAISE EXCEPTION 'تعذر إنشاء كود فريق فريد من 3 أرقام';
            END IF;
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

-- Correct the message-submission RPC: qualify its INSERT target and fail closed
-- when a staff profile/role cannot be found.
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

    IF COALESCE(current_role, '') NOT IN ('founder', 'admin', 'organizer') THEN
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

    INSERT INTO public.scrim_team_applications AS app (
        scrim_id, team_name, team_tag, team_short_name,
        team_representative, submitted_by, status
    )
    VALUES (
        p_scrim_id, trim(p_team_name), trim(p_team_tag),
        trim(p_team_short_name), player_username, p_player_id, 'pending'
    )
    RETURNING app.access_code INTO generated_code;

    RETURN QUERY SELECT generated_code;
END;
$function$;


-- Re-define the review RPC with a fail-closed role check as well.
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

    IF COALESCE(current_role, '') NOT IN ('founder', 'admin', 'organizer') THEN
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
        IF p_slot_number IS NULL OR p_slot_number < 1 THEN
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
GRANT EXECUTE ON FUNCTION public.review_scrim_team_application(bigint, text, integer) TO authenticated;

-- Add the withdrawn state without changing any existing application rows.
DO $migration$
DECLARE
    existing_constraint record;
BEGIN
    FOR existing_constraint IN
        SELECT c.conname
          FROM pg_catalog.pg_constraint AS c
         WHERE c.conrelid = 'public.scrim_team_applications'::regclass
           AND c.contype = 'c'
           AND pg_catalog.pg_get_constraintdef(c.oid) ILIKE '%status%'
    LOOP
        EXECUTE format(
            'ALTER TABLE public.scrim_team_applications DROP CONSTRAINT %I',
            existing_constraint.conname
        );
    END LOOP;
END;
$migration$;

ALTER TABLE public.scrim_team_applications
    ADD CONSTRAINT scrim_team_applications_status_check
    CHECK (status IN ('pending', 'accepted', 'reserve', 'rejected', 'withdrawn'));

-- Admins can load the same management list; all writes still go through
-- the role-checked SECURITY DEFINER RPCs.
DROP POLICY IF EXISTS scrim_team_applications_admin_select
    ON public.scrim_team_applications;

CREATE POLICY scrim_team_applications_admin_select
    ON public.scrim_team_applications
    FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1
              FROM public.profiles AS p
             WHERE p.id = auth.uid()
               AND lower(COALESCE(p.role, '')) = 'admin'
        )
    );

-- Check whether the signed-in player owns an accepted team and is still
-- inside the scrim's withdrawal window. A NULL deadline means no cutoff set.
CREATE OR REPLACE FUNCTION public.can_withdraw_own_scrim_team_application(
    p_team_code text
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT EXISTS (
        SELECT 1
          FROM public.scrim_team_applications AS a
          JOIN public.scrims AS s ON s.id = a.scrim_id
         WHERE upper(a.access_code) = upper(trim(p_team_code))
           AND a.submitted_by = auth.uid()
           AND a.status = 'accepted'
           AND (s.withdrawal_closes_at IS NULL OR now() <= s.withdrawal_closes_at)
    );
$function$;

-- Player self-withdrawal: ownership is checked on the server, not trusted
-- from the browser or from possession of the access code alone.
CREATE OR REPLACE FUNCTION public.withdraw_own_scrim_team_application(
    p_team_code text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    current_user_id uuid := auth.uid();
    application_id bigint;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    PERFORM pg_advisory_xact_lock(734921, 1);

    UPDATE public.scrim_team_applications AS a
       SET status = 'withdrawn',
           slot_number = NULL
      FROM public.scrims AS s
     WHERE s.id = a.scrim_id
       AND upper(a.access_code) = upper(trim(p_team_code))
       AND a.submitted_by = current_user_id
       AND a.status = 'accepted'
       AND (s.withdrawal_closes_at IS NULL OR now() <= s.withdrawal_closes_at);

    IF NOT FOUND THEN
        RAISE EXCEPTION 'لا يمكن الانسحاب: تحقق من ملكية الفريق أو موعد إغلاق الانسحاب أو حالة الفريق';
    END IF;
END;
$function$;

-- Organizer/staff withdrawal from the management list. Staff may withdraw
-- any accepted team; the released slot becomes reusable immediately.
CREATE OR REPLACE FUNCTION public.withdraw_scrim_team_application(
    p_application_id bigint
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    current_user_id uuid := auth.uid();
    current_role text;
BEGIN
    IF current_user_id IS NULL THEN
        RAISE EXCEPTION 'يجب تسجيل الدخول أولاً';
    END IF;

    SELECT lower(COALESCE(p.role, ''))
      INTO current_role
      FROM public.profiles AS p
     WHERE p.id = current_user_id;

    IF COALESCE(current_role, '') NOT IN ('founder', 'admin', 'organizer') THEN
        RAISE EXCEPTION 'ليست لديك صلاحية سحب الفرق';
    END IF;

    PERFORM pg_advisory_xact_lock(734921, 1);

    UPDATE public.scrim_team_applications AS a
       SET status = 'withdrawn',
           slot_number = NULL,
           reviewed_by = current_user_id,
           reviewed_at = now()
     WHERE a.id = p_application_id
       AND a.status = 'accepted';

    IF NOT FOUND THEN
        RAISE EXCEPTION 'الفريق غير موجود أو ليس ضمن الفرق المقبولة';
    END IF;
END;
$function$;

REVOKE ALL ON FUNCTION public.can_withdraw_own_scrim_team_application(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.withdraw_own_scrim_team_application(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.withdraw_scrim_team_application(bigint) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.can_withdraw_own_scrim_team_application(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_own_scrim_team_application(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.withdraw_scrim_team_application(bigint) TO authenticated;


-- Ensure only an accepted team can block a slot during manual approval.
-- Old pending/reserve rows may still contain legacy provisional slot values.
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

    IF COALESCE(current_role, '') NOT IN ('founder', 'admin', 'organizer') THEN
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
