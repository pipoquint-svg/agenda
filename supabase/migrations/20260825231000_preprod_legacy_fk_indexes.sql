-- Pre-production performance hardening for legacy import tables.
-- Add covering indexes for foreign keys reported by Supabase Performance Advisor.

create index if not exists legacy_appointments_batch_id_idx
  on public.legacy_appointments(batch_id);

create index if not exists legacy_appointments_legacy_customer_source_id_idx
  on public.legacy_appointments(legacy_customer_source_id);

create index if not exists legacy_customer_sources_batch_id_idx
  on public.legacy_customer_sources(batch_id);
