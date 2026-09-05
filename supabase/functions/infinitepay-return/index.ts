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

function html(title: string, message: string, status = 200): Response {
  const body = `<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${title}</title>
  <style>
    :root{font-family:system-ui,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;color-scheme:light}
    body{margin:0;min-height:100vh;display:grid;place-items:center;background:#faf8f5;color:#231f20}
    main{max-width:34rem;padding:2rem;text-align:center}
    h1{font-size:1.5rem;margin:0 0 .75rem}
    p{line-height:1.55;margin:0;color:#5a5254}
  </style>
</head>
<body><main><h1>${title}</h1><p>${message}</p></main></body>
</html>`
  return new Response(body, {
    status,
    headers: {
      'content-type': 'text/html; charset=utf-8',
      'cache-control': 'no-store, max-age=0',
      'content-security-policy': "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
      'referrer-policy': 'no-referrer',
      'x-content-type-options': 'nosniff',
      'x-frame-options': 'DENY',
    },
  })
}

function pending(): Response {
  return html(
    'Pagamento em processamento',
    'A confirmação ainda está sendo processada. Você pode fechar esta página; a reserva só será atualizada depois da confirmação segura do pagamento.',
  )
}

function confirmed(): Response {
  return html(
    'Pagamento confirmado',
    'O pagamento foi confirmado com segurança. Você pode fechar esta página.',
  )
}

function unavailable(status = 400): Response {
  return html(
    'Não foi possível confirmar agora',
    'Não usamos esta página como comprovante. A confirmação da reserva depende da validação direta com a InfinitePay.',
    status,
  )
}

Deno.serve(async (req) => {
  if (req.method !== 'GET') return unavailable(405)

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
    if (!data) return unavailable(404)
    const tx = data as TransactionRow

    const runtime = await loadInfinitePayRuntime(client)
    const check = await checkInfinitePayPayment({
      handle: runtime.handle,
      orderNsu: signal.orderNsu,
      transactionNsu: signal.transactionNsu,
      slug: signal.slug,
    }, providerTransport)

    // Redirect query data is never payment proof. A non-paid or not-yet-visible
    // payment_check result cannot mutate the appointment and renders as pending.
    if (!check.success || !check.paid) return pending()

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
    return confirmed()
  } catch (cause) {
    console.error('[OPERATION_ALERT] INFINITEPAY_RETURN_FAILURE', {
      code: cause instanceof Error ? cause.message.split(':')[0] : 'INFINITEPAY_RETURN_ERROR',
      order_nsu: orderNsu || null,
    })
    return unavailable(400)
  }
})
