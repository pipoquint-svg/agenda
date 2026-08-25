-- Remove the isolated Kommo Guard drift from Agenda databases.
--
-- Safety contract:
-- - fresh/rebuilt databases where the drift never existed: no-op;
-- - drifted sandbox: only remove the exact audited object set;
-- - abort if inventory, row counts, or cross-subsystem foreign keys differ;
-- - no CASCADE.

DO $$
DECLARE
  v_tables text[];
  v_external_fk_count integer;
  v_function_count integer;
BEGIN
  SELECT coalesce(array_agg(table_name ORDER BY table_name), ARRAY[]::text[])
    INTO v_tables
  FROM information_schema.tables
  WHERE table_schema = 'public'
    AND table_name LIKE 'kommo_guard_%';

  SELECT count(*)
    INTO v_function_count
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.proname = 'kommo_guard_adjust_due';

  -- Authoritative clean rebuilds have neither the drift tables nor helper.
  IF cardinality(v_tables) = 0 AND v_function_count = 0 THEN
    RETURN;
  END IF;

  IF v_tables <> ARRAY[
    'kommo_guard_audit_log',
    'kommo_guard_discovery_cache',
    'kommo_guard_lead_state',
    'kommo_guard_outgoing_messages',
    'kommo_guard_reconciliation_runs',
    'kommo_guard_rules',
    'kommo_guard_schedules',
    'kommo_guard_settings',
    'kommo_guard_talks',
    'kommo_guard_webhook_inbox'
  ]::text[] THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_INVENTORY_MISMATCH: %', v_tables;
  END IF;

  IF v_function_count <> 1 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_FUNCTION_INVENTORY_MISMATCH: %', v_function_count;
  END IF;

  -- Refuse cleanup if any FK crosses the Kommo Guard boundary.
  SELECT count(*)
    INTO v_external_fk_count
  FROM pg_constraint con
  JOIN pg_class child ON child.oid = con.conrelid
  JOIN pg_namespace child_ns ON child_ns.oid = child.relnamespace
  JOIN pg_class parent ON parent.oid = con.confrelid
  JOIN pg_namespace parent_ns ON parent_ns.oid = parent.relnamespace
  WHERE con.contype = 'f'
    AND child_ns.nspname = 'public'
    AND parent_ns.nspname = 'public'
    AND ((child.relname LIKE 'kommo_guard_%') <> (parent.relname LIKE 'kommo_guard_%'));

  IF v_external_fk_count <> 0 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_EXTERNAL_FK_DEPENDENCY: %', v_external_fk_count;
  END IF;

  -- The sanitized snapshot in docs/qa/kommo-guard/ is authoritative for the
  -- only persisted drift data. Abort rather than discard anything newer.
  IF (SELECT count(*) FROM public.kommo_guard_audit_log) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_lead_state) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_outgoing_messages) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_reconciliation_runs) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_schedules) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_talks) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_webhook_inbox) <> 0
     OR (SELECT count(*) FROM public.kommo_guard_discovery_cache) <> 1
     OR (SELECT count(*) FROM public.kommo_guard_rules) <> 18
     OR (SELECT count(*) FROM public.kommo_guard_settings) <> 1 THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_DATA_DRIFT_DETECTED';
  END IF;
END
$$;

-- Drop the only helper before its settings table. Exact signature, no CASCADE.
DROP FUNCTION IF EXISTS public.kommo_guard_adjust_due(timestamptz);

-- Child tables before referenced parents; every drop is explicit and non-CASCADE.
DROP TABLE IF EXISTS public.kommo_guard_audit_log;
DROP TABLE IF EXISTS public.kommo_guard_outgoing_messages;
DROP TABLE IF EXISTS public.kommo_guard_schedules;
DROP TABLE IF EXISTS public.kommo_guard_rules;
DROP TABLE IF EXISTS public.kommo_guard_discovery_cache;
DROP TABLE IF EXISTS public.kommo_guard_lead_state;
DROP TABLE IF EXISTS public.kommo_guard_reconciliation_runs;
DROP TABLE IF EXISTS public.kommo_guard_talks;
DROP TABLE IF EXISTS public.kommo_guard_webhook_inbox;
DROP TABLE IF EXISTS public.kommo_guard_settings;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema = 'public' AND table_name LIKE 'kommo_guard_%'
  ) OR EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname LIKE 'kommo_guard_%'
  ) THEN
    RAISE EXCEPTION 'KOMMO_GUARD_CLEANUP_INCOMPLETE';
  END IF;
END
$$;
