import {
  buildOpsIncidents,
  renderOpsAlertEmail,
  resolveOpsAlertRecipient,
  sanitizeOpsCode,
  selectDueOpsIncidents,
  type OpsSnapshot,
} from './ops-alerts.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

const NOW = new Date('2035-01-15T12:00:00.000Z')

function completeSnapshot(): OpsSnapshot {
  return {
    pendingPayments: [{ status: 'PENDING', created_at: '2035-01-15T11:44:59.000Z' }],
    edgeFailures: [{ function_name: 'booking-submit', error_code: 'CHECKOUT_RPC_FAILED', http_status: 500, occurred_at: '2035-01-15T11:59:00.000Z' }],
    integrationFailures: [
      { job_type: 'GOOGLE_APPOINTMENT_SYNC', status: 'FAILED', created_at: '2035-01-15T11:47:00.000Z' },
      { job_type: 'GOOGLE_APPOINTMENT_SYNC', status: 'FAILED', created_at: '2035-01-15T11:48:00.000Z' },
      { job_type: 'GOOGLE_APPOINTMENT_SYNC', status: 'FAILED', created_at: '2035-01-15T11:49:00.000Z' },
    ],
    openScheduleDivergences: [{ source: 'GOOGLE', reason: 'EVENT_CONFLICT', status: 'OPEN', detected_at: '2035-01-15T11:44:59.000Z' }],
    emailFailures: [{ event_key: 'APPOINTMENT_APPROVED', status: 'FAILED', last_error_code: 'EMAIL_PROVIDER_HTTP_500', updated_at: '2035-01-15T11:59:00.000Z' }],
  }
}

Deno.test('Item C emits all five required incident categories at the agreed thresholds', () => {
  const incidents = buildOpsIncidents(completeSnapshot(), NOW)
  assert(incidents.length === 5, `expected 5 incidents, got ${incidents.length}`)
  assert(incidents.some((item) => item.category === 'PAYMENT_STUCK'), 'stuck payment alert is mandatory')
  assert(incidents.some((item) => item.category === 'EDGE_FAILURE'), 'Edge failure alert is mandatory')
  assert(incidents.some((item) => item.category === 'INTEGRATION_FAILURES'), 'integration threshold alert is mandatory')
  assert(incidents.some((item) => item.category === 'SCHEDULE_DIVERGENCE'), 'schedule divergence alert is mandatory')
  assert(incidents.some((item) => item.category === 'EMAIL_FAILURE'), 'email failure alert is mandatory')
})

Deno.test('Item C respects 15 minute SLAs and three-in-fifteen integration threshold', () => {
  const snapshot = completeSnapshot()
  snapshot.pendingPayments[0].created_at = '2035-01-15T11:45:01.000Z'
  snapshot.openScheduleDivergences[0].detected_at = '2035-01-15T11:45:01.000Z'
  snapshot.integrationFailures.pop()
  const incidents = buildOpsIncidents(snapshot, NOW)
  assert(!incidents.some((item) => item.category === 'PAYMENT_STUCK'), 'payment before SLA must not alert')
  assert(!incidents.some((item) => item.category === 'SCHEDULE_DIVERGENCE'), 'divergence before SLA must not alert')
  assert(!incidents.some((item) => item.category === 'INTEGRATION_FAILURES'), 'two failures must not alert')
})

Deno.test('Item C deduplicates equal fingerprints for 60 minutes', () => {
  const incidents = buildOpsIncidents(completeSnapshot(), NOW)
  const states = incidents.map((incident, index) => ({
    fingerprint: incident.fingerprint,
    last_notified_at: index === 0 ? '2035-01-15T10:59:59.000Z' : '2035-01-15T11:00:01.000Z',
  }))
  const due = selectDueOpsIncidents(incidents, states, NOW)
  assert(due.length === 1, `only the state older than 60 minutes is due, got ${due.length}`)
  assert(due[0].fingerprint === incidents[0].fingerprint, 'wrong incident escaped deduplication')
})

Deno.test('Item C sanitizes codes and alert content contains no supplied PII, token, amount or card value', () => {
  const sentinels = [
    'cliente-secreto@example.test',
    '+5511999999999',
    'tok_super_secret_123',
    '4111111111111111',
    '9876.54',
  ]
  const sanitized = sanitizeOpsCode(`rpc failed ${sentinels.join(' ')}`)
  assert(sanitized === 'UNCLASSIFIED_ERROR', 'free-form errors must collapse to a non-sensitive code')
  for (const sentinel of sentinels) assert(!sanitized.includes(sentinel), `sanitized code leaked: ${sentinel}`)

  const rendered = renderOpsAlertEmail(buildOpsIncidents(completeSnapshot(), NOW), NOW)
  const body = `${rendered.subject}\n${rendered.text}\n${rendered.html}`
  for (const sentinel of sentinels) assert(!body.includes(sentinel), `sensitive sentinel leaked: ${sentinel}`)
  assert(body.includes('PAYMENT_STUCK'), 'rendered alert must identify the category')
  assert(body.includes('Sem dados pessoais'), 'rendered alert must state the privacy contract')
})

Deno.test('Item C resolves the operational recipient from the canonical sender when optional overrides are absent', () => {
  const recipient = resolveOpsAlertRecipient({
    dedicatedRecipient: null,
    replyTo: null,
    sender: 'BlackSheep Estúdio Criativo <agenda@blacksheepestudiocriativo.com.br>',
  })
  assert(recipient === 'agenda@blacksheepestudiocriativo.com.br', `unexpected recipient: ${recipient}`)

  const dedicated = resolveOpsAlertRecipient({
    dedicatedRecipient: 'operacoes@example.test',
    replyTo: 'respostas@example.test',
    sender: 'BlackSheep <agenda@example.test>',
  })
  assert(dedicated === 'operacoes@example.test', 'dedicated recipient must have priority')

  let rejected = false
  try {
    resolveOpsAlertRecipient({ sender: 'agenda@example.test\nBcc: attacker@example.test' })
  } catch (error) {
    rejected = error instanceof Error && error.message === 'OPS_ALERT_RECIPIENT_MISSING'
  }
  assert(rejected, 'header-injection recipient must be rejected')
})
