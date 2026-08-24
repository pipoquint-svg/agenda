# Mercado Pago manual retest order

Manual retest is allowed only after CI and sandbox deployment:

1. APRO with a fresh reservation and fresh card token.
2. Confirm Order id, internal transaction status and webhook acceptance.
3. Only then run OTHE with another fresh reservation/token.

Do not retry the same failed card token.
