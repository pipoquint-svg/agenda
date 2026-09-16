import { adminClient } from '../_shared/supabase.ts'
import { scheduleImmediateAppointmentIntegrations } from '../_shared/integration-dispatch.ts'
import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'
import {
  assertMercadoPagoPaymentMatchesIntent,
  mercadoPagoPaymentStorageSnapshot,
  normalizeMercadoPagoPaymentStatus,
  sanitizeMercadoPagoPayment,
  verifyMercadoPagoWebhookSignature,
} from '../_shared/mercado-pago.ts'

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

function providerRuntime() {
  return mercadoPagoRuntime({
    environment: Deno.env.get('MERCADO_PAGO_ENV'),
    accessToken: Deno.env.get('MERCADO_PAGO_ACCESS_TOKEN'),
    allowRealCharges: Deno.env.get('ALLOW_REAL_CHARGES'),
    creatingCharge: false,
  })
}

async function getProviderOrder(orderId: string): Promise<Record<string, unknown>> {
  const runtime = providerRuntime()
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 12000)
  try {
    const res = await fetch(`https://api.mercadopago.com/v1/orders/${encodeURIComponent(orderId)}`, {
      headers: {
        authorization: `Bearer ${runtime.accessToken}`,
        accept: 'application/json',
      },
      signal: controller.signal,
    })
    if (!res.ok) throw new Error(`MERCADO_PAGO_LOOKUP_FAILED:${res.status}`)
    return await res.json() as Record<string, unknown>
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error('MERCADO_PAGO_PROVIDER_TIMEOUT')
    throw error
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

function signatureTimestamp(signature: string): string | null {
  const match = signature.match(/(?:^|,)\s*ts=([^,]+)/)
  const value = match?.[1]?.trim() ?? ''
  return /^\d{1,20}$/.test(value) ? value : null
}

function safeRequestId(value: string): string | null {
  const trimmed = value.trim()
  if (!trimmed) return null
  return trimmed.length <= 12 ? trimmed : `${trimmed.slice(0, 12)}…`
}

async function createReceipt(input: {
  dataId?: string | null
  eventType?: string | null
  action?: string | null
  liveMode?: boolean | null
  requestId?: string | null
  signaturePresent?: boolean
}): Promise<string | null> {
  try {
    const { data, error } = await adminClient()
      .from('mercado_pago_webhook_receipts')
      .insert({
        data_id: input.dataId || null,
        event_type: input.eventType || null,
        action: input.action || null,
        live_mode: input.liveMode ?? null,
        request_id_prefix: safeRequestId(input.requestId ?? ''),
        signature_present: input.signaturePresent === true,
        outcome: 'RECEIVED',
      })
      .select('id')
      .maybeSingle()
    if (error || !data?.id) return null
    return String(data.id)
  } catch {
    return null
  }
}

async function finishReceipt(
  receiptId: string | null,
  outcome: string,
  httpStatus: number,
  detail: string | null = null,
): Promise<void> {
  if (!receiptId) return
  try {
    await adminClient()
      .from('mercado_pago_webhook_receipts')
      .update({
        completed_at: new Date().toISOString(),
        outcome,
        http_status: httpStatus,
        detail: detail ? detail.slice(0, 160) : null,
      })
      .eq('id', receiptId)
  } catch {
    // Webhook processing must never depend on observability persistence.
  }
}

async function auditedResponse(
  receiptId: string | null,
  body: unknown,
  status: number,
  outcome: string,
  detail: string | null = null,
): Promise<Response> {
  await finishReceipt(receiptId, outcome, status, detail)
  return json(body, status)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  let body: Record<string, unknown>
  try {
    body = await req.json() as Record<string, unknown>
  } catch {
    const receiptId = await createReceipt({ signaturePresent: Boolean(req.headers.get('x-signature')) })
    return auditedResponse(receiptId, { error: { code: 'INVALID_JSON' } }, 400, 'INVALID_JSON')
  }

  const url = new URL(req.url)
  const dataId = dataIdFrom(url, body)
  const signature = req.headers.get('x-signature') ?? ''
  const requestId = req.headers.get('x-request-id') ?? ''
  const type = typeof body.type === 'string' ? body.type : ''
  const action = typeof body.action === 'string' ? body.action : ''
  const liveMode = typeof body.live_mode === 'boolean' ? body.live_mode : null
  const receiptId = await createReceipt({
    dataId,
    eventType: type,
    action,
    liveMode,
    requestId,
    signaturePresent: Boolean(signature),
  })

  if (!dataId || !signature) {
    console.error('[OPERATION_ALERT] MERCADO_PAGO_WEBHOOK_SIGNATURE_COMPONENT_MISSING', {
      has_data_id: Boolean(dataId),
      has_signature: Boolean(signature),
      has_request_id: Boolean(requestId),
      event_type: type || null,
      live_mode: liveMode,
    })
    return auditedResponse(receiptId, { error: { code: 'MERCADO_PAGO_SIGNATURE_REQUIRED' } }, 401, 'SIGNATURE_REQUIRED')
  }

  try {
    const valid = await verifyMercadoPagoWebhookSignature({
      signature,
      requestId: requestId || null,
      dataId,
      secret: requiredEnv('MERCADO_PAGO_WEBHOOK_SECRET'),
    })
    if (!valid) {
      console.error('[OPERATION_ALERT] MERCADO_PAGO_WEBHOOK_SIGNATURE_INVALID', {
        data_id: dataId,
        data_id_alphanumeric: /[A-Za-z]/.test(dataId),
        has_request_id: Boolean(requestId),
        request_id_prefix: safeRequestId(requestId),
        signature_ts: signatureTimestamp(signature),
        event_type: type || null,
        live_mode: liveMode,
      })
      return auditedResponse(receiptId, { error: { code: 'MERCADO_PAGO_SIGNATURE_INVALID' } }, 401, 'SIGNATURE_INVALID')
    }

    if (type && type !== 'order' && type !== 'orders') {
      return auditedResponse(receiptId, { ok: true, ignored: 'UNSUPPORTED_EVENT_TYPE' }, 200, 'IGNORED', 'UNSUPPORTED_EVENT_TYPE')
    }

    const runtime = providerRuntime()
    if (typeof body.live_mode !== 'boolean') {
      return auditedResponse(receiptId, { ok: true, ignored: 'LIVE_MODE_MISSING' }, 200, 'IGNORED', 'LIVE_MODE_MISSING')
    }
    if (runtime.environment === 'sandbox' && body.live_mode === true) {
      return auditedResponse(receiptId, { ok: true, ignored: 'LIVE_EVENT_IN_SANDBOX' }, 200, 'IGNORED', 'LIVE_EVENT_IN_SANDBOX')
    }
    if (runtime.environment === 'production' && body.live_mode === false) {
      return auditedResponse(receiptId, { ok: true, ignored: 'TEST_EVENT_IN_PRODUCTION' }, 200, 'IGNORED', 'TEST_EVENT_IN_PRODUCTION')
    }

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

    if (!transaction) {
      return auditedResponse(receiptId, { ok: true, ignored: 'ORDER_NOT_MANAGED_BY_AGENDA' }, 200, 'IGNORED', 'ORDER_NOT_MANAGED_BY_AGENDA')
    }
    if (transaction.method !== 'PIX' && transaction.method !== 'CARD') {
      return auditedResponse(receiptId, { ok: true, ignored: 'PAYMENT_INTENT_INVALID' }, 200, 'IGNORED', 'PAYMENT_INTENT_INVALID')
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
      console.error('Mercado Pago Order webhook did not match internal intent', { code })
      const { error: quarantineError } = await client.rpc('service_quarantine_provider_payment_mismatch', {
        p_transaction_id: transaction.id,
        p_provider_payment_id: snapshot.id || dataId,
        p_reason: code,
        p_payload_json: storedSnapshot,
      })
      if (quarantineError) {
        return auditedResponse(receiptId, { error: { code: 'PAYMENT_MISMATCH_QUARANTINE_FAILED' } }, 500, 'ERROR', 'PAYMENT_MISMATCH_QUARANTINE_FAILED')
      }
      return auditedResponse(receiptId, { ok: true, ignored: 'PAYMENT_INTENT_MISMATCH' }, 200, 'QUARANTINED', code)
    }

    const normalized = normalizeMercadoPagoPaymentStatus(snapshot.status)
    const notificationId = body.id == null ? (requestId || dataId) : String(body.id)
    const providerAction = action || 'order.updated'
    const eventKey = `webhook-order:${notificationId}:${providerAction}:${dataId}:${snapshot.raw_status ?? snapshot.status ?? 'unknown'}:${snapshot.status_detail ?? 'none'}`

    const { data: applied, error } = await client.rpc('apply_provider_payment_status', {
      p_transaction_id: transaction.id,
      p_provider_payment_id: snapshot.id,
      p_normalized_status: normalized,
      p_event_key: eventKey,
      p_payload_json: storedSnapshot,
      p_paid_at: snapshot.date_approved,
    })
    if (error) throw new Error('PAYMENT_STATUS_APPLY_FAILED')

    const appointmentId = applied && typeof applied === 'object' && typeof applied.appointment_id === 'string'
      ? applied.appointment_id
      : transaction.appointment_id
    if (normalized === 'APPROVED') {
      scheduleImmediateAppointmentIntegrations(appointmentId, 'MERCADO_PAGO_WEBHOOK')
    }

    await finishReceipt(receiptId, 'APPLIED', 200, normalized)
    return json({ ok: true, state: applied })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'MERCADO_PAGO_WEBHOOK_FAILED'
    const code = message.split(':')[0]
    console.error('Mercado Pago Order webhook processing failed', { code })
    const status = code === 'MERCADO_PAGO_ENV_INVALID'
      || code === 'MERCADO_PAGO_SANDBOX_TOKEN_REQUIRED'
      || code === 'MERCADO_PAGO_PRODUCTION_TOKEN_REQUIRED'
      || code === 'MISSING_ENV' ? 503 : 500
    return auditedResponse(receiptId, { error: { code } }, status, 'ERROR', code)
  }
})
