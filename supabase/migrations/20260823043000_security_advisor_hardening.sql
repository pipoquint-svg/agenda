-- Security advisor hardening: eliminate direct exposure of sensitive SECURITY DEFINER views,
-- remove public execution from internal/admin helpers, and pin search_path on helper functions.

-- Hour-package reporting views are internal read models. They must never be queried
-- directly by anon/authenticated, and they must execute with the caller's privileges.
alter view public.hour_package_balances set (security_invoker = true);
alter view public.hour_package_statement_entries set (security_invoker = true);

revoke all on table public.hour_package_balances from public, anon, authenticated;
revoke all on table public.hour_package_statement_entries from public, anon, authenticated;
grant select on table public.hour_package_balances to service_role;
grant select on table public.hour_package_statement_entries to service_role;

-- Trigger/internal helpers are not API surface.
revoke execute on function public.copy_checkout_attribution_to_appointment() from public, anon, authenticated;
revoke execute on function public.rls_auto_enable() from public, anon, authenticated;

-- Legacy admin overloads remain only for internal compatibility and must not be callable
-- through PostgREST by anonymous or ordinary authenticated users.
revoke execute on function public.service_admin_cancel_appointment(uuid,text,text,timestamptz,uuid) from public, anon, authenticated;
revoke execute on function public.service_admin_create_reschedule_hold(uuid,timestamptz,timestamptz,uuid) from public, anon, authenticated;

-- Commercial terms contain operational/financial configuration and are read through
-- authenticated admin surfaces using service_role, never directly by client roles.
revoke execute on function public.service_get_customer_commercial_terms(uuid) from public, anon, authenticated;

-- Pin helper search paths to prevent role-controlled object shadowing.
alter function public.prevent_hour_package_movement_mutation() set search_path = public, pg_temp;
alter function public.format_duration_seconds(bigint) set search_path = public, pg_temp;
alter function public.is_valid_cpf(text) set search_path = public, pg_temp;
alter function public.is_valid_cnpj(text) set search_path = public, pg_temp;
alter function public.is_valid_tax_id(text) set search_path = public, pg_temp;
