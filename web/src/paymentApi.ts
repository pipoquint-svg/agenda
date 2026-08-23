import { functionsBaseUrl, publicApiKey } from './supabase'
import { trackAppointmentConfirmed, trackFunnelStep, trackPaymentInfo } from './tracking'

export type PublicPaymentContext = {
  appointment: {
    public_code: string
    appointment_status: string
    financial_status: string
    service_name: string
    hold_expires_at: string | null
  }
  financial: {
    commercial_value: number | string
    contract_settled: number | string
    contract_balance: number | string
    confirmation_percentage: number | string
    confirmation_target_amount: number | string
    minimum_due_contract_amount: number | string
    minimum_available: boolean
    full_available: boolean
    pix_discount_percent: number | string
  }
}

export type ProviderPayment = {
  // Orders API resource id (ORD...). Kept under provider.id to preserve the UI contract.
  id: string
  provider_transaction_id?: string | null
  provider_transaction_count?: number
  status: 'pending' | 'approved' | 'rejected' | 'expired' | null
  status_detail: string | null
  raw_status?: string | null
  transaction_amount: number | null
  payment_method_id: string | null
  payment_type_id: string | null
  external_reference: string | null
  date_approved: string | null
  point_of_interaction?: {
    transaction_data?: {
      qr_code?: string | null
      qr_code_base64?: string | null
      ticket_url?: string | null
    } | null
  } | null
  three_ds_info?: {
    external_resource_url?: string | null
  } | null
}

export type PaymentResponse = {
  transaction?: {
    id: string
    method: 'PIX' | 'CARD'
    payment_kind: 'MINIMUM' | 'FULL'
    contract_amount_settled: number | string
    payment_discount_amount: number | string
    cash_amount: number | string
  }
  provider: ProviderPayment
  state: {
    appointment_status?: string
    financial_status?: string
    transaction_status?: string
    payment_after_expiration?: boolean
  }
}

const paymentContextCache = new Map<string, PublicPaymentContext>()

function numeric(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function appointmentIdFromSession(): string | null {
  try {
    const raw = sessionStorage.getItem('bs_appointment_manage')
    if (!raw) return null
    const parsed = JSON.parse(raw) as { appointmentId?: string }
    return parsed.appointmentId?.trim() || null
  } catch {
    return null
  }
}

function intendedCashAmount(context: PublicPaymentContext | undefined, kind: 'MINIMUM' | 'FULL', method: 'PIX' | 'CARD'): number {
  if (!context) return 0
  const contractAmount = kind === 'FULL'
    ? numeric(context.financial.contract_balance)
    : numeric(context.financial.minimum_due_contract_amount)
  if (method !== 'PIX') return contractAmount
  return Math.max(contractAmount * (1 - numeric(context.financial.pix_discount_percent) / 100), 0)
}

function trackProviderState(accessToken: string, response: PaymentResponse, fallbackMethod?: 'PIX' | 'CARD'): void {
  const context = paymentContextCache.get(accessToken)
  const appointmentId = appointmentIdFromSession()
  const method = response.transaction?.method ?? fallbackMethod ?? 'PIX'
  const providerStatus = response.provider?.status?.toLowerCase() ?? ''
  if (providerStatus === 'rejected' || response.state?.transaction_status === 'REJECTED') {
    trackFunnelStep('payment_rejected', {
      payment_method: method,
      status_detail: response.provider?.status_detail ?? undefined,
      provider: 'MERCADO_PAGO',
    })
    return
  }

  if ((response.state?.appointment_status === 'CONFIRMED' || providerStatus === 'approved') && context && appointmentId) {
    trackAppointmentConfirmed({
      appointmentId,
      publicCode: context.appointment.public_code,
      serviceName: context.appointment.service_name,
      commercialValue: numeric(context.financial.commercial_value),
      paymentMethod: method,
      cashCollected: numeric(response.transaction?.cash_amount ?? response.provider?.transaction_amount),
    })
    return
  }

  if (providerStatus === 'pending') {
    trackFunnelStep('payment_pending', { payment_method: method, provider: 'MERCADO_PAGO' })
  }
}

async function callPaymentEndpoint(accessToken: string, init: RequestInit): Promise<Response> {
  return fetch(`${functionsBaseUrl}/mercado-pago-payment`, {
    ...init,
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
      'x-appointment-token': accessToken,
      ...(init.headers ?? {}),
    },
  })
}

async function decode<T>(res: Response): Promise<T> {
  const payload = await res.json().catch(() => ({})) as { error?: { code?: string } } & T
  if (!res.ok) throw new Error(payload.error?.code ?? `HTTP_${res.status}`)
  return payload
}

export async function getPaymentContext(accessToken: string): Promise<PublicPaymentContext> {
  const result = await decode<PublicPaymentContext>(await callPaymentEndpoint(accessToken, { method: 'GET' }))
  paymentContextCache.set(accessToken, result)
  return result
}

export async function createPixPayment(accessToken: string, kind: 'MINIMUM' | 'FULL', requestKey: string): Promise<PaymentResponse> {
  const context = paymentContextCache.get(accessToken)
  const appointmentId = appointmentIdFromSession()
  if (appointmentId) {
    trackPaymentInfo({ appointmentId, method: 'PIX', value: intendedCashAmount(context, kind, 'PIX'), paymentKind: kind, attemptId: requestKey })
  }
  const result = await decode<PaymentResponse>(await callPaymentEndpoint(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ payment_kind: kind, method: 'PIX', request_key: requestKey }),
  }))
  trackProviderState(accessToken, result, 'PIX')
  return result
}

export async function createCardPayment(accessToken: string, kind: 'MINIMUM' | 'FULL', requestKey: string, card: {
  token: string
  payment_method_id: string
  installments: number
  issuer_id?: string | number | null
}): Promise<PaymentResponse> {
  const context = paymentContextCache.get(accessToken)
  const appointmentId = appointmentIdFromSession()
  if (appointmentId) {
    trackPaymentInfo({ appointmentId, method: 'CARD', value: intendedCashAmount(context, kind, 'CARD'), paymentKind: kind, attemptId: requestKey })
  }
  const result = await decode<PaymentResponse>(await callPaymentEndpoint(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ payment_kind: kind, method: 'CARD', request_key: requestKey, card }),
  }))
  trackProviderState(accessToken, result, 'CARD')
  return result
}

export async function syncProviderPayment(accessToken: string, providerOrderId: string): Promise<PaymentResponse> {
  const result = await decode<PaymentResponse>(await callPaymentEndpoint(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'SYNC', provider_payment_id: providerOrderId }),
  }))
  trackProviderState(accessToken, result)
  return result
}
