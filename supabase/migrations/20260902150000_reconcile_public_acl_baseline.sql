-- Item 2A — canonical public-schema ACL baseline.
-- Generated from the read-only production ACL map on 2026-09-02.
-- Scope: every table/view/function/sequence in schema public and every grantee
-- present in the production map (PUBLIC, anon, authenticated, postgres, service_role).
--
-- This migration does NOT change RLS and does NOT intentionally widen or reduce any
-- production privilege. It only makes rebuilds reproduce the ACL already present
-- in production. Any questionable production grant must be reviewed separately.

do $$
declare
  r record;
  object_identity text;
begin
  -- Relations: production baseline is explicit owner + service_role privileges,
  -- with the exceptions below. PUBLIC/anon/authenticated have no direct relation grants.
  for r in
    select
      case when c.relkind in ('v','m') then 'view' else 'table' end as object_kind,
      format('%I.%I', n.nspname, c.relname) as object_identity
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind in ('r','p','v','m','f')
    order by 1,2
  loop
    execute format(
      'REVOKE ALL PRIVILEGES ON TABLE %s FROM PUBLIC, anon, authenticated, service_role, postgres',
      r.object_identity
    );
    execute format(
      'GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE %s TO postgres',
      r.object_identity
    );
    execute format(
      'GRANT SELECT, INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE %s TO service_role',
      r.object_identity
    );
  end loop;

  foreach object_identity in array ARRAY[
      'public.appointment_authorship_events',
      'public.public_rate_limit_buckets'
    ]::text[]
  loop
    execute format('REVOKE ALL PRIVILEGES ON TABLE %s FROM service_role', object_identity);
  end loop;

  foreach object_identity in array ARRAY[
      'public.appointment_change_policy_snapshot_terms',
      'public.appointment_change_policy_snapshots',
      'public.appointment_change_settlements',
      'public.audit_logs',
      'public.customer_balance_movements'
    ]::text[]
  loop
    execute format('REVOKE UPDATE, DELETE, TRUNCATE ON TABLE %s FROM service_role', object_identity);
  end loop;

  foreach object_identity in array ARRAY[
      'public.appointment_token_events',
      'public.appointment_token_network_evidence'
    ]::text[]
  loop
    execute format(
      'REVOKE UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE %s FROM service_role',
      object_identity
    );
  end loop;

  foreach object_identity in array ARRAY[
      'public.audit_purge_runs',
      'public.audit_retention_policy',
      'public.pre_reservation_access_tokens',
      'public.pre_reservations'
    ]::text[]
  loop
    execute format(
      'REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON TABLE %s FROM service_role',
      object_identity
    );
  end loop;

  foreach object_identity in array ARRAY[
      'public.appointment_token_network_purge_runs'
    ]::text[]
  loop
    execute format(
      'REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLE %s FROM service_role',
      object_identity
    );
  end loop;

  -- Sequences: both owner and service_role have exactly SELECT/UPDATE/USAGE.
  for r in
    select format('%I.%I', n.nspname, c.relname) as object_identity
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'S'
    order by 1
  loop
    execute format(
      'REVOKE ALL PRIVILEGES ON SEQUENCE %s FROM PUBLIC, anon, authenticated, service_role, postgres',
      r.object_identity
    );
    execute format(
      'GRANT SELECT, UPDATE, USAGE ON SEQUENCE %s TO postgres',
      r.object_identity
    );
    execute format(
      'GRANT SELECT, UPDATE, USAGE ON SEQUENCE %s TO service_role',
      r.object_identity
    );
  end loop;

  -- Functions: production baseline is postgres + service_role EXECUTE.
  -- Exceptions below reproduce the exact PUBLIC/anon/authenticated/owner-only map.
  for r in
    select format(
      '%I.%I(%s)',
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid)
    ) as object_identity
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
    order by 1
  loop
    execute format(
      'REVOKE ALL PRIVILEGES ON FUNCTION %s FROM PUBLIC, anon, authenticated, service_role, postgres',
      r.object_identity
    );
    execute format('GRANT EXECUTE ON FUNCTION %s TO postgres', r.object_identity);
    execute format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.object_identity);
  end loop;

  foreach object_identity in array ARRAY[
      'public.assert_birthday_coupon_has_locacao_service()',
      'public.assert_booking_page_activation_has_policies()',
      'public.assert_booking_page_service_has_change_policy()',
      'public.capture_appointment_commercial_configuration()',
      'public.capture_appointment_service_type_snapshot()',
      'public.capture_current_appointment_change_policy_snapshot()',
      'public.copy_checkout_attribution_to_appointment()',
      'public.customer_access_appointment_before_insert()',
      'public.customer_access_no_show_after_update()',
      'public.customers_capture_identity_keys_trigger()',
      'public.enforce_active_service_has_change_policy()',
      'public.enforce_cancellation_financial_settlement_permission()',
      'public.enforce_category_operation_change()',
      'public.enforce_checkout_coupon_customer()',
      'public.enforce_coupon_customer_usage_limit()',
      'public.enforce_direct_public_hold_rate_limit()',
      'public.enforce_google_sync_ready_for_new_hold_allocation()',
      'public.enforce_invoice_due_basis_integrity()',
      'public.enforce_service_category_operation()',
      'public.enqueue_no_show_balance_cancellation()',
      'public.ensure_appointment_schedule_defaults()',
      'public.ensure_checkout_hold_schedule_defaults()',
      'public.guard_birthday_coupon_service_scope()',
      'public.guard_customer_access_append_only()',
      'public.guard_duplicate_balance_payment()',
      'public.mark_balance_collection_paid_after_payment()',
      'public.mark_confirmed_appointment_policy_snapshot()',
      'public.populate_checkout_hold_quote_snapshot()',
      'public.prevent_active_service_policy_removal()',
      'public.prevent_appointment_confirmation_snapshot_change()',
      'public.prevent_duration_pricing_overlap()',
      'public.prevent_hour_package_movement_mutation()',
      'public.prevent_public_service_policy_delete()',
      'public.reject_appointment_authorship_mutation()',
      'public.reject_appointment_change_policy_snapshot_mutation()',
      'public.reject_appointment_token_event_mutation()',
      'public.reject_appointment_token_network_mutation()',
      'public.reject_appointment_token_purge_run_mutation()',
      'public.reject_audit_log_mutation()',
      'public.reject_financial_ledger_mutation()',
      'public.revoke_action_tokens_after_appointment_change()',
      'public.seed_hour_package_initial_credit()',
      'public.sync_promoted_appointment_schedule()',
      'public.touch_duration_preset_updated_at()',
      'public.touch_extra_schedule_rule_updated_at()',
      'public.touch_service_extra_schedule_version()',
      'public.trg_enqueue_kommo_appointment_sync()',
      'public.trg_enqueue_kommo_extra_sync()',
      'public.trg_enqueue_kommo_payment_sync()'
    ]::text[]
  loop
    execute format('REVOKE EXECUTE ON FUNCTION %s FROM service_role', object_identity);
  end loop;

  foreach object_identity in array ARRAY[
      'public.apply_external_physical_post_buffer()',
      'public.apply_typed_change_penalty_metadata()',
      'public.blacksheep_rental_special_date(p_date date)',
      'public.blacksheep_special_date_treatment(p_date date)',
      'public.calculate_booking_quotes_for_duration_batch(p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_requested_start_ats timestamp with time zone[], p_coupon_code text)',
      'public.calculate_booking_quotes_for_duration_listing_batch(p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_requested_start_ats timestamp with time zone[], p_coupon_code text)',
      'public.create_checkout_hold_for_reschedule(p_appointment_id uuid, p_requested_start_at timestamp with time zone)',
      'public.list_available_slots_for_duration_reschedule_base(p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date, p_coupon_code text, p_ignore_appointment_id uuid)',
      'public.populate_appointment_block_pricing_snapshots()'
    ]::text[]
  loop
    execute format('GRANT EXECUTE ON FUNCTION %s TO PUBLIC', object_identity);
  end loop;

  foreach object_identity in array ARRAY[
      'public.public_get_booking_page(p_slug text)',
      'public.public_list_available_slots(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_extra_selections jsonb, p_people_count integer, p_local_date date)',
      'public.public_list_available_slots_duration(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer, p_local_date date)',
      'public.public_list_available_slots_minutes(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_contracted_minutes integer, p_extra_selections jsonb, p_people_count integer, p_local_date date)',
      'public.public_quote_booking(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_extra_selections jsonb, p_people_count integer)',
      'public.public_quote_booking_duration(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_duration_blocks integer, p_extra_selections jsonb, p_people_count integer)',
      'public.public_quote_booking_minutes(p_booking_page_slug text, p_service_id uuid, p_service_employee_id uuid, p_contracted_minutes integer, p_extra_selections jsonb, p_people_count integer)'
    ]::text[]
  loop
    execute format('GRANT EXECUTE ON FUNCTION %s TO anon', object_identity);
    execute format('GRANT EXECUTE ON FUNCTION %s TO authenticated', object_identity);
  end loop;

  foreach object_identity in array ARRAY[
      'public.service_admin_search_appointments_global(p_search text, p_limit integer)'
    ]::text[]
  loop
    execute format('GRANT EXECUTE ON FUNCTION %s TO authenticated', object_identity);
  end loop;
end
$$;
