# Gate 05-0 — Production migration provenance audit

Date: 2026-09-13
Project: `sbexdggbwqvyhbkatucs`

This audit is read-only. No schema changes were made.

## Remote history state

The following local migration versions are absent from `supabase_migrations.schema_migrations` in production:

- `20260910164500_admin_agenda_google_event_display_id.sql`
- `20260910213000_admin_customers_operation_scope.sql`
- `20260912021000_add_sabrina_contextual_booking_pages.sql`
- `20260912110500_finance_launches_range.sql`

## Classification

### 20260910164500_admin_agenda_google_event_display_id.sql

Classification: EFFECT PRESENT / HISTORY MISSING.

Production `public.service_admin_list_agenda(timestamptz,timestamptz)` already exposes the Google calendar event identifier and qualification fields introduced by this migration. Its ACL is server-only (`postgres`/`service_role`).

Recommended action: repair history as APPLIED; do not re-execute SQL.

### 20260910213000_admin_customers_operation_scope.sql

Classification: EFFECT PRESENT / HISTORY MISSING.

Production already has both four-argument functions:

- `service_admin_list_customers_page_scoped(text,integer,integer,text)`
- `service_admin_list_customers_page(text,integer,integer,text)`

The scoped function contains the `CUSTOMER_OPERATION_SCOPE_INVALID` behavior and the ACL is server-only (`postgres`/`service_role`).

Recommended action: repair history as APPLIED; do not re-execute SQL.

### 20260912110500_finance_launches_range.sql

Classification: EFFECT PRESENT / HISTORY MISSING.

Production already has `service_admin_finance_launches_range(timestamptz,timestamptz,text,uuid)` with the expected finance period guard and server-only ACL (`postgres`/`service_role`).

Recommended action: repair history as APPLIED; do not re-execute SQL.

### 20260912021000_add_sabrina_contextual_booking_pages.sql

Classification: NOT APPLIED.

Production evidence:

- `booking_pages_infinitepay_scope_check` currently permits only `sabrina` and `natal-2026` for SABRINA + INFINITEPAY; it does not include `sabrina-essencial` or `sabrina-signature`.
- `booking_pages` has `sabrina` and `natal-2026`, but does not have `sabrina-essencial` or `sabrina-signature`.
- all five required services exist and are active:
  - `essencial-10-fotos`
  - `essencial-20-fotos`
  - `signature-20-fotos`
  - `signature-35-fotos`
  - `signature-40-fotos`

Therefore this migration must NOT be marked APPLIED without executing its SQL. Executing it is a real production schema/business-data change (constraint update plus contextual booking pages/service mappings), so it requires explicit human authorization outside the current no-schema-change Gate 05-0 rule.

## Decision boundary

Safe without schema change:

- mark `20260910164500` APPLIED in migration history;
- mark `20260910213000` APPLIED in migration history;
- mark `20260912110500` APPLIED in migration history.

Requires explicit production-change authorization:

- execute `20260912021000_add_sabrina_contextual_booking_pages.sql`, then let its canonical version be recorded as applied.

Do not use `--include-all` and do not mark `20260912021000` applied without execution.
