# Mercado Pago remediation checklist

- [x] Evidence captured before behavior change
- [x] Payer email preserved instead of sandbox substitution
- [x] Webhook manifest omits absent request id
- [x] Lowercase alphanumeric order id retained
- [x] Regression test added for absent request id
- [ ] CI green
- [ ] Sandbox Edge Functions deployed
- [ ] Manual APRO reconciled
- [ ] Manual OTHE rejected as expected
