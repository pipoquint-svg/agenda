import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'
import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'
import {
  assertMercadoPagoPaymentMatchesIntent,
  mercadoPagoPaymentStorageSnapshot,
  normalizeMercadoPagoPaymentStatus,
  payerIdentification,
  sanitizeMercadoPagoPayment,
  validateCardSubmission,
} from '../_shared/mercado-pago.ts'

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
  hold_expires_at: string | null
  commercial_value: number | string
  contract_settled: number | string
  contract_balance: number | string
  confirmation_percentage: number | string
  confirmation_target_amount: number | string
  minimum_due_contract_amount: number | string
  minimum_available: boolean
  full_available: boolean
  payer: { name: string; email: string; tax_id: string }
}

type Intent = {
  transaction_id: string
  appointment_id: string
  status: string
  payment_kind: string
  payment_percentage: number | string
  contract_amount_settled: number | string
  payment_discount_amount: number | string
  cash_amount: number | string
  method: 'PIX' | 'CARD'
  idempotent_replay: boolean
}

type ProviderResult = { status: number; data: Record<string, unknown> }

type TransactionRow = {
  id: string
  cash_amount: number | string
  method: 'PIX' | 'CARD'
  provider_payment_id: string | null
  status: string
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function appointmentToken(req: Request): string {
  const value = req.headers.get('x-appointment-token')?.trim() ?? ''
  if (value.length < 32) throw new Error('APPOINTMENT_TOKEN_INVALID')
  return value
}

function moneyString(value: number | string): string {
  const amount = Number(value)
  if (!Number.isFinite(amount) || amount <= 0) throw new Error('PAYMENT_AMOUNT_INVALID')
  return (Math.round(amount * 100) / 100).toFixed(2)
}

function providerCode(value: unknown): string | null {
  if (typeof value !== 'string') return null
  const normalized = value.trim()
  return /^[A-Za-z0-9_.-]{1,120}$/.test(normalized) ? normalized : null
}

function providerErrorSnapshot(status: number, raw: unknown): Record<string, unknown> {
  const row = raw && typeof raw === 'object' ? raw as Record<string, unknown> : {}
  const errors = Array.isArray(row.errors) ? row.errors : Array.isArray(row.cause) ? row.cause : []
  return {
    http_status: status,
    error: providerCode(row.error),
    status: typeof row.status === 'number' || typeof row.status === 'string' ? row.status : null,
    status_detail: providerCode(row.status_detail),
    errors: errors.slice(0, 5).map((item) => {
      const error = item && typeof item === 'object' ? item as Record<string, unknown> : {}
      return { code: providerCode(error.code) }
    }),
  }
}

function providerPaymentsConfigured(): boolean {
  try {
    mercadoPagoRuntime({
      environment: Deno.env.get('MERCADO_PAGO_ENV'),
      accessToken: Deno.env.get('MERCADO_PAGO_ACCESS_TOKEN'),
      allowRealCharges: Deno.env.get('ALLOW_REAL_CHARGES'),
      creatingCharge: true,
    })
    return true
  } catch (cause) {
    const code = cause instanceof Error ? cause.message.split(':')[0] : 'UNKNOWN'
    console.error('[OPERATION_ALERT] PAYMENT_PROVIDER_CONFIGURATION_UNAVAILABLE', { provider: 'MERCADO_PAGO', code })
    return false
  }
}

function isIdempotencyConflict(provider: ProviderResult): boolean {
  if (provider.status !== 409) return false
  const errors = Array.isArray(provider.data.errors) ? provider.data.errors : []
  return errors.some((item) => {
    const row = item && typeof item === 'object' ? item as Record<string, unknown> : {}
    return row.code === 'idempotency_key_already_used'
  })
}

function shouldUseThreeDS(): boolean {
  const mode = (Deno.env.get('MERCADO_PAGO_3DS_MODE') ?? 'never').trim().toLowerCase()
  if (mode === 'never' || mode === '') return false
  if (mode === 'on_fraud_risk') return true
  throw new Error('MERCADO_PAGO_3DS_MODE_INVALID')
}

async function mercadoPagoRequest(url: string, init: RequestInit, options: { creatingCharge?: boolean } = {}): Promise<ProviderResult> {
  const runtime = mercadoPagoRuntime({
    environment: Deno.env.get('MERCADO_PAGO_ENV'),
    accessToken: Deno.env.get('MERCADO_PAGO_ACCESS_TOKEN'),
    allowRealCharges: Deno.env.get('ALLOW_REAL_CHARGES'),
    creatingCharge: options.creatingCharge === true,
  })
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)
  try {
    const res = await fetch(url, {
      ...init,
      headers: { authorization: `Bearer ${runtime.accessToken}`, accept: 'application/json', ...(init.headers ?? {}) },
      signal: controller.signal,
    })
    const data = await res.json().catch(() => ({})) as Record<string, unknown>
    return { status: res.status, data }
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error('MERCADO_PAGO_PROVIDER_TIMEOUT')
    if (error instanceof Error && (error.message === 'MERCADO_PAGO_ENV_INVALID' || error.message === 'MERCADO_PAGO_SANDBOX_TOKEN_REQUIRED' || error.message === 'MERCADO_PAGO_PRODUCTION_TOKEN_REQUIRED' || error.message === 'REAL_CHARGES_DISABLED' || error.message.startsWith('MISSING_ENV:'))) throw error
    throw new Error('MERCADO_PAGO_PROVIDER_NETWORK_ERROR')
  } finally { clearTimeout(timer) }
}

