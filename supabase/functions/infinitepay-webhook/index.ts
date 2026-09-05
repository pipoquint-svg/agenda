import { adminClient } from '../_shared/supabase.ts'
import { loadInfinitePayRuntime } from '../_shared/infinitepay-runtime.ts'
import {
  brlToCents,
  checkInfinitePayPayment,
  infinitePayPaymentStorageSnapshot,
  parseInfinitePayWebhookSignal,
  type InfinitePayPaymentSignal,
  type InfinitePayTransport,
  verifyInfinitePayPayment,
} from '../_shared/infinitepay.ts'

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void }

type TransactionRow = {
  id: string
  appointment_id: string
  cash_amount: number | string
  status: string
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

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  })
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

async function processSignal(signal: InfinitePayPaymentSignal): Promise<void> {
  try {
    if (!isUuid(signal.orderNsu)) throw new Error('INFINITEPAY_ORDER_NSU_INVALID')
    const client = adminClient()
    const { data, error } = await client
      .from('payment_transactions')
      .select('id,appointment_id,cash_amount,status')
      .eq('id', signal.orderNsu)
      .eq('provider', 'INFINITEPAY')
      .eq('transaction_type', 'CHARGE')
      .maybeSingle()
    if (error) throw new Error('INFINITEPAY_WEBHOOK_PAYMENT_LOOKUP_FAILED')
    if (!data) {
      console.error('[OPERATION_ALERT] INFINITEPAY_WEBHOOK_UNKNOWN_ORDER', { order_nsu: signal.orderNsu })
      return
    }
    const tx = data as TransactionRow
    const runtime = await loadInfinitePayRuntime(client)
    const check = await checkInfinitePayPayment({
      handle: runtime.handle,
      orderNsu: signal.orderNsu,
      transactionNsu: signal.transactionNsu,
      slug: signal.slug,
    }, providerTransport)

    // The webhook itself is never payment proof. Only an authoritative paid=true
    // payment_check response with exact internal amount can mutate financial state.
    if (!check.success || !check.paid) {
      console.error('[OPERATION_ALERT] INFINITEPAY_WEBHOOK_NOT_CONFIRMED_BY_PAYMENT_CHECK', {
        transaction_id: tx.id,
        success: check.success,
        paid: check.paid,
      })
      return
    }

    const verified = verifyInfinitePayPayment({
      signal,
      check,
      expectedOrderNsu: tx.id,
      expectedAmountCents: brlToCents(tx.cash_amount),
    })
    const snapshot = infinitePayPaymentStorageSnapshot(verified)
    const { error: applyError } = await client.rpc('service_apply_infinitepay_payment_check', {
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
    if (applyError) throw new Error('INFINITEPAY_WEBHOOK_PAYMENT_APPLY_FAILED')
  } catch (cause) {
    console.error('[OPERATION_ALERT] INFINITEPAY_WEBHOOK_BACKGROUND_FAILURE', {
      code: cause instanceof Error ? cause.message.split(':')[0] : 'INFINITEPAY_WEBHOOK_ERROR',
      order_nsu: signal.orderNsu,
    })
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const body = await req.json()
    const signal = parseInfinitePayWebhookSignal(body)

    // InfinitePay documents the webhook as an approval notification and asks for a
    // prompt acknowledgement. No public webhook-signature scheme is documented, so
    // the payload is only a wake-up signal; payment_check performs the actual proof.
    EdgeRuntime.waitUntil(processSignal(signal))
    return json({ ok: true })
  } catch (cause) {
    const code = cause instanceof Error ? cause.message.split(':')[0] : 'INFINITEPAY_WEBHOOK_INVALID'
    return json({ error: { code } }, 400)
  }
})
