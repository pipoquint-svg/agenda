# Mercado Pago webhook manifest contract

The HMAC manifest is built only from components actually present in the notification.

- `data.id` is required and alphanumeric values are lowercased before signing.
- `ts` comes from `x-signature` and is required.
- `x-request-id` is included only when present.
- an absent request id must not become `request-id:;`.
- verification remains HMAC SHA-256 via WebCrypto.

Regression tests cover notifications with and without `x-request-id`.
