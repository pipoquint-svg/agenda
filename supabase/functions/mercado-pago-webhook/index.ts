import { adminClient } from '../_shared/supabase.ts'
import {
  assertMercadoPagoPaymentMatchesIntent,
  mercadoPagoPaymentStorageSnapshot,
  normalizeMercadoPagoPaymentStatus,
  sanitizeMercadoPagoPayment,
  verifyMercadoPagoWebhookSignature,
} from '../_shared/mercado-pago.ts'

declare const EdgeRuntime: {
  waitUntil(promise: Promise<unknown>): void
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  })
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

async function getProviderOrder(orderId: string): Promise<Record<string, unknown>> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 12000)
  try {
    const res = await fetch(`https://api.mercadopago.com/v1/orders/${encodeURIComponent(orderId)}`, {
      headers: {
        authorization: `Bearer ${requiredEnv('MERCADO_PAGO_ACCESS_TOKEN')}`,
        accept: 'application/json',
      },
      signal: controller.signal,
    })
    if (!res.ok) throw new Error(`MERCADO_PAGO_LOOKUP_FAILED:${res.status}`)
    return await res.json() as Record<string, unknown>
  } finally {
    clearTimeout(timer)
  }
}

function dataIdFrom(url: URL, body: Record<string, unknown>): string {
  const query = url.searchParams.get('data.id') ?? url.searchParams.get('data_id')
  if (query) return query
  const data = body.data && typeof body.data === 'object' ? body.data as Record<string, unknown> : null
  return data?.id == null ? '' : String(data.id)
}