async function mercadoPagoCreateOrder(body: Record<string, unknown>, idempotencyKey: string) {
  return mercadoPagoRequest('https://api.mercadopago.com/v1/orders', {
    method: 'POST', headers: { 'content-type': 'application/json', 'x-idempotency-key': idempotencyKey }, body: JSON.stringify(body),
  }, { creatingCharge: true })
}
async function mercadoPagoGetOrder(orderId: string) { return mercadoPagoRequest(`https://api.mercadopago.com/v1/orders/${encodeURIComponent(orderId)}`, { method: 'GET' }) }
async function loadContext(token: string): Promise<PaymentContext> { const client = adminClient(); const { data, error } = await client.rpc('service_get_public_payment_context', { p_access_token: token }); if (error) throw new Error(error.message); return data as PaymentContext }
function mismatchReason(error: unknown): string { return error instanceof Error && error.message.startsWith('MERCADO_PAGO_') ? error.message : 'MERCADO_PAGO_PAYMENT_METHOD_MISMATCH' }
async function loadTransaction(transactionId: string): Promise<TransactionRow | null> { const client = adminClient(); const { data, error } = await client.from('payment_transactions').select('id,cash_amount,method,provider_payment_id,status').eq('id', transactionId).maybeSingle(); if (error) throw new Error('PAYMENT_LOOKUP_FAILED'); return data as TransactionRow | null }

