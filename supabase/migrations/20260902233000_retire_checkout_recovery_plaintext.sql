-- Item 4: the direct checkout recovery feature is operationally retired.
-- Remove the readable capability instead of recreating a dead public recovery flow.

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM public.checkout_holds
    WHERE recovery_enabled
      AND status = 'ACTIVE'
      AND expires_at > now()
      AND recovery_token_expires_at > now()
  ) THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'ITEM04_ACTIVE_RECOVERY_HOLD_PRESENT';
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.get_checkout_hold_resume_context(
  p_recovery_token text
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RAISE EXCEPTION USING
    ERRCODE = 'P0001',
    MESSAGE = 'CHECKOUT_RECOVERY_RETIRED';
END;
$$;

COMMENT ON FUNCTION public.get_checkout_hold_resume_context(text) IS
  'Retired checkout recovery boundary. Preserved only to fail closed for stale internal callers.';

CREATE OR REPLACE FUNCTION public.set_checkout_hold_recovery_contact(
  p_checkout_hold_token text,
  p_phone text,
  p_enabled boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
VOLATILE
SECURITY DEFINER
SET search_path = public, extensions
AS $$
BEGIN
  RAISE EXCEPTION USING
    ERRCODE = 'P0001',
    MESSAGE = 'CHECKOUT_RECOVERY_RETIRED';
END;
$$;

COMMENT ON FUNCTION public.set_checkout_hold_recovery_contact(text, text, boolean) IS
  'Retired checkout recovery mutation. Preserved only to fail closed for stale internal callers.';

-- Preserve the public_bind_checkout_customer signature for compatibility, but make
-- recovery opt-in impossible. The legacy default was true, which made omitted
-- arguments conceptually re-enable recovery and regressed normal checkout once
-- the retirement constraint was introduced.
CREATE OR REPLACE FUNCTION public.public_bind_checkout_customer(
  p_checkout_hold_token text,
  p_name text,
  p_email text,
  p_phone text,
  p_tax_id text DEFAULT null::text,
  p_recovery_enabled boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions'
AS $function$
DECLARE
  v_hold public.checkout_holds%rowtype;
  v_page public.booking_pages%rowtype;
  v_name text := nullif(btrim(p_name), '');
  v_email text := nullif(lower(btrim(p_email)), '');
  v_phone_raw text := regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g');
  v_phone text := public.normalize_customer_phone_identity(p_phone);
  v_tax text := nullif(regexp_replace(coalesce(p_tax_id, ''), '[^0-9]', '', 'g'), '');
  v_customer public.customers%rowtype;
  v_by_email public.customers%rowtype;
  v_by_phone public.customers%rowtype;
  v_by_tax public.customers%rowtype;
  v_count integer;
  v_created boolean := false;
BEGIN
  IF p_recovery_enabled THEN
    RAISE EXCEPTION USING
      ERRCODE = 'P0001',
      MESSAGE = 'CHECKOUT_RECOVERY_RETIRED';
  END IF;

  SELECT * INTO v_hold
  FROM public.checkout_holds
  WHERE public_token_hash = encode(digest(p_checkout_hold_token, 'sha256'), 'hex')
  FOR UPDATE;

  IF NOT FOUND OR v_hold.status <> 'ACTIVE' OR v_hold.expires_at <= now() THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CHECKOUT_HOLD_NOT_ACTIVE';
  END IF;
  IF v_hold.booking_page_id IS NULL THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CHECKOUT_ORIGIN_MISSING';
  END IF;

  SELECT * INTO v_page
  FROM public.booking_pages
  WHERE id = v_hold.booking_page_id AND is_active;
  IF NOT FOUND THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CHECKOUT_ORIGIN_NOT_ACTIVE';
  END IF;

  IF v_name IS NULL OR length(v_name) < 2 OR length(v_name) > 160 THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_NAME_INVALID';
  END IF;
  IF v_email IS NULL OR v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_EMAIL_INVALID';
  END IF;
  IF length(v_phone_raw) NOT BETWEEN 10 AND 15 OR v_phone IS NULL THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_PHONE_INVALID';
  END IF;
  IF v_page.require_tax_id AND (v_tax IS NULL OR NOT public.is_valid_tax_id(v_tax)) THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_TAX_ID_INVALID';
  END IF;
  IF v_tax IS NOT NULL AND NOT public.is_valid_tax_id(v_tax) THEN
    RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_TAX_ID_INVALID';
  END IF;

  IF v_hold.primary_customer_id IS NOT NULL THEN
    SELECT * INTO v_customer
    FROM public.customers
    WHERE id = v_hold.primary_customer_id
    FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION USING errcode = 'P0001', message = 'CHECKOUT_CUSTOMER_MISSING';
    END IF;

    IF v_customer.email IS NOT NULL AND lower(v_customer.email) <> v_email THEN
      RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
    END IF;
    IF v_customer.phone IS NOT NULL AND public.normalize_customer_phone_identity(v_customer.phone) <> v_phone THEN
      RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
    END IF;
    IF v_tax IS NOT NULL AND v_customer.cpf_cnpj IS NOT NULL
       AND regexp_replace(v_customer.cpf_cnpj, '[^0-9]', '', 'g') <> v_tax THEN
      RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_TAX_ID_MISMATCH';
    END IF;
  ELSE
    PERFORM pg_advisory_xact_lock(hashtextextended(
      'customer-bind:' || coalesce(v_email, '') || ':' || coalesce(v_phone, '') || ':' || coalesce(v_tax, ''),
      0
    ));

    SELECT count(*)::integer INTO v_count
    FROM public.customers c
    WHERE lower(coalesce(c.email, '')) = v_email;
    IF v_count > 1 THEN
      RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
    ELSIF v_count = 1 THEN
      SELECT * INTO v_by_email
      FROM public.customers c
      WHERE lower(coalesce(c.email, '')) = v_email
      FOR UPDATE;
    END IF;

    SELECT count(*)::integer INTO v_count
    FROM public.customers c
    WHERE public.normalize_customer_phone_identity(c.phone) = v_phone;
    IF v_count > 1 THEN
      RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
    ELSIF v_count = 1 THEN
      SELECT * INTO v_by_phone
      FROM public.customers c
      WHERE public.normalize_customer_phone_identity(c.phone) = v_phone
      FOR UPDATE;
    END IF;

    IF v_tax IS NOT NULL THEN
      SELECT count(*)::integer INTO v_count
      FROM public.customers c
      WHERE regexp_replace(coalesce(c.cpf_cnpj, ''), '[^0-9]', '', 'g') = v_tax;
      IF v_count > 1 THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_IDENTITY_AMBIGUOUS';
      ELSIF v_count = 1 THEN
        SELECT * INTO v_by_tax
        FROM public.customers c
        WHERE regexp_replace(coalesce(c.cpf_cnpj, ''), '[^0-9]', '', 'g') = v_tax
        FOR UPDATE;
      END IF;
    END IF;

    IF v_by_tax.id IS NOT NULL THEN
      v_customer := v_by_tax;
      IF v_by_email.id IS NOT NULL AND v_by_email.id <> v_customer.id THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
      END IF;
      IF v_customer.email IS NOT NULL AND lower(v_customer.email) <> v_email THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
      END IF;
      IF v_by_phone.id IS NOT NULL AND v_by_phone.id <> v_customer.id THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      END IF;
      IF v_customer.phone IS NOT NULL AND public.normalize_customer_phone_identity(v_customer.phone) <> v_phone THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      END IF;
    ELSIF v_by_email.id IS NOT NULL THEN
      v_customer := v_by_email;
      IF v_by_phone.id IS NOT NULL AND v_by_phone.id <> v_customer.id THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      END IF;
      IF v_customer.phone IS NOT NULL AND public.normalize_customer_phone_identity(v_customer.phone) <> v_phone THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_PHONE_MISMATCH';
      END IF;
      IF v_tax IS NOT NULL AND v_customer.cpf_cnpj IS NOT NULL
         AND regexp_replace(v_customer.cpf_cnpj, '[^0-9]', '', 'g') <> v_tax THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_TAX_ID_MISMATCH';
      END IF;
    ELSIF v_by_phone.id IS NOT NULL THEN
      v_customer := v_by_phone;
      IF v_customer.email IS NOT NULL AND lower(v_customer.email) <> v_email THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_EMAIL_MISMATCH';
      END IF;
      IF v_tax IS NOT NULL AND v_customer.cpf_cnpj IS NOT NULL
         AND regexp_replace(v_customer.cpf_cnpj, '[^0-9]', '', 'g') <> v_tax THEN
        RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_TAX_ID_MISMATCH';
      END IF;
    END IF;
  END IF;

  IF v_customer.id IS NULL THEN
    BEGIN
      INSERT INTO public.customers(name, email, phone, cpf_cnpj)
      VALUES (v_name, v_email, v_phone, v_tax)
      RETURNING * INTO v_customer;
      v_created := true;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION USING errcode = 'P0001', message = 'CUSTOMER_IDENTITY_CONFLICT';
    END;
  ELSE
    UPDATE public.customers
    SET name = v_name,
        email = coalesce(email, v_email),
        phone = coalesce(phone, v_phone),
        cpf_cnpj = coalesce(cpf_cnpj, v_tax),
        updated_at = now()
    WHERE id = v_customer.id
    RETURNING * INTO v_customer;
  END IF;

  UPDATE public.checkout_holds
  SET primary_customer_id = v_customer.id,
      recovery_phone = null,
      recovery_enabled = false,
      updated_at = now()
  WHERE id = v_hold.id;

  RETURN jsonb_build_object(
    'customer_bound', true,
    'customer_created', v_created,
    'recovery_enabled', false,
    'has_tax_id', v_customer.cpf_cnpj IS NOT NULL
  );
END;
$function$;

COMMENT ON FUNCTION public.public_bind_checkout_customer(text, text, text, text, text, boolean) IS
  'Binds a customer to checkout. The recovery argument is retained only for compatibility; true fails closed because direct checkout recovery is retired.';

ALTER TABLE public.checkout_holds
  ALTER COLUMN recovery_token_expires_at DROP DEFAULT,
  ALTER COLUMN recovery_token_expires_at DROP NOT NULL;

UPDATE public.checkout_holds
SET recovery_enabled = false,
    recovery_phone = null,
    recovery_token_expires_at = null,
    recovery_enqueued_at = null
WHERE recovery_enabled
   OR recovery_phone IS NOT NULL
   OR recovery_token_expires_at IS NOT NULL
   OR recovery_enqueued_at IS NOT NULL;

DROP INDEX IF EXISTS public.checkout_holds_recovery_public_token_uq;
ALTER TABLE public.checkout_holds
  DROP COLUMN recovery_public_token;

ALTER TABLE public.checkout_holds
  ADD CONSTRAINT checkout_holds_recovery_retired_check
  CHECK (recovery_enabled = false)
  NOT VALID;

ALTER TABLE public.checkout_holds
  VALIDATE CONSTRAINT checkout_holds_recovery_retired_check;
