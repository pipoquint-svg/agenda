# Mercado Pago payer identity contract

For card payments, the payer identity sent to the Orders API must remain aligned with the identity used to initialize the Brick and tokenize the card.

Rules:

- preserve the reservation payer email in sandbox and production;
- never replace it with `test@testuser.com` after tokenization;
- keep test behavior in test credentials and Mercado Pago test cardholder data;
- never mutate customer or reservation data to satisfy a provider sandbox convention.

This contract exists because a known-good CARD order succeeded before the sandbox email substitution was introduced, while later attempts failed after that substitution.
