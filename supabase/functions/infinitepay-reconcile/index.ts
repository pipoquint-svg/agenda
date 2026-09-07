import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { loadInfinitePayRuntime } from '../_shared/infinitepay-runtime.ts'
import {
  brlToCents,
  checkInfinitePayPayment,
  infinitePayPaymentStorageSnapshot,
  parseInfinitePayWebhookSignal,
  type InfinitePayTransport,
  verifyInfinitePayPayment,
} from '../_shared/infinitepay.ts'

type TransactionRow = {
  id: string
  appointment_id: string
  cash_amount: number | string
  status: string
  provider_payment_id: string | null
}

const providerTransport: InfinitePayTransport = async (input, init = {}) => {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 12_000)
  try {
    return await fetch(input, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    requireInternal(req)
    const body = await req.json()
    const rawSignal = body?.signal ?? body
    const signal = parseInfinitePayWebhookSignal(rawSignal)
    if (!isUuid(signal.orderNsu)) throw new Error('INFINITEPAY_ORDER_NSU_INVALID')

    const client = adminClient()
    const { data, error } = await client
      .from('payment_transactions')
      .select('id,appointment_id,cash_amount,status,provider_payment_id')
      .eq('id', signal.orderNsu)
      .eq('provider', 'INFINITEPAY')
      .eq('transaction_type', 'CHARGE')
      .maybeSingle()
    if (error) throw new Error('INFINITEPAY_RECONCILE_PAYMENT_LOOKUP_FAILED')
    if (!data) return errorResponse(new Error('INFINITEPAY_RECONCILE_UNKNOWN_ORDER'), 404)

    const tx = data as TransactionRow
    if (tx.status === 'APPROVED' && tx.provider_payment_id === signal.transactionNsu) {
      return jsonResponse({ ok: true, paid: true, idempotent_replay: true, transaction_id: tx.id, appointment_id: tx.appointment_id })
    }

    const runtime = await loadInfinitePayRuntime(client)
    const check = await checkInfinitePayPayment({
      handle: runtime.handle,
      orderNsu: signal.orderNsu,
      transactionNsu: signal.transactionNsu,
      slug: signal.slug,
    }, providerTransport)

    if (!check.success || !check.paid) {
      return errorResponse(new Error('INFINITEPAY_PAYMENT_NOT_CONFIRMED_YET'), 409)
    }

    const verified = verifyInfinitePayPayment({
      signal,
      check,
      expectedOrderNsu: tx.id,
      expectedAmountCents: brlToCents(tx.cash_amount),
    })
    const snapshot = infinitePayPaymentStorageSnapshot(verified)
    const { data: state, error: applyError } = await client.rpc('service_apply_infinitepay_payment_check', {
      p_transaction_id: tx.id,
      p_order_nsu: verified.orderNsu,
      p_transaction_nsu: verified.transactionNsu,
      p_slug: verified.slug,
      p_amount_cents: verified.amount,
      p_paid_amount_cents: verified.paidAmount,
      p_capture_method: verified.captureMethod,
      p_installments: verified.installments,
      p_receipt_url: verified.receiptUrl,
      p_payload_json: snapshot,
    })
    if (applyError) throw new Error('INFINITEPAY_RECONCILE_PAYMENT_APPLY_FAILED')

    return jsonResponse({ ok: true, paid: true, transaction_id: tx.id, appointment_id: tx.appointment_id, state })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'INFINITEPAY_RECONCILE_FAILED'
    const status = code === 'INTERNAL_AUTH_REQUIRED' ? 401
      : code === 'INFINITEPAY_ORDER_NSU_INVALID' ? 400
      : 500
    return errorResponse(error, status)
  }
})
