-- Supabase Performance Advisor: cover the service_type_id foreign key on the
-- operation_service_types junction table. Additive and behavior-neutral.
create index if not exists operation_service_types_service_type_id_idx
  on public.operation_service_types(service_type_id);
