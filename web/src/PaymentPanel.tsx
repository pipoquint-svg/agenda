import { useEffect, useState } from 'react'
import { PaymentPanel as MercadoPagoPaymentPanel } from './MercadoPagoPaymentPanel'
import { InfinitePayPaymentPanel } from './InfinitePayPaymentPanel'
import { getPaymentProvider, type PaymentProvider } from './paymentProviderApi'

type PaymentPanelProps = {
  accessToken: string
  onConfirmed?: () => void
  mode?: 'BOOKING' | 'BALANCE'
}

function providerError(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'PAYMENT_PROVIDER_LOOKUP_FAILED'
  if (raw.includes('APPOINTMENT_TOKEN_EXPIRED')) return 'O link de pagamento expirou.'
  if (raw.includes('APPOINTMENT_TOKEN_INVALID')) return 'O link de pagamento não é válido.'
  if (raw.includes('RATE_LIMITED')) return 'Muitas tentativas em sequência. Aguarde alguns minutos.'
  return 'Não foi possível identificar com segurança o provedor deste pagamento.'
}

export function PaymentPanel(props: PaymentPanelProps) {
  const [provider, setProvider] = useState<PaymentProvider | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setProvider(null)
    setError(null)
    getPaymentProvider(props.accessToken)
      .then((next) => { if (!cancelled) setProvider(next) })
      .catch((cause) => { if (!cancelled) setError(providerError(cause)) })
    return () => { cancelled = true }
  }, [props.accessToken])

  if (error) {
    return <section className="payment-panel"><div className="form-alert error" role="alert">{error}</div></section>
  }
  if (!provider) {
    return <section className="payment-panel"><p>Preparando pagamento…</p></section>
  }
  if (provider === 'INFINITEPAY') return <InfinitePayPaymentPanel {...props} />
  return <MercadoPagoPaymentPanel {...props} />
}