async function validateAndApplyProviderOrder(input: { transactionId: string; cashAmount: number | string; method: 'PIX' | 'CARD'; providerPaymentMethodId?: string | null; providerOrderId?: string | null; provider: ProviderResult; eventPrefix: string }): Promise<{ snapshot: ReturnType<typeof sanitizeMercadoPagoPayment>; state: unknown }> {
  if (input.provider.status < 200 || input.provider.status >= 300) throw new Error(`MERCADO_PAGO_LOOKUP_FAILED:${input.provider.status}`)
  const snapshot = sanitizeMercadoPagoPayment(input.provider.data)
  const storedSnapshot = mercadoPagoPaymentStorageSnapshot(snapshot)
  let validationError: unknown = null
  if (!snapshot.id) validationError = new Error('MERCADO_PAGO_PAYMENT_ID_MISSING')
  else if (input.providerOrderId && snapshot.id !== input.providerOrderId) validationError = new Error('MERCADO_PAGO_PAYMENT_ID_MISMATCH')
  else { try { assertMercadoPagoPaymentMatchesIntent(snapshot, { transactionId: input.transactionId, cashAmount: input.cashAmount, method: input.method, providerPaymentMethodId: input.providerPaymentMethodId }) } catch (cause) { validationError = cause } }
  const client = adminClient()
  if (validationError) {
    const reason = mismatchReason(validationError)
    console.error('Mercado Pago Order did not match internal intent', { transactionId: input.transactionId, providerOrderId: snapshot.id || input.providerOrderId || null, reason })
    const { error: quarantineError } = await client.rpc('service_quarantine_provider_payment_mismatch', { p_transaction_id: input.transactionId, p_provider_payment_id: snapshot.id || input.providerOrderId || null, p_reason: reason, p_payload_json: storedSnapshot })
    if (quarantineError) throw new Error('PAYMENT_MISMATCH_QUARANTINE_FAILED')
    throw new Error('MERCADO_PAGO_PAYMENT_VALIDATION_FAILED')
  }
  const normalized = normalizeMercadoPagoPaymentStatus(snapshot.status)
  const { data: applied, error: applyError } = await client.rpc('apply_provider_payment_status', { p_transaction_id: input.transactionId, p_provider_payment_id: snapshot.id, p_normalized_status: normalized, p_event_key: `${input.eventPrefix}:${snapshot.id}:${snapshot.raw_status ?? snapshot.status ?? 'unknown'}:${snapshot.status_detail ?? 'none'}`, p_payload_json: storedSnapshot, p_paid_at: snapshot.date_approved })
  if (applyError) throw new Error('PAYMENT_STATUS_APPLY_FAILED')
  return { snapshot, state: applied }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, { scope: 'PUBLIC_PAYMENT', limit: 60, windowSeconds: 600 })
    const token = appointmentToken(req)
    if (req.method === 'GET') {
      const context = await loadContext(token)
      const { data: settings, error: settingsError } = await client.from('operation_settings').select('pix_discount_percent').eq('id', 1).single()
      if (settingsError) throw new Error('PAYMENT_SETTINGS_LOAD_FAILED')
      const providerReady = providerPaymentsConfigured()
      return response({
        appointment: { public_code: context.public_code, appointment_status: context.appointment_status, financial_status: context.financial_status, service_name: context.service_name, hold_expires_at: context.hold_expires_at },
        financial: { commercial_value: context.commercial_value, contract_settled: context.contract_settled, contract_balance: context.contract_balance, confirmation_percentage: context.confirmation_percentage, confirmation_target_amount: context.confirmation_target_amount, minimum_due_contract_amount: context.minimum_due_contract_amount, minimum_available: context.minimum_available, full_available: context.full_available, pix_discount_percent: settings.pix_discount_percent },
        payment_methods: { pix_available: providerReady, card_backend_available: providerReady },
      })
    }
    if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    const input = await req.json()
    const context = await loadContext(token)
    if (input?.action === 'SYNC') {
      const providerOrderId = typeof input?.provider_payment_id === 'string' ? input.provider_payment_id.trim() : ''
      if (!/^[A-Za-z0-9_-]{1,100}$/.test(providerOrderId)) throw new Error('PROVIDER_PAYMENT_ID_INVALID')
      const { data: transaction, error: transactionError } = await client.from('payment_transactions').select('id,cash_amount,method').eq('appointment_id', context.appointment_id).eq('provider', 'MERCADO_PAGO').eq('transaction_type', 'CHARGE').eq('provider_payment_id', providerOrderId).maybeSingle()
      if (transactionError) throw new Error('PAYMENT_LOOKUP_FAILED')
      if (!transaction?.id) throw new Error('PAYMENT_NOT_FOUND')
      if (transaction.method !== 'PIX' && transaction.method !== 'CARD') throw new Error('PAYMENT_METHOD_INVALID')
      const provider = await mercadoPagoGetOrder(providerOrderId)
      const applied = await validateAndApplyProviderOrder({ transactionId: transaction.id, cashAmount: transaction.cash_amount, method: transaction.method, providerOrderId, provider, eventPrefix: 'poll-order' })
      return response({ provider: applied.snapshot, state: applied.state })
    }
    const paymentKind = input?.payment_kind === 'FULL' ? 'FULL' : input?.payment_kind === 'MINIMUM' ? 'MINIMUM' : ''
    const method = input?.method === 'PIX' ? 'PIX' : input?.method === 'CARD' ? 'CARD' : ''
    const requestKey = typeof input?.request_key === 'string' ? input.request_key.trim() : ''
    if (!paymentKind) throw new Error('INVALID_PAYMENT_KIND')
    if (!method) throw new Error('PUBLIC_PAYMENT_METHOD_NOT_ALLOWED')
    const { data: intentData, error: intentError } = await client.rpc('service_create_payment_intent_by_token', { p_access_token: token, p_payment_kind: paymentKind, p_method: method, p_request_key: requestKey })
    if (intentError) throw new Error(intentError.message)
    const intent = intentData as Intent
    let providerPaymentMethodId: string | null = null
    let paymentMethod: Record<string, unknown>
    const identification = payerIdentification(context.payer.tax_id)
    const amount = moneyString(intent.cash_amount)
    if (intent.idempotent_replay) {
      const existing = await loadTransaction(intent.transaction_id)
      if (existing?.provider_payment_id && (existing.method === 'PIX' || existing.method === 'CARD')) {
        const provider = await mercadoPagoGetOrder(existing.provider_payment_id)
        const applied = await validateAndApplyProviderOrder({ transactionId: intent.transaction_id, cashAmount: intent.cash_amount, method: existing.method, providerOrderId: existing.provider_payment_id, provider, eventPrefix: 'idempotent-replay' })
        return response({ transaction: { id: intent.transaction_id, method: existing.method, payment_kind: paymentKind, contract_amount_settled: intent.contract_amount_settled, payment_discount_amount: intent.payment_discount_amount, cash_amount: intent.cash_amount, idempotent_replay: true }, provider: applied.snapshot, state: applied.state }, normalizeMercadoPagoPaymentStatus(applied.snapshot.status) === 'APPROVED' ? 200 : 201)
      }
    }
    const providerBody: Record<string, unknown> = { type: 'online', processing_mode: 'automatic', capture_mode: 'automatic', external_reference: intent.transaction_id, total_amount: amount, payer: { email: context.payer.email, identification }, transactions: { payments: [] } }
    if (method === 'PIX') { providerPaymentMethodId = 'pix'; paymentMethod = { id: 'pix', type: 'bank_transfer' } }
    else {
      const card = validateCardSubmission(input?.card); providerPaymentMethodId = card.paymentMethodId; paymentMethod = { id: card.paymentMethodId, type: 'credit_card', token: card.token, installments: card.installments }
      if (shouldUseThreeDS()) providerBody.config = { online: { transaction_security: { validation: 'on_fraud_risk', liability_shift: 'required' } } }
    }
    providerBody.transactions = { payments: [{ amount, payment_method: paymentMethod }] }
    let provider: ProviderResult
    try { provider = await mercadoPagoCreateOrder(providerBody, intent.transaction_id) }
    catch (cause) {
      const causeCode = cause instanceof Error ? cause.message : 'MERCADO_PAGO_PROVIDER_ERROR'
      if (causeCode === 'MERCADO_PAGO_ENV_INVALID' || causeCode === 'MERCADO_PAGO_SANDBOX_TOKEN_REQUIRED' || causeCode === 'MERCADO_PAGO_PRODUCTION_TOKEN_REQUIRED' || causeCode === 'REAL_CHARGES_DISABLED' || causeCode.startsWith('MISSING_ENV:')) throw cause
      console.error('Mercado Pago create Order unavailable', { code: causeCode.split(':')[0] })
      return response({ error: { code: 'MERCADO_PAGO_TEMPORARY_FAILURE' }, transaction_id: intent.transaction_id }, 503)
    }
    if (isIdempotencyConflict(provider)) { const existing = await loadTransaction(intent.transaction_id); if (!existing?.provider_payment_id) return response({ error: { code: 'MERCADO_PAGO_TEMPORARY_FAILURE' }, transaction_id: intent.transaction_id }, 503); provider = await mercadoPagoGetOrder(existing.provider_payment_id) }
    if (provider.status >= 500) return response({ error: { code: 'MERCADO_PAGO_TEMPORARY_FAILURE' }, transaction_id: intent.transaction_id }, 503)
    if (provider.status < 200 || provider.status >= 300) {
      const snapshot = providerErrorSnapshot(provider.status, provider.data)
      await client.rpc('service_fail_payment_intent', { p_transaction_id: intent.transaction_id, p_reason: 'MERCADO_PAGO_CREATE_REJECTED', p_payload_json: snapshot })
      return response({ error: { code: 'MERCADO_PAGO_PAYMENT_REJECTED', provider: snapshot } }, 422)
    }
    const applied = await validateAndApplyProviderOrder({ transactionId: intent.transaction_id, cashAmount: intent.cash_amount, method, providerPaymentMethodId, provider, eventPrefix: 'create-order' })
    const normalized = normalizeMercadoPagoPaymentStatus(applied.snapshot.status)
    return response({ transaction: { id: intent.transaction_id, method, payment_kind: paymentKind, contract_amount_settled: intent.contract_amount_settled, payment_discount_amount: intent.payment_discount_amount, cash_amount: intent.cash_amount, idempotent_replay: intent.idempotent_replay }, provider: applied.snapshot, state: applied.state }, normalized === 'APPROVED' ? 200 : 201)
  } catch (error) {
    const code = error instanceof Error ? error.message : 'PAYMENT_REQUEST_FAILED'
    if (code.startsWith('MERCADO_PAGO_') && code.includes('MISMATCH')) console.error('Mercado Pago validation failed', code)
    const publicCode = code.match(/(APPOINTMENT_TOKEN_INVALID|APPOINTMENT_TOKEN_REVOKED|APPOINTMENT_TOKEN_EXPIRED|TOKEN_SCOPE_DENIED|APPOINTMENT_NOT_PAYABLE|PAYMENT_HOLD_EXPIRED|APPOINTMENT_ALREADY_PAID|CONFIRMATION_PAYMENT_ALREADY_SATISFIED|INVALID_PAYMENT_KIND|PUBLIC_PAYMENT_METHOD_NOT_ALLOWED|PAYMENT_REQUEST_KEY_INVALID|CARD_DATA_INVALID|CARD_TOKEN_INVALID|CARD_PAYMENT_METHOD_INVALID|CARD_INSTALLMENTS_INVALID|PAYER_TAX_ID_INVALID|PROVIDER_PAYMENT_ID_INVALID|PAYMENT_NOT_FOUND|RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|MERCADO_PAGO_3DS_MODE_INVALID|MERCADO_PAGO_ENV_INVALID|MERCADO_PAGO_SANDBOX_TOKEN_REQUIRED|MERCADO_PAGO_PRODUCTION_TOKEN_REQUIRED|REAL_CHARGES_DISABLED|MISSING_ENV)/)?.[1] ?? (code.startsWith('MERCADO_PAGO_') && (code.includes('MISMATCH') || code === 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED') ? 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED' : code.split(':')[0])
    const status = publicCode === 'RATE_LIMITED' ? 429 : publicCode === 'PAYMENT_HOLD_EXPIRED' ? 409 : publicCode === 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED' ? 502 : publicCode.startsWith('MISSING_ENV') || publicCode === 'RATE_LIMIT_BACKEND_FAILED' || publicCode === 'MERCADO_PAGO_ENV_INVALID' || publicCode === 'MERCADO_PAGO_SANDBOX_TOKEN_REQUIRED' || publicCode === 'MERCADO_PAGO_PRODUCTION_TOKEN_REQUIRED' || publicCode === 'REAL_CHARGES_DISABLED' ? 503 : publicCode.startsWith('APPOINTMENT_TOKEN') || publicCode === 'TOKEN_SCOPE_DENIED' ? 401 : 400
    return response({ error: { code: publicCode } }, status)
  }
})