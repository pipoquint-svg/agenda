# Mercado Pago remediation scope

This patch is intentionally narrow:

- preserve payer email from the reservation in Orders API requests;
- accept webhook notifications without `x-request-id` by omitting that component from the HMAC manifest;
- retain lowercase normalization for alphanumeric `data.id`;
- retain existing Orders payload structure, amount formatting, capture mode, processing mode and idempotency semantics;
- do not change Google integration, production charge gates or card data handling.
