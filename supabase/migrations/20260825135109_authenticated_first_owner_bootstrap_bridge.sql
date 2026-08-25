-- Reconcile the authenticated first-OWNER bridge that was applied to the
-- sandbox before it was committed to the authoritative migration history.
--
-- Security contract:
-- - authenticated caller must have a Supabase session (`auth.uid()`);
-- - only the confirmed studio admin address may invoke the one-time bootstrap;
-- - the service-role-only primitive remains the authority for creating OWNER;
-- - no service_role credential is exposed to the browser.

CREATE OR REPLACE FUNCTION public.service_bootstrap_first_owner_authenticated(
  p_display_name text DEFAULT 'BlackSheep Agenda'::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_email text;
  v_confirmed boolean;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_AUTH_REQUIRED';
  END IF;

  SELECT lower(email), email_confirmed_at IS NOT NULL
    INTO v_email, v_confirmed
  FROM auth.users
  WHERE id = v_uid;

  IF v_email IS DISTINCT FROM lower('agenda@blacksheepestudiocriativo.com.br') THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_EMAIL_DENIED';
  END IF;

  IF coalesce(v_confirmed, false) IS NOT TRUE THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_EMAIL_UNCONFIRMED';
  END IF;

  RETURN public.service_bootstrap_first_owner(
    v_uid,
    p_display_name,
    gen_random_uuid()
  );
END;
$$;

REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) FROM anon;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) TO service_role;

COMMENT ON FUNCTION public.service_bootstrap_first_owner_authenticated(text) IS
  'One-time authenticated bridge for the first BlackSheep Agenda OWNER. Restricted to the confirmed studio admin email and delegates to the service-role-only bootstrap primitive.';