async function tryImmediateConfirmationEmail(
  client: ReturnType<typeof adminClient>,
  appointmentId: string,
  normalizedPaymentStatus: string,
): Promise<void> {
  if (normalizedPaymentStatus !== 'APPROVED' || !appointmentId) return

  try {
    const { data: appointment, error: appointmentError } = await client
      .from('appointments')
      .select('id,status,version')
      .eq('id', appointmentId)
      .maybeSingle()
    if (appointmentError || !appointment || appointment.status !== 'CONFIRMED') return

    // Only an actual confirmation outbox event authorizes this best-effort fast path.
    // The durable job remains pending until integration-worker consumes it, so any
    // failure here is retried later. Resend idempotency prevents duplicate delivery.
    const { data: jobs, error: jobError } = await client
      .from('integration_jobs')
      .select('entity_version,payload_json')
      .eq('job_type', 'APPOINTMENT_CONFIRMED_MESSAGE')
      .eq('entity_id', appointment.id)
      .eq('entity_version', appointment.version)
      .eq('status', 'PENDING')
      .order('created_at', { ascending: false })
      .limit(1)
    if (jobError || !jobs?.length) return

    const base = Deno.env.get('SUPABASE_URL')?.trim().replace(/\/$/, '') ?? ''
    const internalSecret = Deno.env.get('INTEGRATION_INTERNAL_SECRET')?.trim() ?? ''
    if (!base || !internalSecret) {
      console.error('Immediate confirmation email skipped: internal runtime not configured', { appointmentId })
      return
    }

    const reason = typeof jobs[0]?.payload_json?.reason === 'string'
      ? jobs[0].payload_json.reason
      : 'CONFIRMED'
    const controller = new AbortController()
    const timer = setTimeout(() => controller.abort(), 8000)
    try {
      const response = await fetch(`${base}/functions/v1/email-send`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-internal-secret': internalSecret,
        },
        body: JSON.stringify({
          appointment_id: appointment.id,
          entity_version: appointment.version,
          reason,
        }),
        signal: controller.signal,
      })

      if (!response.ok) {
        console.error('Immediate confirmation email failed; durable outbox retained', {
          appointmentId,
          status: response.status,
        })
        return
      }

      console.log('Immediate confirmation email attempt completed', {
        appointmentId,
        entityVersion: appointment.version,
      })
    } finally {
      clearTimeout(timer)
    }
  } catch (error) {
    console.error('Immediate confirmation email failed; durable outbox retained', {
      appointmentId,
      code: error instanceof Error ? error.message.split(':')[0] : 'UNKNOWN',
    })
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  let body: Record<string, unknown>
  try {
    body = await req.json() as Record<string, unknown>
  } catch {
    return json({ error: { code: 'INVALID_JSON' } }, 400)
  }

  const url = new URL(req.url)
  const dataId = dataIdFrom(url, body)
  const signature = req.headers.get('x-signature') ?? ''
  const requestId = req.headers.get('x-request-id') ?? ''
  if (!dataId || !signature || !requestId) return json({ error: { code: 'MERCADO_PAGO_SIGNATURE_REQUIRED' } }, 401)

  try {
    const valid = await verifyMercadoPagoWebhookSignature({
      signature,
      requestId,
      dataId,
      secret: requiredEnv('MERCADO_PAGO_WEBHOOK_SECRET'),
    })
    if (!valid) return json({ error: { code: 'MERCADO_PAGO_SIGNATURE_INVALID' } }, 401)

    const type = typeof body.type === 'string' ? body.type : ''
    if (type && type !== 'order' && type !== 'orders') {
      return json({ ok: true, ignored: 'UNSUPPORTED_EVENT_TYPE' })
    }

    // Fail closed across environments: a live provider event never mutates sandbox,
    // and a test event never mutates a future production deployment.
    const mpEnv = Deno.env.get('MERCADO_PAGO_ENV')?.trim().toLowerCase() ?? ''
    if (mpEnv === 'sandbox' && body.live_mode === true) {
      console.error('Ignoring live Mercado Pago Order event in sandbox', { dataId, requestId })
      return json({ ok: true, ignored: 'LIVE_EVENT_IN_SANDBOX' })
    }
    if (mpEnv === 'production' && body.live_mode === false) {
      console.error('Ignoring Mercado Pago test Order event in production', { dataId, requestId })
      return json({ ok: true, ignored: 'TEST_EVENT_IN_PRODUCTION' })
    }

    // The notification is only a signal. Full Order state is always re-fetched.
    const rawOrder = await getProviderOrder(dataId)
    const snapshot = sanitizeMercadoPagoPayment(rawOrder)
    const storedSnapshot = mercadoPagoPaymentStorageSnapshot(snapshot)

    const client = adminClient()
    let transaction: { id: string; appointment_id: string; cash_amount: number | string; method: string } | null = null

    if (snapshot.external_reference && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(snapshot.external_reference)) {
      const { data } = await client
        .from('payment_transactions')
        .select('id,appointment_id,cash_amount,method')
        .eq('id', snapshot.external_reference)
        .eq('provider', 'MERCADO_PAGO')
        .eq('transaction_type', 'CHARGE')
        .maybeSingle()
      transaction = data ?? null
    }

    if (!transaction) {
      const { data } = await client
        .from('payment_transactions')
        .select('id,appointment_id,cash_amount,method')
        .eq('provider', 'MERCADO_PAGO')
        .eq('provider_payment_id', dataId)
        .eq('transaction_type', 'CHARGE')
        .maybeSingle()
      transaction = data ?? null
    }

    // Orders unrelated to Agenda are acknowledged without mutating any booking.
    if (!transaction) return json({ ok: true, ignored: 'ORDER_NOT_MANAGED_BY_AGENDA' })
    if (transaction.method !== 'PIX' && transaction.method !== 'CARD') {
      console.error('Mercado Pago managed transaction has invalid method', transaction.id)
      return json({ ok: true, ignored: 'PAYMENT_INTENT_INVALID' })
    }

    let validationError: unknown = null
    if (!snapshot.id) validationError = new Error('MERCADO_PAGO_PAYMENT_ID_MISSING')
    else if (snapshot.id !== dataId) validationError = new Error('MERCADO_PAGO_PAYMENT_ID_MISMATCH')
    else {
      try {
        assertMercadoPagoPaymentMatchesIntent(snapshot, {
          transactionId: transaction.id,
          cashAmount: transaction.cash_amount,
          method: transaction.method,
        })
      } catch (cause) {
        validationError = cause
      }
    }

    if (validationError) {
      const code = validationError instanceof Error && validationError.message.startsWith('MERCADO_PAGO_')
        ? validationError.message
        : 'MERCADO_PAGO_PAYMENT_METHOD_MISMATCH'
      console.error('Mercado Pago Order webhook did not match internal intent', {
        transactionId: transaction.id,
        notificationOrderId: dataId,
        providerOrderId: snapshot.id || null,
        providerTransactionId: snapshot.provider_transaction_id,
        code,
      })
      const { error: quarantineError } = await client.rpc('service_quarantine_provider_payment_mismatch', {
        p_transaction_id: transaction.id,
        p_provider_payment_id: snapshot.id || dataId,
        p_reason: code,
        p_payload_json: storedSnapshot,
      })
      if (quarantineError) {
        console.error('Failed to persist Mercado Pago Order mismatch quarantine', quarantineError.message)
        return json({ error: { code: 'PAYMENT_MISMATCH_QUARANTINE_FAILED' } }, 500)
      }
      // Signed event is acknowledged to avoid retry storms, but state is never applied.
      return json({ ok: true, ignored: 'PAYMENT_INTENT_MISMATCH' })
    }

    const normalized = normalizeMercadoPagoPaymentStatus(snapshot.status)
    const notificationId = body.id == null ? requestId : String(body.id)
    const action = typeof body.action === 'string' ? body.action : 'order.updated'
    const eventKey = `webhook-order:${notificationId}:${action}:${dataId}:${snapshot.raw_status ?? snapshot.status ?? 'unknown'}:${snapshot.status_detail ?? 'none'}`

    const { data: applied, error } = await client.rpc('apply_provider_payment_status', {
      p_transaction_id: transaction.id,
      p_provider_payment_id: snapshot.id,
      p_normalized_status: normalized,
      p_event_key: eventKey,
      p_payload_json: storedSnapshot,
      p_paid_at: snapshot.date_approved,
    })
    if (error) throw new Error(`PAYMENT_STATUS_APPLY_FAILED:${error.message}`)

    const appointmentId = applied && typeof applied === 'object' && typeof applied.appointment_id === 'string'
      ? applied.appointment_id
      : transaction.appointment_id
    EdgeRuntime.waitUntil(tryImmediateConfirmationEmail(client, appointmentId, normalized))

    return json({ ok: true, state: applied })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'MERCADO_PAGO_WEBHOOK_FAILED'
    console.error('Mercado Pago Order webhook processing failed', message)
    const status = message.startsWith('MISSING_ENV') ? 503 : 500
    return json({ error: { code: message.split(':')[0] } }, status)
  }
})
