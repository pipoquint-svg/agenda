import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'
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

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function appointmentToken(req: Request): string {
  const value = req.headers.get('x-appointment-token')?.trim() ?? ''
  if (value.length < 32) throw new Error('APPOINTMENT_TOKEN_INVALID')
  return value
}

function providerErrorSnapshot(status: number, raw: unknown): Record<string, unknown> {
  const row = raw && typeof raw === 'object' ? raw as Record<string, unknown> : {}
  return {
    http_status: status,
    error: typeof row.error === 'string' ? row.error : null,
    message: typeof row.message === 'string' ? row.message.slice(0, 500) : null,
    status: typeof row.status === 'number' || typeof row.status === 'string' ? row.status : null,
    cause: Array.isArray(row.cause) ? row.cause.slice(0, 5).map((item) => {
      const cause = item && typeof item === 'object' ? item as Record<string, unknown> : {}
      return { code: cause.code ?? null, description: cause.description ?? null }
    }) : [],
  }
}

async function mercadoPagoRequest(url: string, init: RequestInit): Promise<{ status: number; data: Record<string, unknown> }> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)
  try {
    const res = await fetch(url, {
      ...init,
      headers: {
        authorization: `Bearer ${requiredEnv('MERCADO_PAGO_ACCESS_TOKEN')}`,
        accept: 'application/json',
        ...(init.headers ?? {}),
      },
      signal: controller.signal,
    })
    const data = await res.json().catch(() => ({})) as Record<string, unknown>
    return { status: res.status, data }
  } finally {
    clearTimeout(timer)
  }
}

async function mercadoPagoCreatePayment(body: Record<string, unknown>, idempotencyKey: string) {
  return mercadoPagoRequest('https://api.mercadopago.com/v1/payments', {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-idempotency-key': idempotencyKey },
    body: JSON.stringify(body),
  })
}

