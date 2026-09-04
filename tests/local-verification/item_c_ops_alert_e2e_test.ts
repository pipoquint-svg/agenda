import { createClient } from 'npm:@supabase/supabase-js@2'
import { sendEmailWithProvider } from '../../supabase/functions/_shared/email-provider.ts'
import { runOpsAlertCycle } from '../../supabase/functions/_shared/ops-alerts.ts'

const API_URL = requiredEnv('LOCAL_API_URL').replace(/\/+$/, '')
const SERVICE_ROLE_KEY = requiredEnv('LOCAL_SERVICE_ROLE_KEY')
const client = createClient(API_URL, SERVICE_ROLE_KEY, { auth: { persistSession: false, autoRefreshToken: false } })

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? ''
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function isoBefore(now: Date, minutes: number): string {
  return new Date(now.getTime() - minutes * 60_000).toISOString()
}

async function insertOrFail(table: string, value: Record<string, unknown> | Record<string, unknown>[]): Promise<void> {
  const { error } = await client.from(table).insert(value)
  if (error) throw new Error(`ITEM_C_FIXTURE_${table.toUpperCase()}_FAILED:${error.code}:${error.message}`)
}

Deno.test('Item C local E2E: all five controlled failures reach one PII-free deduplicated email alert', async () => {
  const seedNow = new Date()
  const sentinel = 'cliente-secreto@example.test|+5511999999999|tok_super_secret_123|4111111111111111|9876.54'
  const { data: appointments, error: appointmentError } = await client.from('appointments').select('id').order('created_at').limit(1)
  if (appointmentError) throw new Error(`ITEM_C_APPOINTMENT_QUERY_FAILED:${appointmentError.code}`)
  const appointmentId = appointments?.[0]?.id
  assert(typeof appointmentId === 'string', 'Item 1 must create a real local booking before Item C E2E')

  await insertOrFail('payment_transactions', {
    appointment_id: appointmentId,
    transaction_type: 'CHARGE',
    method: 'PIX',
    provider: 'MANUAL',
    status: 'PENDING',
    contract_amount_settled: 0,
    cash_amount: 0,
    notes: sentinel,
    provider_payload_json: { forbidden_sentinel: sentinel },
    idempotency_key: `item-c-payment-${crypto.randomUUID()}`,
    payment_purpose: 'CONTRACT',
    created_at: isoBefore(seedNow, 16),
    updated_at: isoBefore(seedNow, 16),
  })

  const { error: edgeError } = await client.rpc('service_record_ops_edge_failure', {
    p_function_name: 'booking-submit',
    p_error_code: 'CONTROLLED_LOCAL_FAILURE',
    p_http_status: 500,
  })
  if (edgeError) throw new Error(`ITEM_C_EDGE_FIXTURE_FAILED:${edgeError.code}`)

  await insertOrFail('integration_jobs', [0, 1, 2].map((index) => ({
    job_type: 'ITEM_C_LOCAL_INTEGRATION',
    entity_type: 'APPOINTMENT',
    entity_id: appointmentId,
    payload_json: { forbidden_sentinel: sentinel },
    status: 'FAILED',
    attempt_count: 1,
    last_error: sentinel,
    idempotency_key: `item-c-integration-${index}-${crypto.randomUUID()}`,
    created_at: isoBefore(seedNow, 2 + index),
    updated_at: isoBefore(seedNow, 2 + index),
    processed_at: isoBefore(seedNow, 2 + index),
  })))

  const connectionId = crypto.randomUUID()
  const calendarId = crypto.randomUUID()
  const eventId = crypto.randomUUID()
  await insertOrFail('google_connections', {
    id: connectionId,
    account_email: `local-${crypto.randomUUID()}@example.test`,
    status: 'REVOKED',
  })
  await insertOrFail('google_calendars', {
    id: calendarId,
    google_connection_id: connectionId,
    google_calendar_id: `item-c-${crypto.randomUUID()}`,
    name: 'ITEM C LOCAL ONLY',
    is_active: false,
  })
  await insertOrFail('google_calendar_events', {
    id: eventId,
    google_calendar_id: calendarId,
    google_event_id: `item-c-${crypto.randomUUID()}`,
    status: 'confirmed',
    is_all_day: false,
    start_at: '2035-01-20T10:00:00.000Z',
    end_at: '2035-01-20T11:00:00.000Z',
    qualification: 'BLOCKING',
    normalized_payload: { forbidden_sentinel: sentinel },
  })
  await insertOrFail('schedule_divergences', {
    resource_id: '99100000-0000-0000-0000-000000000001',
    google_calendar_event_id: eventId,
    source: 'GOOGLE',
    desired_range: '[2035-01-20 10:00:00+00,2035-01-20 11:00:00+00)',
    status: 'OPEN',
    reason: 'CONTROLLED_LOCAL_DIVERGENCE',
    detected_at: isoBefore(seedNow, 16),
  })

  await insertOrFail('notification_delivery_logs', {
    event_key: 'APPOINTMENT_APPROVED',
    channel: 'EMAIL',
    audience: 'CUSTOMER',
    appointment_id: appointmentId,
    status: 'FAILED',
    attempt_count: 1,
    last_error_code: 'EMAIL_PROVIDER_HTTP_500',
    idempotency_key: `item-c-email-${crypto.randomUUID()}`,
    payload_snapshot: { forbidden_sentinel: sentinel },
    created_at: isoBefore(seedNow, 1),
    updated_at: isoBefore(seedNow, 1),
  })

  const now = new Date()
  const outbound: Array<{ url: string; body: string }> = []
  const send = async (email: { subject: string; text: string; html: string }) => await sendEmailWithProvider({
    from: 'BlackSheep <agenda@example.test>',
    to: ['operacao@example.test'],
    subject: email.subject,
    text: email.text,
    html: email.html,
  }, `item-c-local-${crypto.randomUUID()}`, {
    apiKey: 'local-only-key',
    fetchImpl: (async (input: string | URL | Request, init?: RequestInit) => {
      outbound.push({ url: String(input), body: String(init?.body ?? '') })
      return new Response(JSON.stringify({ id: 'item-c-local-provider-message' }), { status: 200 })
    }) as typeof fetch,
  })

  const first = await runOpsAlertCycle(client, { now, send })
  assert(first.incident_count === 5, `all five categories must be active, got ${first.incident_count}`)
  assert(first.notified_count === 5, `all five categories must be delivered, got ${first.notified_count}`)
  assert(outbound.length === 1, `one batched email must reach the provider, got ${outbound.length}`)
  assert(outbound[0].url === 'https://api.resend.com/emails', 'alert must use the central email provider')
  for (const category of ['PAYMENT_STUCK', 'EDGE_FAILURE', 'INTEGRATION_FAILURES', 'SCHEDULE_DIVERGENCE', 'EMAIL_FAILURE']) {
    assert(outbound[0].body.includes(category), `outbound alert is missing ${category}`)
  }
  for (const secretPart of sentinel.split('|')) assert(!outbound[0].body.includes(secretPart), `outbound alert leaked ${secretPart}`)

  const second = await runOpsAlertCycle(client, { now: new Date(now.getTime() + 60_000), send })
  assert(second.incident_count === 5, 'controlled incidents must still be observable on the second cycle')
  assert(second.notified_count === 0, 'equal fingerprints must be suppressed inside 60 minutes')
  assert(outbound.length === 1, 'deduplicated cycle must not call the provider again')

  const { data: states, error: statesError } = await client.from('ops_alert_states').select('category,last_notified_at,notification_count').is('resolved_at', null)
  if (statesError) throw new Error(`ITEM_C_STATE_QUERY_FAILED:${statesError.code}`)
  assert(states?.length === 5, `five active dedup states expected, got ${states?.length}`)
  assert(states.every((state) => state.last_notified_at && state.notification_count === 1), 'every category must record exactly one delivery')
})
