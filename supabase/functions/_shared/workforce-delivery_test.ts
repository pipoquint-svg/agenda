import { assert, assertEquals } from 'jsr:@std/assert@1'
import { errorCode, renderDelivery, renderNotification, runWorkforceDeliveryCycle, type CycleResult } from './workforce-delivery.ts'

const report = {
  employer: { legal_name: 'Pierri Quint Produções', trade_name: 'BlackSheep Estúdio Criativo', cnpj: '11222333000181' },
  competencia: '2026-10',
  employee: { display_name: 'Jheneffe' },
  habitual_schedules: [],
  rows: [{ date: '2026-10-06', weekday: 'terça-feira', period: '18:00–20:00', type: 'EXTRA_WORK', classification: 'EXTRA_WEEKDAY', administrative_classification: null, minutes: 45, status: 'VALIDATED' }],
  totals: { extra_weekday_minutes: 45, extra_saturday_minutes: 240, extra_sunday_minutes: 0, extra_holiday_minutes: 0 },
}

function cycle(): CycleResult {
  return {
    closed_periods: 1,
    blocked_periods: 0,
    deliveries: [
      { delivery_id: 'd1', idempotency_key: 'workforce-report:c:1:contadora@x.test:ACCOUNTANT_MIRROR', recipient_email: 'contadora@x.test', recipient_kind: 'ACCOUNTANT', report_kind: 'ACCOUNTANT_MIRROR', version: 1, attempt: 1, report },
      { delivery_id: 'd2', idempotency_key: 'workforce-report:c:1:j@x.test:EMPLOYEE_MIRROR', recipient_email: 'j@x.test', recipient_kind: 'EMPLOYEE', report_kind: 'EMPLOYEE_MIRROR', version: 1, attempt: 1, report },
    ],
    notifications: [
      { notification_id: 'n1', idempotency_key: 'workforce-receipt:RECORD_COMPLETED:x:v1', recipient_email: 'j@x.test', event_kind: 'RECORD_COMPLETED', attempt: 1, employer_legal_name: 'Pierri Quint Produções', employee_display_name: 'Jheneffe', payload: { exception_type: 'EXTRA_WORK', event_date: '2026-10-06', start_local: '2026-10-06T18:00', end_local: '2026-10-06T20:00', status: 'PENDING_REVIEW' } },
    ],
  }
}

Deno.test('sends each claimed item once with its idempotency key and records SENT', async () => {
  const sent: Array<{ to: string; key: string; attachments: number }> = []
  const recorded: Array<[string, string, boolean]> = []
  const summary = await runWorkforceDeliveryCycle({
    runCycle: async () => cycle(),
    recordResult: async (kind, id, success) => { recorded.push([kind, id, success]) },
    send: async (email, key) => { sent.push({ to: email.to, key, attachments: email.attachments?.length ?? 0 }); return `re_${sent.length}` },
  })
  assertEquals(sent.map((item) => item.key), [
    'workforce-report:c:1:contadora@x.test:ACCOUNTANT_MIRROR',
    'workforce-report:c:1:j@x.test:EMPLOYEE_MIRROR',
    'workforce-receipt:RECORD_COMPLETED:x:v1',
  ])
  assertEquals(sent[0].attachments, 1, 'accountant report carries the PDF')
  assertEquals(recorded, [['DELIVERY', 'd1', true], ['DELIVERY', 'd2', true], ['NOTIFICATION', 'n1', true]])
  assertEquals(summary.deliveries_sent, 2)
})

Deno.test('a provider failure is recorded as FAILED with a shaped code and the cycle continues', async () => {
  const recorded: Array<[string, boolean, string | null]> = []
  const summary = await runWorkforceDeliveryCycle({
    runCycle: async () => cycle(),
    recordResult: async (_kind, id, success, _provider, code) => { recorded.push([id, success, code]) },
    send: async (email) => {
      if (email.to === 'contadora@x.test') throw new Error('EMAIL_PROVIDER_HTTP_500')
      return 're_ok'
    },
  })
  assertEquals(recorded[0], ['d1', false, 'EMAIL_PROVIDER_HTTP_500'])
  assertEquals(recorded[1], ['d2', true, null])
  assertEquals(summary.deliveries_failed, 1)
  assertEquals(summary.closed_periods, 1, 'the closure is reported as done regardless of the e-mail outcome')
  assertEquals(errorCode(new Error('weird: provider said <html>')), 'SEND_FAILED')
})

Deno.test('e-mails use razão social and carry no free text', () => {
  const accountant = renderDelivery(cycle().deliveries[0])
  assert(accountant.subject.includes('Pierri Quint Produções'))
  assert(accountant.text.includes('Extra em sábado: 4h00'))
  assert(!/R\$|salário|DSR|FGTS|INSS/i.test(accountant.text), 'no monetary content')
  const unsafe = cycle().notifications[0]
  ;(unsafe.payload as Record<string, unknown>).note = 'NOTA-SECRETA'
  const receipt = renderNotification(unsafe)
  assert(!receipt.text.includes('NOTA-SECRETA'))
  assert(receipt.text.includes('06/10/2026 18:00–20:00'))
  const rectification = renderDelivery({ ...cycle().deliveries[0], version: 2 })
  assert(rectification.subject.includes('versão 2'))
})