async function mercadoPagoGetPayment(paymentId: string) {
  return mercadoPagoRequest(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(paymentId)}`, { method: 'GET' })
}

async function loadContext(token: string): Promise<PaymentContext> {
  const client = adminClient()
  const { data, error } = await client.rpc('service_get_public_payment_context', { p_access_token: token })
  if (error) throw new Error(error.message)
  return data as PaymentContext
}

function mismatchReason(error: unknown): string {
  return error instanceof Error && error.message.startsWith('MERCADO_PAGO_')
    ? error.message
    : 'MERCADO_PAGO_PAYMENT_METHOD_MISMATCH'
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

    if (req.method === 'GET') {
      const context = await loadContext(token)
      const { data: settings, error: settingsError } = await client
        .from('operation_settings')
        .select('pix_discount_percent')
        .eq('id', 1)
        .single()
      if (settingsError) throw new Error(`PAYMENT_SETTINGS_LOAD_FAILED:${settingsError.message}`)

      return response({
        appointment: {
          public_code: context.public_code,
          appointment_status: context.appointment_status,
          financial_status: context.financial_status,
          service_name: context.service_name,
          hold_expires_at: context.hold_expires_at,
        },
        financial: {
          commercial_value: context.commercial_value,
          contract_settled: context.contract_settled,
          contract_balance: context.contract_balance,
          confirmation_percentage: context.confirmation_percentage,
          confirmation_target_amount: context.confirmation_target_amount,
          minimum_due_contract_amount: context.minimum_due_contract_amount,
          minimum_available: context.minimum_available,
          full_available: context.full_available,
          pix_discount_percent: settings.pix_discount_percent,
        },
      })
    }

    if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    const input = await req.json()
    const context = await loadContext(token)

    if (input?.action === 'SYNC') {
      const providerPaymentId = typeof input?.provider_payment_id === 'string' ? input.provider_payment_id.trim() : ''
      if (!/^[A-Za-z0-9_-]{1,100}$/.test(providerPaymentId)) throw new Error('PROVIDER_PAYMENT_ID_INVALID')

      const { data: transaction, error: transactionError } = await client
        .from('payment_transactions')
        .select('id,cash_amount,method')
        .eq('appointment_id', context.appointment_id)
        .eq('provider', 'MERCADO_PAGO')
        .eq('transaction_type', 'CHARGE')
        .eq('provider_payment_id', providerPaymentId)
        .maybeSingle()
      if (transactionError) throw new Error(`PAYMENT_LOOKUP_FAILED:${transactionError.message}`)
      if (!transaction?.id) throw new Error('PAYMENT_NOT_FOUND')
      if (transaction.method !== 'PIX' && transaction.method !== 'CARD') throw new Error('PAYMENT_METHOD_INVALID')

      const provider = await mercadoPagoGetPayment(providerPaymentId)
      if (provider.status < 200 || provider.status >= 300) throw new Error(`MERCADO_PAGO_LOOKUP_FAILED:${provider.status}`)
      const snapshot = sanitizeMercadoPagoPayment(provider.data)
      const storedSnapshot = mercadoPagoPaymentStorageSnapshot(snapshot)

      let validationError: unknown = null
      if (!snapshot.id) validationError = new Error('MERCADO_PAGO_PAYMENT_ID_MISSING')
      else if (snapshot.id !== providerPaymentId) validationError = new Error('MERCADO_PAGO_PAYMENT_ID_MISMATCH')
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
        const reason = mismatchReason(validationError)
        console.error('Mercado Pago sync did not match internal intent', { transactionId: transaction.id, providerPaymentId, reason })
        const { error: quarantineError } = await client.rpc('service_quarantine_provider_payment_mismatch', {
          p_transaction_id: transaction.id,
          p_provider_payment_id: snapshot.id || providerPaymentId,
          p_reason: reason,
          p_payload_json: storedSnapshot,
        })
        if (quarantineError) {
          console.error('Failed to quarantine Mercado Pago sync mismatch', quarantineError.message)
          return response({ error: { code: 'MERCADO_PAGO_TEMPORARY_FAILURE' } }, 503)
        }
        return response({ error: { code: 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED' } }, 502)
      }

      const normalized = normalizeMercadoPagoPaymentStatus(snapshot.status)
      const { data: applied, error: applyError } = await client.rpc('apply_provider_payment_status', {
        p_transaction_id: transaction.id,
        p_provider_payment_id: snapshot.id,
        p_normalized_status: normalized,
        p_event_key: `poll:${snapshot.id}:${snapshot.status ?? 'unknown'}:${snapshot.status_detail ?? 'none'}`,
        p_payload_json: storedSnapshot,
        p_paid_at: snapshot.date_approved,
      })
      if (applyError) throw new Error(`PAYMENT_STATUS_APPLY_FAILED:${applyError.message}`)
      return response({ provider: snapshot, state: applied })
    }

    const paymentKind = input?.payment_kind === 'FULL' ? 'FULL' : input?.payment_kind === 'MINIMUM' ? 'MINIMUM' : ''
    const method = input?.method === 'PIX' ? 'PIX' : input?.method === 'CARD' ? 'CARD' : ''
    const requestKey = typeof input?.request_key === 'string' ? input.request_key.trim() : ''
    if (!paymentKind) throw new Error('INVALID_PAYMENT_KIND')
    if (!method) throw new Error('PUBLIC_PAYMENT_METHOD_NOT_ALLOWED')

    const { data: intentData, error: intentError } = await client.rpc('service_create_payment_intent_by_token', {
      p_access_token: token,
      p_payment_kind: paymentKind,
      p_method: method,
      p_request_key: requestKey,
    })
    if (intentError) throw new Error(intentError.message)
    const intent = intentData as Intent

    const identification = payerIdentification(context.payer.tax_id)
    const cashAmount = Number(intent.cash_amount)
    if (!Number.isFinite(cashAmount) || cashAmount <= 0) throw new Error('PAYMENT_AMOUNT_INVALID')

    const providerBody: Record<string, unknown> = {
      transaction_amount: cashAmount,
      description: `BlackSheep Agenda - ${context.service_name}`.slice(0, 200),
      external_reference: intent.transaction_id,
      payer: { email: context.payer.email, identification },
    }

    const notificationUrl = Deno.env.get('MERCADO_PAGO_WEBHOOK_URL')?.trim()
    if (notificationUrl) providerBody.notification_url = notificationUrl

    let providerPaymentMethodId: string | null = null
    if (method === 'PIX') {
      providerPaymentMethodId = 'pix'
      providerBody.payment_method_id = 'pix'
    } else {
      const card = validateCardSubmission(input?.card)
      providerPaymentMethodId = card.paymentMethodId
      providerBody.token = card.token
      providerBody.payment_method_id = card.paymentMethodId
      providerBody.installments = card.installments
      providerBody.three_d_secure_mode = 'optional'
      providerBody.capture = true
      providerBody.binary_mode = false
      if (card.issuerId) providerBody.issuer_id = card.issuerId
    }

    let provider: { status: number; data: Record<string, unknown> }
    try {
      provider = await mercadoPagoCreatePayment(providerBody, intent.transaction_id)
    } catch (cause) {
      console.error('Mercado Pago create payment unavailable', cause)
      return response({ error: { code: 'MERCADO_PAGO_TEMPORARY_FAILURE' }, transaction_id: intent.transaction_id }, 503)
    }

    if (provider.status >= 500) {
      return response({ error: { code: 'MERCADO_PAGO_TEMPORARY_FAILURE' }, transaction_id: intent.transaction_id }, 503)
    }

    if (provider.status < 200 || provider.status >= 300) {
      const snapshot = providerErrorSnapshot(provider.status, provider.data)
      await client.rpc('service_fail_payment_intent', {
        p_transaction_id: intent.transaction_id,
        p_reason: 'MERCADO_PAGO_CREATE_REJECTED',
        p_payload_json: snapshot,
      })
      return response({ error: { code: 'MERCADO_PAGO_PAYMENT_REJECTED', provider: snapshot } }, 422)
    }

    const snapshot = sanitizeMercadoPagoPayment(provider.data)
    const storedSnapshot = mercadoPagoPaymentStorageSnapshot(snapshot)
    try {
      assertMercadoPagoPaymentMatchesIntent(snapshot, {
        transactionId: intent.transaction_id,
        cashAmount: intent.cash_amount,
        method,
        providerPaymentMethodId,
      })
    } catch (validationError) {
      const reason = mismatchReason(validationError)
      console.error('Mercado Pago payment did not match internal intent', { transactionId: intent.transaction_id, providerPaymentId: snapshot.id || null, reason })
      const { error: quarantineError } = await client.rpc('service_quarantine_provider_payment_mismatch', {
        p_transaction_id: intent.transaction_id,
        p_provider_payment_id: snapshot.id || null,
        p_reason: reason,
        p_payload_json: storedSnapshot,
      })
      if (quarantineError) {
        console.error('Failed to quarantine Mercado Pago create mismatch', quarantineError.message)
        return response({ error: { code: 'MERCADO_PAGO_TEMPORARY_FAILURE' }, transaction_id: intent.transaction_id }, 503)
      }
      return response({ error: { code: 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED' } }, 502)
    }
    const normalized = normalizeMercadoPagoPaymentStatus(snapshot.status)

    const { data: applied, error: applyError } = await client.rpc('apply_provider_payment_status', {
      p_transaction_id: intent.transaction_id,
      p_provider_payment_id: snapshot.id,
      p_normalized_status: normalized,
      p_event_key: `create:${snapshot.id}:${snapshot.status ?? 'unknown'}:${snapshot.status_detail ?? 'none'}`,
      p_payload_json: storedSnapshot,
      p_paid_at: snapshot.date_approved,
    })
    if (applyError) throw new Error(`PAYMENT_STATUS_APPLY_FAILED:${applyError.message}`)

    return response({
      transaction: {
        id: intent.transaction_id,
        method,
        payment_kind: paymentKind,
        contract_amount_settled: intent.contract_amount_settled,
        payment_discount_amount: intent.payment_discount_amount,
        cash_amount: intent.cash_amount,
      },
      provider: snapshot,
      state: applied,
    }, normalized === 'APPROVED' ? 200 : 201)
  } catch (error) {
    const code = error instanceof Error ? error.message : 'PAYMENT_REQUEST_FAILED'
    if (code.startsWith('MERCADO_PAGO_') && code.includes('MISMATCH')) console.error('Mercado Pago validation failed', code)
    const publicCode = code.match(/(APPOINTMENT_TOKEN_INVALID|APPOINTMENT_TOKEN_REVOKED|APPOINTMENT_TOKEN_EXPIRED|TOKEN_SCOPE_DENIED|APPOINTMENT_NOT_PAYABLE|PAYMENT_HOLD_EXPIRED|APPOINTMENT_ALREADY_PAID|CONFIRMATION_PAYMENT_ALREADY_SATISFIED|INVALID_PAYMENT_KIND|PUBLIC_PAYMENT_METHOD_NOT_ALLOWED|PAYMENT_REQUEST_KEY_INVALID|CARD_DATA_INVALID|CARD_TOKEN_INVALID|CARD_PAYMENT_METHOD_INVALID|CARD_INSTALLMENTS_INVALID|PAYER_TAX_ID_INVALID|PROVIDER_PAYMENT_ID_INVALID|PAYMENT_NOT_FOUND|RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|MISSING_ENV)/)?.[1] ?? (code.startsWith('MERCADO_PAGO_') && code.includes('MISMATCH') ? 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED' : code.split(':')[0])
    const status = publicCode === 'RATE_LIMITED' ? 429
      : publicCode === 'PAYMENT_HOLD_EXPIRED' ? 409
      : publicCode === 'MERCADO_PAGO_PAYMENT_VALIDATION_FAILED' ? 502
      : publicCode.startsWith('MISSING_ENV') || publicCode === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : publicCode.startsWith('APPOINTMENT_TOKEN') || publicCode === 'TOKEN_SCOPE_DENIED' ? 401
      : 400
    return response({ error: { code: publicCode } }, status)
  }
})
