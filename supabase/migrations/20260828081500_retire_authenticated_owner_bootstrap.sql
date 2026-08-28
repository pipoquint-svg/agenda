-- Retire the temporary authenticated first-owner bootstrap surface after pre-LIVE owner initialization.
-- Keep the lower-level bootstrap callable only by service_role for fresh controlled environments;
-- it remains fail-closed once any admin_users row exists.

drop function if exists public.service_bootstrap_first_owner_authenticated(text);

revoke all on function public.service_bootstrap_first_owner(uuid, text, uuid) from public;
revoke all on function public.service_bootstrap_first_owner(uuid, text, uuid) from anon;
revoke all on function public.service_bootstrap_first_owner(uuid, text, uuid) from authenticated;
grant execute on function public.service_bootstrap_first_owner(uuid, text, uuid) to service_role;
