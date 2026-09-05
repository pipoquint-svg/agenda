import { functionsBaseUrl, publicApiKey } from './supabase'

export type InfinitePayContext = {
  appointment: {
    public_code: string
    appointment_status: string
    financial_status: string
    service_name: string
    commercial_description: string
    hold_expires_at: string | null
  }
  financial: {
    commercial_value: number | string
    contract_settled: number | string
    contract_balance: number | string
    minimum_due_contract_amount: number | string
    minimum_available: boolean
    full_available: boolean
    payment_mode: 'MINIMUM_OR_FULL' | 'MINIMUM_ONLY' | 'FULL_ONLY'
    policy_allows_minimum: boolean
    policy_allows_full: boolean
  }
  payment_provider: {
    provider: 'INFINITEPAY'
    hosted_checkout: true
    method_selected_at_provider: true
    hosted_checkout_available: boolean
  }
}

export type InfinitePayCheckoutResponse = {
  transaction: {
    id: string
    cash_amount: number | string
    payment_kind: 'MINIMUM' | 'FULL'
  }
  checkout: {
    url: string
    reused: boolean
  }
}

type ErrorPayload = { error?: { code?: string } }

async function callInfinitePay(accessToken: string, init: RequestInit): Promise<Response> {
  return fetch(`${functionsBaseUrl}/infinitepay-payment`, {
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
  const payload = await res.json().catch(() => ({})) as ErrorPayload & T
  if (!res.ok) throw new Error(payload.error?.code ?? `HTTP_${res.status}`)
  return payload
}

export async function getInfinitePayContext(accessToken: string): Promise<InfinitePayContext> {
  return decode<InfinitePayContext>(await callInfinitePay(accessToken, { method: 'GET' }))
}

function hostedCheckoutUrl(value: string): string {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    throw new Error('INFINITEPAY_CHECKOUT_URL_INVALID')
  }
  if (url.protocol !== 'https:' || url.hostname !== 'checkout.infinitepay.com.br') {
    throw new Error('INFINITEPAY_CHECKOUT_URL_INVALID')
  }
  return url.toString()
}

export async function createInfinitePayCheckout(
  accessToken: string,
  paymentKind: 'MINIMUM' | 'FULL',
  requestKey: string,
): Promise<InfinitePayCheckoutResponse> {
  const result = await decode<InfinitePayCheckoutResponse>(await callInfinitePay(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'CREATE', payment_kind: paymentKind, request_key: requestKey }),
  }))
  result.checkout.url = hostedCheckoutUrl(result.checkout.url)
  return result
}

export async function syncInfinitePayReturn(accessToken: string, returnUrl: string): Promise<{ paid: boolean }> {
  return decode<{ paid: boolean }>(await callInfinitePay(accessToken, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ action: 'SYNC', return_url: returnUrl }),
  }))
}
