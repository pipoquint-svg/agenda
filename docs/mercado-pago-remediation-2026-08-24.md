# Mercado Pago remediation 2026-08-24

Evidence captured before code changes:

- CARD approved successfully in sandbox at 16:39 UTC with an ORDTST order before PR #169.
- CARD attempts after PR #169 return 503 from mercado-pago-payment and leave payment_transactions PENDING with provider_payment_id null.
- Idempotency is not being reused across attempts: each attempt has a distinct request_key, internal idempotency key and transaction_id.
- Current Orders payload already uses string amounts, processing_mode=automatic, capture_mode=automatic and payment_method.id from the Brick.
- PR #169 introduced sandbox substitution of payer email to test@testuser.com. This is now the primary regression suspect because it changed between the known-good and failing paths.
- Current webhook requires x-request-id and always includes request-id in the signed manifest. The provider documentation allows omission of absent components, so this must be corrected without weakening HMAC verification.
- BlackSheep hours/buffer are already corrected by PR #170: sold service until 22:00, physical resource occupation until 22:30.

Planned patch:

1. Preserve context.payer.email when creating Orders in sandbox and production. Do not mutate reservation data.
2. Keep X-Idempotency-Key based on transaction_id.
3. Allow x-request-id to be absent from webhook signature construction; omit the manifest component instead of signing an empty field.
4. Keep lowercasing alphanumeric data.id and constant-time WebCrypto HMAC verification.
5. Add regression tests for payer email preservation and webhook signatures with and without request-id.
6. Do not expose provider raw bodies, card data, tokens, payer PII, access tokens, webhook secrets or full signatures in logs.
