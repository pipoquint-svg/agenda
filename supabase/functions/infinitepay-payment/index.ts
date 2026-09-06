import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'
import { loadInfinitePayRuntime } from '../_shared/infinitepay-runtime.ts'
import {
  brlToCents,
  checkInfinitePayPayment,
  createInfinitePayCheckoutLink,
  infinitePayPaymentStorageSnapshot,
  parseInfinitePayRedirectSignal,
  type InfinitePayPaymentSignal,
  type InfinitePayTransport,
  verifyInfinitePayPayment,
} from '../_shared/infinitepay.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-appointment-token',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

type PaymentContext = {
  appointment_id: string
  public_code: string
  appointment_status: string
  financial_status: string
  service_name: string
  commercial_description: string
  provider_commercial_description: string
  hold_expires_at: string | null
  commercial_value: number | string
  contract_settled: number | string
  contract_balance: number | string
  minimum_due_contract_amount: number | string
  minimum_available: boolean
  full_available: boolean
  payment_mode: 'MINIMUM_OR_FULL' | 'MINIMUM_ONLY' | 'FULL_ONLY'
  policy_allows_minimum: boolean
  policy_allows_full: boolean
  payer: { name: string; email: string; tax_id: string }
}

type ClaimedCheckout = {
  transaction_id: string
  appointment_id: string
  status: string
  payment_kind: string
  contract_amount_settled: number | string
  payment_discount_amount: number | string
  cash_amount: number | string
  method: string
  provider: string
  idempotent_replay: boolean
  link_creation_claimed: boolean
  link_state: string
  checkout_url: string | null
}

