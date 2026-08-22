-- Follow-up hardening for the distributed limiter.
-- SECURITY DEFINER functions own the counter mutation. service_role must not be able to
-- edit buckets directly, otherwise an application credential could reset its own quota.
revoke all on table public.public_rate_limit_buckets from public, anon, authenticated, service_role;

-- This legacy token-scoped promotion wrapper can create an appointment. The current web
-- flow already uses booking-submit -> service_submit_public_checkout, so remove the direct
-- anonymous mutation surface and keep it only for backend compatibility.
revoke execute on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text) from anon, authenticated;
grant execute on function public.public_promote_checkout_hold(text,text,uuid[],jsonb,text) to service_role;
