import { invoicePrebookEmail } from './invoice-prebook-email.ts'
import { renderNotificationMessage } from './notification-email.ts'
Deno.test('invoice prebook e-mail replaces payment-only copy, including custom HTML', () => {
  for (const manual of [false, true]) {
    const template = invoicePrebookEmail({ id: 'test', title_template: 'Pay', body_template: 'Pay now', html_template: '<p>Pay now</p>', variable_schema: [] }, manual)
    const message = renderNotificationMessage(template, { 'customer.name': '<script>test</script>', 'invoice.due_at': '13/10/2026' }, 'Studio')
    if (message.text.includes('Pay now') || message.html.includes('<script>')) throw new Error('unsafe invoice copy')
    if (!message.text.includes('Não há pagamento antecipado')) throw new Error('missing invoice notice')
    if (!message.text.includes(manual ? 'nossa equipe' : 'pelo link')) throw new Error('wrong confirmation mode')
  }
})
