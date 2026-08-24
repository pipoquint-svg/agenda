# Mercado Pago remediation validation

Validation order:

1. Deno regression tests for webhook signature manifest with and without `x-request-id`.
2. Edge Function type-check through Database Core CI.
3. Deploy `mercado-pago-payment` and `mercado-pago-webhook` to sandbox only after CI passes.
4. Manual APRO on HTTPS staging using a new reservation and a new card token.
5. Inspect resulting Order id, payment transaction state and webhook response before any OTHE attempt.
6. Run OTHE only after APRO is fully reconciled.

No Google integration is touched by this change.
