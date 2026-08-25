CREATE OR REPLACE FUNCTION public.service_bootstrap_first_owner(
  p_auth_user_id uuid,
  p_display_name text,
  p_request_id uuid DEFAULT gen_random_uuid()
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid;
  v_display_name text := btrim(coalesce(p_display_name, ''));
  v_profile jsonb;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtextextended('agenda:first-owner-bootstrap', 0));

  IF EXISTS (SELECT 1 FROM public.admin_users) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_CLOSED';
  END IF;

  IF p_auth_user_id IS NULL OR NOT EXISTS (
    SELECT 1 FROM auth.users WHERE id = p_auth_user_id
  ) THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_AUTH_USER_NOT_FOUND';
  END IF;

  IF length(v_display_name) < 2 OR length(v_display_name) > 120 THEN
    RAISE EXCEPTION USING ERRCODE = 'P0001', MESSAGE = 'ADMIN_BOOTSTRAP_DISPLAY_NAME_INVALID';
  END IF;

  INSERT INTO public.admin_users (auth_user_id, display_name, role, is_active)
  VALUES (p_auth_user_id, v_display_name, 'OWNER', true)
  RETURNING id INTO v_admin_id;

  v_profile := public.service_admin_get_access_profile(p_auth_user_id);

  INSERT INTO public.audit_logs (
    admin_user_id,
    entity_type,
    entity_id,
    action,
    before_json,
    after_json,
    origin,
    request_id,
    reason,
    occurred_at
  ) VALUES (
    v_admin_id,
    'ADMIN_USER',
    v_admin_id,
    'FIRST_OWNER_BOOTSTRAPPED',
    NULL,
    jsonb_build_object(
      'admin_user_id', v_admin_id,
      'auth_user_id', p_auth_user_id,
      'display_name', v_display_name,
      'role', 'OWNER',
      'is_active', true
    ),
    'SYSTEM_JOB',
    p_request_id,
    'Initial system owner bootstrap',
    now()
  );

  RETURN v_profile;
END;
$$;

REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM anon;
REVOKE ALL ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) TO service_role;

COMMENT ON FUNCTION public.service_bootstrap_first_owner(uuid, text, uuid) IS
  'One-time, service-role-only bootstrap for the first OWNER. Permanently closes after any admin_users row exists.';
