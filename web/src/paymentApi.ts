import { functionsBaseUrl, publicApiKey } from './supabase'

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
  id: string
  status: string | null
  status_detail: string | null
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
  return decode(await callPaymentEndpoint(accessToken, { method: 'GET' }))
}

export async function createPixPayment(accessToken: string, kind: 'MINIMUM' | 'FULL', requestKey: string): Promise<PaymentResponse> {
  return decode(await callPaymentEndpoint(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ payment_kind: kind, method: 'PIX', request_key: requestKey }),
  }))
}

export async function createCardPayment(accessToken: string, kind: 'MINIMUM' | 'FULL', requestKey: string, card: {
  token: string
  payment_method_id: string
  installments: number
  issuer_id?: string | number | null
}): Promise<PaymentResponse> {
  return decode(await callPaymentEndpoint(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ payment_kind: kind, method: 'CARD', request_key: requestKey, card }),
  }))
}

export async function syncProviderPayment(accessToken: string, providerPaymentId: string): Promise<PaymentResponse> {
  return decode(await callPaymentEndpoint(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'SYNC', provider_payment_id: providerPaymentId }),
  }))
}
