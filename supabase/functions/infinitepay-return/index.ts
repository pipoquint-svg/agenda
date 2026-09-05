import { adminClient } from '../_shared/supabase.ts'
import { loadInfinitePayRuntime } from '../_shared/infinitepay-runtime.ts'
import {
  brlToCents,
  checkInfinitePayPayment,
  infinitePayPaymentStorageSnapshot,
  parseInfinitePayRedirectSignal,
  type InfinitePayTransport,
  verifyInfinitePayPayment,
} from '../_shared/infinitepay.ts'

type TransactionRow = {
  id: string
  cash_amount: number | string
  status: string
}

type PaymentResultStatus = 'confirmado' | 'processando' | 'verificando'

const CUSTOMER_RESULT_URL = 'https://www.sabrinapierri.com.br/pagamento.html'

const providerTransport: InfinitePayTransport = async (input, init = {}) => {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 12_000)
  try {
    return await fetch(input, { ...init, signal: controller.signal })
  } finally {
    clearTimeout(timer)
  }
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
}

function resultRedirect(status: PaymentResultStatus): Response {
  const target = new URL(CUSTOMER_RESULT_URL)
  target.searchParams.set('status', status)

  return new Response(null, {
    status: 303,
    headers: {
      location: target.toString(),
      'cache-control': 'no-store, max-age=0',
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
    },
  })
}

Deno.serve(async (req) => {
  if (req.method !== 'GET') {
    return new Response(null, {
      status: 405,
      headers: { allow: 'GET', 'cache-control': 'no-store, max-age=0' },
    })
  }

  let orderNsu = ''
  try {
    const signal = parseInfinitePayRedirectSignal(new URL(req.url))
    orderNsu = signal.orderNsu
    if (!isUuid(signal.orderNsu)) throw new Error('INFINITEPAY_ORDER_NSU_INVALID')

    const client = adminClient()
    const { data, error } = await client
      .from('payment_transactions')
      .select('id,cash_amount,status')
      .eq('id', signal.orderNsu)
      .eq('provider', 'INFINITEPAY')
      .eq('transaction_type', 'CHARGE')
      .maybeSingle()
    if (error) throw new Error('INFINITEPAY_RETURN_PAYMENT_LOOKUP_FAILED')
    if (!data) return resultRedirect('verificando')
    const tx = data as TransactionRow

    const runtime = await loadInfinitePayRuntime(client)
    const check = await checkInfinitePayPayment({
      handle: runtime.handle,
      orderNsu: signal.orderNsu,
      transactionNsu: signal.transactionNsu,
      slug: signal.slug,
    }, providerTransport)

    // Redirect query data is never payment proof. A non-paid or not-yet-visible
    // payment_check result cannot mutate the appointment and redirects as pending.
    if (!check.success || !check.paid) return resultRedirect('processando')

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
    if (applyError) throw new Error('INFINITEPAY_RETURN_PAYMENT_APPLY_FAILED')
    return resultRedirect('confirmado')
  } catch (cause) {
    console.error('[OPERATION_ALERT] INFINITEPAY_RETURN_FAILURE', {
      code: cause instanceof Error ? cause.message.split(':')[0] : 'INFINITEPAY_RETURN_ERROR',
      order_nsu: orderNsu || null,
    })
    return resultRedirect('verificando')
  }
})
