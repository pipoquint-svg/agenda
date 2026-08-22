import { assertEquals } from 'jsr:@std/assert@1'
import { customerFinancialTermsChanged } from './customerTermsPermission.ts'

Deno.test('existing INVOICE customer may change non-financial fields without financial change', () => {
  assertEquals(customerFinancialTermsChanged(
    { billing_mode: 'INVOICE', invoice_due_days: 15 },
    { billing_mode: 'INVOICE', invoice_due_days: 15 },
  ), false)
})

Deno.test('changing invoice due days is a financial change', () => {
  assertEquals(customerFinancialTermsChanged(
    { billing_mode: 'INVOICE', invoice_due_days: 15 },
    { billing_mode: 'INVOICE', invoice_due_days: 30 },
  ), true)
})

Deno.test('switching checkout to invoice is a financial change', () => {
  assertEquals(customerFinancialTermsChanged(
    { billing_mode: 'CHECKOUT', invoice_due_days: null },
    { billing_mode: 'INVOICE', invoice_due_days: 15 },
  ), true)
})

Deno.test('new checkout terms do not require financial management', () => {
  assertEquals(customerFinancialTermsChanged(
    null,
    { billing_mode: 'CHECKOUT', invoice_due_days: null },
  ), false)
})
