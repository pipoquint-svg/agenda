# Mercado Pago remediation notes

Known-good evidence: a CARD transaction was approved in the same sandbox before the payer email substitution introduced in PR #169. Current remediation restores payer identity consistency while keeping all other Orders API fields unchanged.
