-- Hosted migration parity marker for Etapa 6B.
--
-- The functional manual-refund idempotency correction is already versioned in:
--   20260830012423_etapa6b_manual_refund_idempotency_fix.sql
--
-- Production recorded this additional migration version while the same
-- CREATE OR REPLACE FUNCTION correction was replayed during stabilization.
-- Keeping this harmless marker in the repository prevents migration-version
-- drift without changing the final database behavior.
select 1;
