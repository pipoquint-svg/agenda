# Invoice checkout hotfix, 2026-09-21

## Authorized scope

Restore independent invoice billing and optional prebooking. This hotfix is isolated from the tenant-foundation PR and does not alter its authorization or merge/deploy restrictions.

## Contract

- Active invoice customer + verified email session: normal checkout confirms without upfront payment when manual approval is disabled. It does not depend on can_prebook or the optional prebook quota.
- Invoice + PREBOOK: temporary global hold, followed by explicit customer confirmation when allowed, otherwise authorized administrative confirmation. Manual-review normal checkout follows the same temporary lifecycle.
- The invoice due-date snapshot remains SERVICE_START (core service start) plus the configured days, including zero. Outstanding debt is not cash received and no PIX discount is applied.
- Email identity verification reuses the existing hold-bound OTP/session. Typing company data alone does not authorize credit. The server owns eligibility, price and lifecycle transitions.
- The same reservation and resource allocations are retained through confirmation. Confirmed invoices have no checkout payment expiration; unconfirmed prebooks still expire. A repeated confirmation is idempotent.
- Private waitlist invitations cannot become long prebooks. Manual-review customers must use an ordinary booking slot rather than extending a private invitation.
- Existing checkout, free services, fully covered packages/balances, payment collections and administrative receipts retain their existing contracts. INVOICE was already excluded from automatic online balance collections; this hotfix does not add invoice collection/payment issuance.
- Ordinary payment checkout remains available for non-invoice customers. An inactive or revoked invoice authorization cannot waive payment. Financial authorization changes require FINANCE_MANAGE.

## Release order and proof

1. Run canonical database rebuild, complete pgTAP suite, Edge checks, web build and website QA.
2. Backend forward-only migration + booking-submit, prebook-access, admin-customers, mercado-pago-payment and infinitepay-payment Edge functions.
3. Agenda frontend and BlackSheep public checkout/admin frontend. Both repositories are part of the same release.
4. Confirm production schema/version and perform non-charging synthetic smoke tests; do not claim production delivery before these checks.

No customer records or existing bookings are rewritten by this migration. Existing Volt booking remains untouched. New behavior is server-authoritative and old checkout payment links cannot create an upfront invoice charge.

Tests: 160_invoice_prebook_checkout.test.sql, invoice-prebook-email_test.ts, invoiceCheckout.test.ts and invoice-prebook-confirm.test.tsx, plus existing regression suites. CI status is recorded on the actual PR head.
