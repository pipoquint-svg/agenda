begin;

select plan(8);

select ok(to_regclass('public.appointment_balance_collections_created_by_admin_idx') is not null,
  'appointment_balance_collections created_by_admin_id is indexed');
select ok(to_regclass('public.balance_collection_divergences_appointment_idx') is not null,
  'balance_collection_divergences appointment_id is indexed');
select ok(to_regclass('public.balance_collection_divergences_collection_idx') is not null,
  'balance_collection_divergences balance_collection_id is indexed');
select ok(to_regclass('public.balance_collection_divergences_payment_tx_idx') is not null,
  'balance_collection_divergences payment_transaction_id is indexed');
select ok(to_regclass('public.balance_collection_divergences_resolved_by_admin_idx') is not null,
  'balance_collection_divergences resolved_by_admin_id is indexed');
select ok(to_regclass('public.customer_access_events_actor_admin_idx') is not null,
  'customer_access_events actor_admin_id is indexed');
select ok(to_regclass('public.kommo_guard_outgoing_messages_schedule_idx') is not null,
  'kommo_guard_outgoing_messages matched_schedule_id is indexed');
select ok(to_regclass('public.kommo_guard_schedules_rule_idx') is not null,
  'kommo_guard_schedules rule_id is indexed');

select * from finish();
rollback;
