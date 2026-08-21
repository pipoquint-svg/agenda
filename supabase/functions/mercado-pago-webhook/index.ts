import { adminClient } from '../_shared/supabase.ts'
import {
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

async function getProviderPayment(paymentId: string): Promise<Record<string, unknown>> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 12000)
  try {
    const res = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(paymentId)}`, {
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

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  let body: Record<string, unknown>
  try {
    body = await req.json() as Record<string, unknown>
  } catch {
    return json({ error: { code: 'INVALID_JSON' } }, 400)
  }

  const type = typeof body.type === 'string' ? body.type : ''
  if (type && type !== 'payment') return json({ ok: true, ignored: 'UNSUPPORTED_EVENT_TYPE' })

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

    // The notification is only a signal. Full payment state is fetched from Mercado Pago.
    const rawPayment = await getProviderPayment(dataId)
    const snapshot = sanitizeMercadoPagoPayment(rawPayment)
    if (!snapshot.id || snapshot.id !== dataId) throw new Error('MERCADO_PAGO_PAYMENT_ID_MISMATCH')

    const client = adminClient()
    let transactionId: string | null = null

    if (snapshot.external_reference && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(snapshot.external_reference)) {
      const { data } = await client
        .from('payment_transactions')
        .select('id')
        .eq('id', snapshot.external_reference)
        .eq('provider', 'MERCADO_PAGO')
        .eq('transaction_type', 'CHARGE')
        .maybeSingle()
      transactionId = data?.id ?? null
    }

    if (!transactionId) {
      const { data } = await client
        .from('payment_transactions')
        .select('id')
        .eq('provider', 'MERCADO_PAGO')
        .eq('provider_payment_id', snapshot.id)
        .eq('transaction_type', 'CHARGE')
        .maybeSingle()
      transactionId = data?.id ?? null
    }

    // A payment from the same Mercado Pago application but unrelated to Agenda
    // must not trigger retries forever or mutate any booking.
    if (!transactionId) return json({ ok: true, ignored: 'PAYMENT_NOT_MANAGED_BY_AGENDA' })

    const normalized = normalizeMercadoPagoPaymentStatus(snapshot.status)
    const notificationId = body.id == null ? requestId : String(body.id)
    const action = typeof body.action === 'string' ? body.action : 'payment.updated'
    const eventKey = `webhook:${notificationId}:${action}:${dataId}`

    const { data: applied, error } = await client.rpc('apply_provider_payment_status', {
      p_transaction_id: transactionId,
      p_provider_payment_id: snapshot.id,
      p_normalized_status: normalized,
      p_event_key: eventKey,
      p_payload_json: snapshot,
      p_paid_at: snapshot.date_approved,
    })
    if (error) throw new Error(`PAYMENT_STATUS_APPLY_FAILED:${error.message}`)

    return json({ ok: true, state: applied })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'MERCADO_PAGO_WEBHOOK_FAILED'
    console.error('Mercado Pago webhook processing failed', message)
    const status = message.startsWith('MISSING_ENV') ? 503 : 500
    return json({ error: { code: message.split(':')[0] } }, status)
  }
})
