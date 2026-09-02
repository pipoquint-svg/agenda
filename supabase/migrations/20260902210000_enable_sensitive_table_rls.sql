-- Item 2B — defense-in-depth RLS for the 11 sensitive launch-path tables.
--
-- Intentional policy model: deny by default. Browser roles have no direct table
-- grants on these relations and legitimate runtime access is through narrow
-- RPCs/Edge Functions using service_role/postgres paths that bypass RLS.
-- Do not add permissive policies here.

alter table public.customers enable row level security;
alter table public.appointments enable row level security;
alter table public.payment_transactions enable row level security;
alter table public.payment_provider_events enable row level security;
alter table public.checkout_holds enable row level security;
alter table public.appointment_access_tokens enable row level security;
alter table public.pre_reservation_access_tokens enable row level security;
alter table public.google_connections enable row level security;
alter table public.audit_logs enable row level security;
alter table public.customer_balance_movements enable row level security;
alter table public.google_calendar_events enable row level security;
