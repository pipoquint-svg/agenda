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

-- Preserve the service-only RPC signatures so any unknown caller fails explicitly
-- rather than falling through to a missing-function or stale plaintext lookup path.
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

-- Expiration metadata no longer represents an automatically issued capability.
ALTER TABLE public.checkout_holds
  ALTER COLUMN recovery_token_expires_at DROP DEFAULT,
  ALTER COLUMN recovery_token_expires_at DROP NOT NULL;

-- Invalidate every historical recovery state before removing the readable token.
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

-- This closes every writer, including legacy/default callers of
-- public_bind_checkout_customer(..., p_recovery_enabled => true).
ALTER TABLE public.checkout_holds
  ADD CONSTRAINT checkout_holds_recovery_retired_check
  CHECK (recovery_enabled = false)
  NOT VALID;

ALTER TABLE public.checkout_holds
  VALIDATE CONSTRAINT checkout_holds_recovery_retired_check;
