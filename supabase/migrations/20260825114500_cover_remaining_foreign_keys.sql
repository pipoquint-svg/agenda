CREATE INDEX IF NOT EXISTS appointment_balance_collections_created_by_admin_idx
  ON public.appointment_balance_collections (created_by_admin_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_appointment_idx
  ON public.balance_collection_divergences (appointment_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_collection_idx
  ON public.balance_collection_divergences (balance_collection_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_payment_tx_idx
  ON public.balance_collection_divergences (payment_transaction_id);

CREATE INDEX IF NOT EXISTS balance_collection_divergences_resolved_by_admin_idx
  ON public.balance_collection_divergences (resolved_by_admin_id);

CREATE INDEX IF NOT EXISTS customer_access_events_actor_admin_idx
  ON public.customer_access_events (actor_admin_id);
