# Mercado Pago remediation acceptance

Acceptance requires:

- Deno signature tests green;
- Database Core green;
- sandbox payment/webhook functions on the branch revision;
- APRO produces an Order and reconciles APPROVED;
- webhook no longer rejects a valid notification solely because `x-request-id` is absent;
- OTHE is rejected without confirming the appointment.