type TransactionRow = {
  id: string
  appointment_id: string
  cash_amount: number | string
  status: string
  provider_payment_id: string | null
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function appointmentToken(req: Request): string {
  const token = req.headers.get('x-appointment-token')?.trim() ?? ''
  if (token.length < 32) throw new Error('APPOINTMENT_TOKEN_INVALID')
  return token
}

function safeDescription(value: string, fallback: string): string {
  const description = (value || fallback || 'Reserva').trim().replace(/\s+/g, ' ')
  if (!description || description.length > 160) throw new Error('INFINITEPAY_DESCRIPTION_INVALID')
  return description
}

function providerWebhookUrl(): string {
  const base = (Deno.env.get('SUPABASE_URL') ?? '').trim().replace(/\/$/, '')
  if (!base) throw new Error('MISSING_ENV:SUPABASE_URL')
  const url = new URL(`${base}/functions/v1/infinitepay-webhook`)
  if (url.protocol !== 'https:') throw new Error('INFINITEPAY_WEBHOOK_URL_INVALID')
  return url.toString()
}

function isUuid(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)
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

async function loadContext(token: string): Promise<PaymentContext> {
  const client = adminClient()
  const { data, error } = await client.rpc('service_get_public_payment_context', { p_access_token: token })
  if (error) throw new Error(error.message)
  return data as PaymentContext
}

async function assertInfinitePayAppointment(appointmentId: string): Promise<void> {
  const client = adminClient()
  const { data, error } = await client
    .from('appointments')
    .select('payment_provider_snapshot')
    .eq('id', appointmentId)
    .maybeSingle()
  if (error || !data) throw new Error('APPOINTMENT_NOT_FOUND')
  if (data.payment_provider_snapshot !== 'INFINITEPAY') throw new Error('PAYMENT_PROVIDER_MISMATCH')
}

async function loadTransaction(signal: InfinitePayPaymentSignal, appointmentId: string): Promise<TransactionRow> {
  if (!isUuid(signal.orderNsu)) throw new Error('INFINITEPAY_ORDER_NSU_INVALID')
  const client = adminClient()
  const { data, error } = await client
    .from('payment_transactions')
    .select('id,appointment_id,cash_amount,status,provider_payment_id')
    .eq('id', signal.orderNsu)
    .eq('appointment_id', appointmentId)
    .eq('provider', 'INFINITEPAY')
    .eq('transaction_type', 'CHARGE')
    .maybeSingle()
  if (error) throw new Error('PAYMENT_LOOKUP_FAILED')
  if (!data) throw new Error('PAYMENT_NOT_FOUND')
  return data as TransactionRow
}

async function verifyAndApply(
  signal: InfinitePayPaymentSignal,
  tx: TransactionRow,
  handle: string,
): Promise<{ paid: boolean; state?: unknown; provider?: Record<string, unknown> }> {
  const check = await checkInfinitePayPayment({
    handle,
    orderNsu: signal.orderNsu,
    transactionNsu: signal.transactionNsu,
    slug: signal.slug,
  }, providerTransport)

  if (!check.success || !check.paid) {
    return { paid: false, provider: { success: check.success, paid: check.paid } }
  }

  const verified = verifyInfinitePayPayment({
    signal,
    check,
    expectedOrderNsu: tx.id,
    expectedAmountCents: brlToCents(tx.cash_amount),
  })
  const snapshot = infinitePayPaymentStorageSnapshot(verified)
  const client = adminClient()
  const { data: state, error } = await client.rpc('service_apply_infinitepay_payment_check', {
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
  if (error) throw new Error('INFINITEPAY_PAYMENT_APPLY_FAILED')
  return { paid: true, state, provider: snapshot }
}

async function providerReady(client: ReturnType<typeof adminClient>): Promise<boolean> {
  try {
    await loadInfinitePayRuntime(client, { creatingLink: true })
    providerWebhookUrl()
    return true
  } catch {
    return false
  }
}

function providerFailureSnapshot(error: unknown): Record<string, unknown> {
  const message = error instanceof Error ? error.message : 'INFINITEPAY_PROVIDER_ERROR'
  const status = Number((error as { providerStatus?: unknown })?.providerStatus)
  return {
    code: message.split(':')[0],
    http_status: Number.isInteger(status) ? status : null,
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'PUBLIC_PAYMENT',
      limit: 60,
      windowSeconds: 600,
    })

    const token = appointmentToken(req)
    const context = await loadContext(token)
    await assertInfinitePayAppointment(context.appointment_id)

    if (req.method === 'GET') {
      return response({
        appointment: {
          public_code: context.public_code,
          appointment_status: context.appointment_status,
          financial_status: context.financial_status,
          service_name: context.service_name,
          commercial_description: context.commercial_description,
          hold_expires_at: context.hold_expires_at,
        },
        financial: {
          commercial_value: context.commercial_value,
          contract_settled: context.contract_settled,
          contract_balance: context.contract_balance,
          minimum_due_contract_amount: context.minimum_due_contract_amount,
          minimum_available: context.minimum_available,
          full_available: context.full_available,
          payment_mode: context.payment_mode,
          policy_allows_minimum: context.policy_allows_minimum,
          policy_allows_full: context.policy_allows_full,
        },
        payment_provider: {
          provider: 'INFINITEPAY',
          hosted_checkout: true,
          method_selected_at_provider: true,
          hosted_checkout_available: await providerReady(client),
        },
      })
    }

    if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    const input = await req.json().catch(() => ({})) as Record<string, unknown>

    if (input.action === 'SYNC') {
      const returnUrl = typeof input.return_url === 'string' ? input.return_url.trim() : ''
      if (!returnUrl) throw new Error('INFINITEPAY_RETURN_URL_REQUIRED')
      let signal: InfinitePayPaymentSignal
      try {
        signal = parseInfinitePayRedirectSignal(new URL(returnUrl))
      } catch (cause) {
        if (cause instanceof Error) throw cause
        throw new Error('INFINITEPAY_RETURN_URL_INVALID')
      }
      const tx = await loadTransaction(signal, context.appointment_id)
      const runtime = await loadInfinitePayRuntime(client)
      const applied = await verifyAndApply(signal, tx, runtime.handle)
      return response(applied, applied.paid ? 200 : 202)
    }

    if (input.action !== 'CREATE') throw new Error('INFINITEPAY_ACTION_INVALID')
    const paymentKind = input.payment_kind === 'FULL' ? 'FULL' : input.payment_kind === 'MINIMUM' ? 'MINIMUM' : ''
    const requestKey = typeof input.request_key === 'string' ? input.request_key.trim() : ''
    if (!paymentKind) throw new Error('INVALID_PAYMENT_KIND')
    if (paymentKind === 'FULL' && !context.policy_allows_full) throw new Error('PAYMENT_POLICY_FULL_NOT_ALLOWED')
    if (paymentKind === 'MINIMUM' && !context.policy_allows_minimum) throw new Error('PAYMENT_POLICY_MINIMUM_NOT_ALLOWED')

    // The private runtime row must explicitly enable live link creation. The default
    // and deployment state remain fail-closed until a controlled operational window.
    const runtime = await loadInfinitePayRuntime(client, { creatingLink: true })
    const webhookUrl = providerWebhookUrl()

    const { data: claimData, error: claimError } = await client.rpc('service_claim_infinitepay_checkout_by_token', {
      p_access_token: token,
      p_payment_kind: paymentKind,
      p_request_key: requestKey,
    })
    if (claimError) throw new Error(claimError.message)
    const claim = claimData as ClaimedCheckout

    if (!claim.link_creation_claimed) {
      if (claim.link_state === 'READY' && claim.checkout_url) {
        return response({
          transaction: { id: claim.transaction_id, cash_amount: claim.cash_amount, payment_kind: claim.payment_kind },
          checkout: { url: claim.checkout_url, reused: true },
        })
      }
      return response({
        error: { code: 'INFINITEPAY_LINK_CREATION_UNCERTAIN' },
        transaction_id: claim.transaction_id,
      }, 409)
    }

    try {
      const checkout = await createInfinitePayCheckoutLink({
        handle: runtime.handle,
        orderNsu: claim.transaction_id,
        items: [{
          quantity: 1,
          price: brlToCents(claim.cash_amount),
          description: safeDescription(context.provider_commercial_description, context.service_name),
        }],
        redirectUrl: runtime.redirectUrl,
        webhookUrl,
        customer: { name: context.payer.name, email: context.payer.email },
      }, providerTransport)

      const { data: stored, error: storeError } = await client.rpc('service_record_infinitepay_checkout_link_result', {
        p_transaction_id: claim.transaction_id,
        p_outcome: 'READY',
        p_checkout_url: checkout.url,
        p_payload_json: checkout.raw,
      })
      if (storeError) throw new Error('INFINITEPAY_LINK_STORE_FAILED')
      return response({
        transaction: { id: claim.transaction_id, cash_amount: claim.cash_amount, payment_kind: claim.payment_kind },
        checkout: { url: checkout.url, reused: false },
        state: stored,
      }, 201)
    } catch (cause) {
      const snapshot = providerFailureSnapshot(cause)
      const code = String(snapshot.code ?? 'INFINITEPAY_PROVIDER_ERROR')
      if (/^INFINITEPAY_PROVIDER_HTTP_4\d\d$/.test(code)) {
        await client.rpc('service_record_infinitepay_checkout_link_result', {
          p_transaction_id: claim.transaction_id,
          p_outcome: 'REJECTED',
          p_checkout_url: null,
          p_payload_json: snapshot,
        })
        return response({ error: { code: 'INFINITEPAY_LINK_REJECTED' }, transaction_id: claim.transaction_id }, 422)
      }

      // Network/timeout/5xx/invalid 2xx response is ambiguous: the provider might
      // already have created the link. Keep CREATE_STARTED and never auto-create again.
      console.error('[OPERATION_ALERT] INFINITEPAY_LINK_CREATION_UNCERTAIN', {
        transaction_id: claim.transaction_id,
        code,
      })
      return response({ error: { code: 'INFINITEPAY_LINK_CREATION_UNCERTAIN' }, transaction_id: claim.transaction_id }, 503)
    }
  } catch (cause) {
    const code = cause instanceof Error ? cause.message.split(':')[0] : 'INFINITEPAY_PAYMENT_ERROR'
    const status = code === 'PAYMENT_PROVIDER_MISMATCH' ? 409
      : code === 'INFINITEPAY_LIVE_LINKS_DISABLED' || code.startsWith('MISSING_ENV') || code.startsWith('INFINITEPAY_RUNTIME_CONFIG_') ? 503
      : code === 'PAYMENT_NOT_FOUND' ? 404
      : 400
    return response({ error: { code } }, status)
  }
})
