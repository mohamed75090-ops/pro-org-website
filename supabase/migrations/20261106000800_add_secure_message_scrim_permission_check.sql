-- صلاحية آمنة لعرض خيار إضافة صاحب الرسالة إلى السكريم
-- يتم فحص الدور داخل SECURITY DEFINER لتجنب اعتماد الواجهة على قراءة profiles مباشرة.

CREATE OR REPLACE FUNCTION public.can_add_message_author_to_scrim()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.profiles AS p
        WHERE p.id = auth.uid()
          AND lower(trim(COALESCE(p.role, ''))) IN ('founder', 'admin', 'organizer')
    );
$function$;

REVOKE ALL ON FUNCTION public.can_add_message_author_to_scrim() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.can_add_message_author_to_scrim() FROM anon;
GRANT EXECUTE ON FUNCTION public.can_add_message_author_to_scrim() TO authenticated;
GRANT EXECUTE ON FUNCTION public.can_add_message_author_to_scrim() TO service_role;
