import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

async function stableKey(value: string): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))
  return Array.from(digest).map((b) => b.toString(16).padStart(2, '0')).join('')
}

async function cancelOrder(orderId: string, idempotencyKey: string): Promise<{ ok: boolean; status: number; code: string | null }> {
  const runtime = mercadoPagoRuntime({
    environment: Deno.env.get('MERCADO_PAGO_ENV'),
    accessToken: Deno.env.get('MERCADO_PAGO_ACCESS_TOKEN'),
    allowRealCharges: Deno.env.get('ALLOW_REAL_CHARGES'),
    creatingCharge: false,
  })
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)
  try {
    const response = await fetch(`https://api.mercadopago.com/v1/orders/${encodeURIComponent(orderId)}/cancel`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${runtime.accessToken}`,
        accept: 'application/json',
        'content-type': 'application/json',
        'x-idempotency-key': idempotencyKey,
      },
      signal: controller.signal,
    })
    const body = await response.json().catch(() => ({})) as Record<string, unknown>
    const errors = Array.isArray(body.errors) ? body.errors : []
    const code = typeof body.error === 'string' ? body.error
      : typeof errors[0] === 'object' && errors[0] && typeof (errors[0] as Record<string, unknown>).code === 'string'
        ? String((errors[0] as Record<string, unknown>).code)
        : null
    const alreadyCancelled = response.status === 409 && code === 'order_already_canceled'
    return { ok: response.ok || alreadyCancelled, status: response.status, code }
  } finally {
    clearTimeout(timer)
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
  try {
    requireInternal(req)
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const collectionId = String(body.collection_id ?? '').trim()
    const reason = String(body.reason ?? '').trim().toUpperCase()
    const adminId = typeof body.admin_id === 'string' && body.admin_id ? body.admin_id : null
    const ip = typeof body.ip === 'string' ? body.ip.slice(0, 64) : null
    const userAgent = typeof body.user_agent === 'string' ? body.user_agent.slice(0, 1000) : null
    const requestId = typeof body.request_id === 'string' ? body.request_id.slice(0, 200) : null
    if (!/^[0-9a-f-]{36}$/i.test(collectionId)) throw new Error('BALANCE_COLLECTION_ID_INVALID')
    if (!['SETTLED','PARTIAL','EXPIRED'].includes(reason)) throw new Error('BALANCE_COLLECTION_CANCEL_REASON_INVALID')

    const client = adminClient()
    const { data: collection, error: collectionError } = await client
      .from('appointment_balance_collections')
      .select('id,appointment_id,status')
      .eq('id', collectionId)
      .maybeSingle()
    if (collectionError || !collection) throw new Error('BALANCE_COLLECTION_NOT_FOUND')
    if (reason !== 'EXPIRED' && collection.status !== 'PENDING') {
      return jsonResponse({ cancelled: true, idempotent: true, status: collection.status })
    }
    if (reason === 'EXPIRED' && collection.status !== 'EXPIRED') {
      return jsonResponse({ cancelled: true, idempotent: true, status: collection.status })
    }

    const { data: transactions, error: txError } = await client
      .from('payment_transactions')
      .select('id,provider_payment_id,status')
      .eq('balance_collection_id', collectionId)
      .eq('provider', 'MERCADO_PAGO')
      .eq('transaction_type', 'CHARGE')
    if (txError) throw new Error('BALANCE_COLLECTION_PAYMENT_LOOKUP_FAILED')

    const live = (transactions ?? []).filter((tx) => tx.provider_payment_id && tx.status === 'PENDING')
    const failures: Array<Record<string, unknown>> = []
    const cancelledTransactionIds: string[] = []
    for (const tx of live) {
      const orderId = String(tx.provider_payment_id)
      try {
        const result = await cancelOrder(orderId, await stableKey(`balance-cancel:${collectionId}:${tx.id}:${reason}`))
        if (!result.ok) failures.push({ transaction_id: tx.id, provider_reference: orderId, http_status: result.status, code: result.code })
        else cancelledTransactionIds.push(String(tx.id))
      } catch (error) {
        failures.push({ transaction_id: tx.id, provider_reference: orderId, code: error instanceof Error ? error.message.split(':')[0] : 'PROVIDER_CANCEL_FAILED' })
      }
    }

    if (failures.length) {
      for (const failure of failures) {
        await client.from('balance_collection_divergences').insert({
          appointment_id: collection.appointment_id,
          balance_collection_id: collectionId,
          payment_transaction_id: failure.transaction_id ?? null,
          divergence_type: 'PROVIDER_CANCEL_FAILED',
          provider: 'MERCADO_PAGO',
          provider_reference: failure.provider_reference ?? null,
          details_json: { reason, http_status: failure.http_status ?? null, code: failure.code ?? 'PROVIDER_CANCEL_FAILED' },
        })
      }
      return jsonResponse({ cancelled: false, provider_cleanup_pending: true, failures: failures.length }, 409)
    }

    if (cancelledTransactionIds.length) {
      const { error: updateError } = await client
        .from('payment_transactions')
        .update({ status: 'EXPIRED', updated_at: new Date().toISOString() })
        .in('id', cancelledTransactionIds)
      if (updateError) throw new Error('BALANCE_PROVIDER_CANCEL_STATE_UPDATE_FAILED')
    }

    if (reason === 'EXPIRED') {
      await client.from('audit_logs').insert({
        entity_type: 'APPOINTMENT',
        entity_id: collection.appointment_id,
        action: 'BALANCE_PROVIDER_ORDERS_CANCELLED_AFTER_EXPIRY',
        after_json: { collection_id: collectionId, provider_orders_cancelled: cancelledTransactionIds.length },
        origin: 'SYSTEM',
      })
      return jsonResponse({ cancelled: true, provider_orders_cancelled: cancelledTransactionIds.length, state: 'EXPIRED' })
    }

    const { data: marked, error: markError } = await client.rpc('service_mark_balance_collection_cancelled', {
      p_collection_id: collectionId,
      p_reason: reason,
      p_admin_id: adminId,
      p_ip: ip,
      p_user_agent: userAgent,
      p_request_id: requestId,
    })
    if (markError) throw new Error(markError.message)
    return jsonResponse({ cancelled: true, provider_orders_cancelled: cancelledTransactionIds.length, state: marked })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'BALANCE_PROVIDER_CANCEL_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
