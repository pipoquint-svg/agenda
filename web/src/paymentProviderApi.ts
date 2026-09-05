import { functionsBaseUrl, publicApiKey } from './supabase'

export type PaymentProvider = 'MERCADO_PAGO' | 'INFINITEPAY'

type ProviderProbe = {
  payment_provider?: { provider?: string }
  error?: { code?: string }
}

export async function getPaymentProvider(accessToken: string): Promise<PaymentProvider> {
  const res = await fetch(`${functionsBaseUrl}/infinitepay-payment`, {
    method: 'GET',
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
      'x-appointment-token': accessToken,
    },
  })
  const payload = await res.json().catch(() => ({})) as ProviderProbe

  if (res.ok) {
    if (payload.payment_provider?.provider !== 'INFINITEPAY') {
      throw new Error('PAYMENT_PROVIDER_RESPONSE_INVALID')
    }
    return 'INFINITEPAY'
  }

  if (res.status === 409 && payload.error?.code === 'PAYMENT_PROVIDER_MISMATCH') {
    return 'MERCADO_PAGO'
  }

  throw new Error(payload.error?.code ?? `PAYMENT_PROVIDER_HTTP_${res.status}`)
}
