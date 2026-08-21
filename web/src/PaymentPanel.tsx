import { useEffect, useMemo, useState } from 'react'
import { CardPayment, initMercadoPago } from '@mercadopago/sdk-react'
import {
  createCardPayment,
  createPixPayment,
  getPaymentContext,
  syncProviderPayment,
  type PaymentResponse,
  type PublicPaymentContext,
} from './paymentApi'

const publicKey = import.meta.env.VITE_MERCADO_PAGO_PUBLIC_KEY?.trim() ?? ''
if (publicKey) initMercadoPago(publicKey, { locale: 'pt-BR' })

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

function numeric(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function paymentError(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'PAYMENT_FAILED'
  const map: Array<[string, string]> = [
    ['PAYMENT_HOLD_EXPIRED', 'O prazo para pagamento terminou. O horário foi liberado.'],
    ['CONFIRMATION_PAYMENT_ALREADY_SATISFIED', 'A entrada mínima já foi atingida. Atualize a página para ver o saldo.'],
    ['MERCADO_PAGO_PAYMENT_REJECTED', 'O Mercado Pago recusou esta tentativa. Revise o meio de pagamento e tente novamente.'],
    ['MERCADO_PAGO_TEMPORARY_FAILURE', 'O Mercado Pago está temporariamente indisponível. Tente novamente sem refazer a reserva.'],
    ['APPOINTMENT_TOKEN_INVALID', 'O link de pagamento não é válido.'],
    ['APPOINTMENT_TOKEN_EXPIRED', 'O link de pagamento expirou.'],
    ['RATE_LIMITED', 'Muitas tentativas em sequência. Aguarde alguns minutos.'],
  ]
  return map.find(([code]) => raw.includes(code))?.[1] ?? 'Não foi possível processar o pagamento. Tente novamente.'
}

function randomRequestKey(): string {
  return crypto.randomUUID()
}

export function PaymentPanel({ accessToken, onConfirmed }: {
  accessToken: string
  onConfirmed?: () => void
}) {
  const [context, setContext] = useState<PublicPaymentContext | null>(null)
  const [kind, setKind] = useState<'MINIMUM' | 'FULL'>('MINIMUM')
  const [method, setMethod] = useState<'PIX' | 'CARD'>('PIX')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [payment, setPayment] = useState<PaymentResponse | null>(null)
  const [confirmed, setConfirmed] = useState(false)

  async function reloadContext() {
    const next = await getPaymentContext(accessToken)
    setContext(next)
    if (!next.financial.minimum_available) setKind('FULL')
    if (next.appointment.appointment_status === 'CONFIRMED' || numeric(next.financial.contract_balance) <= 0) {
      setConfirmed(true)
      onConfirmed?.()
    }
  }

  useEffect(() => {
    reloadContext().catch((cause) => setError(paymentError(cause)))
  }, [accessToken])

  const providerId = payment?.provider?.id || null
  const providerPending = payment?.provider?.status != null && ['pending', 'in_process', 'authorized', 'in_mediation'].includes(payment.provider.status)

  useEffect(() => {
    if (!providerId || !providerPending || confirmed) return
    let cancelled = false
    const timer = window.setInterval(async () => {
      try {
        const synced = await syncProviderPayment(accessToken, providerId)
        if (cancelled) return
        setPayment((current) => ({ ...current, ...synced }))
        if (synced.state?.appointment_status === 'CONFIRMED' || synced.provider?.status === 'approved') {
          setConfirmed(true)
          await reloadContext()
          onConfirmed?.()
        }
      } catch {
        // Webhook remains authoritative; transient poll failures must not interrupt PIX instructions.
      }
    }, 4500)
    return () => {
      cancelled = true
      window.clearInterval(timer)
    }
  }, [accessToken, providerId, providerPending, confirmed])

  const contractAmount = useMemo(() => {
    if (!context) return 0
    return kind === 'FULL'
      ? numeric(context.financial.contract_balance)
      : numeric(context.financial.minimum_due_contract_amount)
  }, [context, kind])

  const pixDiscount = context ? numeric(context.financial.pix_discount_percent) : 0
  const pixAmount = Math.max(contractAmount * (1 - pixDiscount / 100), 0)
  const cardAmount = contractAmount

  async function payPix() {
    setBusy(true)
    setError(null)
    setPayment(null)
    try {
      const next = await createPixPayment(accessToken, kind, randomRequestKey())
      setPayment(next)
      if (next.state?.appointment_status === 'CONFIRMED' || next.provider?.status === 'approved') {
        setConfirmed(true)
        await reloadContext()
        onConfirmed?.()
      }
    } catch (cause) {
      setError(paymentError(cause))
    } finally {
      setBusy(false)
    }
  }

  async function submitCard(formData: unknown) {
    const row = formData && typeof formData === 'object' ? formData as Record<string, unknown> : {}
    setBusy(true)
    setError(null)
    try {
      const next = await createCardPayment(accessToken, kind, randomRequestKey(), {
        token: String(row.token ?? ''),
        payment_method_id: String(row.payment_method_id ?? ''),
        installments: Number(row.installments),
        issuer_id: row.issuer_id == null ? null : String(row.issuer_id),
      })
      setPayment(next)
      if (next.state?.appointment_status === 'CONFIRMED' || next.provider?.status === 'approved') {
        setConfirmed(true)
        await reloadContext()
        onConfirmed?.()
      }
    } catch (cause) {
      setError(paymentError(cause))
      throw cause
    } finally {
      setBusy(false)
    }
  }

  if (confirmed) {
    return (
      <section className="payment-panel payment-confirmed" aria-live="polite">
        <small>Pagamento confirmado</small>
        <h3>Sua reserva está confirmada.</h3>
        <p>Você pode guardar o código da reserva e fechar esta página.</p>
      </section>
    )
  }

  if (!context) {
    return <section className="payment-panel">{error ? <div className="form-alert error">{error}</div> : <p>Preparando pagamento…</p>}</section>
  }

  const qr = payment?.provider?.point_of_interaction?.transaction_data

  return (
    <section className="payment-panel">
      <div className="payment-heading">
        <small>Pagamento seguro</small>
        <h3>Confirme sua reserva</h3>
        <p>O valor é calculado pela Agenda. A confirmação só acontece após validação pelo Mercado Pago.</p>
      </div>

      {error ? <div className="form-alert error" role="alert">{error}</div> : null}

      <div className="payment-kind-grid">
        {context.financial.minimum_available ? (
          <label className={`payment-choice ${kind === 'MINIMUM' ? 'selected' : ''}`}>
            <input type="radio" name="payment-kind" checked={kind === 'MINIMUM'} onChange={() => { setKind('MINIMUM'); setPayment(null) }} />
            <span>
              <strong>Entrada de {numeric(context.financial.confirmation_percentage)}%</strong>
              <small>{money.format(numeric(context.financial.minimum_due_contract_amount))} do contrato</small>
            </span>
          </label>
        ) : null}
        <label className={`payment-choice ${kind === 'FULL' ? 'selected' : ''}`}>
          <input type="radio" name="payment-kind" checked={kind === 'FULL'} onChange={() => { setKind('FULL'); setPayment(null) }} />
          <span>
            <strong>Pagar 100% do saldo</strong>
            <small>{money.format(numeric(context.financial.contract_balance))}</small>
          </span>
        </label>
      </div>

      <div className="payment-method-tabs" role="tablist" aria-label="Forma de pagamento">
        <button type="button" className={method === 'PIX' ? 'active' : ''} onClick={() => { setMethod('PIX'); setPayment(null) }}>PIX</button>
        <button type="button" className={method === 'CARD' ? 'active' : ''} onClick={() => { setMethod('CARD'); setPayment(null) }}>Cartão</button>
      </div>

      {method === 'PIX' ? (
        <div className="payment-method-body">
          <div className="payment-amount">
            <span>Valor no PIX</span>
            <strong>{money.format(pixAmount)}</strong>
            {pixDiscount > 0 ? <small>{pixDiscount}% de desconto aplicado apenas a este pagamento.</small> : null}
          </div>

          {!qr?.qr_code ? (
            <button type="button" className="primary" disabled={busy || pixAmount <= 0} onClick={payPix}>
              {busy ? 'Gerando PIX…' : 'Gerar PIX'}
            </button>
          ) : (
            <div className="pix-box" aria-live="polite">
              {qr.qr_code_base64 ? <img src={`data:image/png;base64,${qr.qr_code_base64}`} alt="QR Code PIX" /> : null}
              <label>PIX copia e cola
                <textarea readOnly value={qr.qr_code ?? ''} onFocus={(event) => event.currentTarget.select()} />
              </label>
              <button type="button" className="secondary" onClick={() => navigator.clipboard.writeText(qr.qr_code ?? '')}>Copiar código PIX</button>
              <p>Aguardando confirmação do pagamento…</p>
            </div>
          )}
        </div>
      ) : (
        <div className="payment-method-body">
          <div className="payment-amount">
            <span>Valor no cartão</span>
            <strong>{money.format(cardAmount)}</strong>
            <small>Os dados do cartão são processados pelo formulário seguro do Mercado Pago.</small>
          </div>
          {!publicKey ? (
            <div className="form-alert error">Cartão será habilitado assim que a Public Key do Mercado Pago for configurada no ambiente.</div>
          ) : (
            <div className={busy ? 'card-brick busy' : 'card-brick'}>
              <CardPayment
                key={`${kind}:${cardAmount}`}
                initialization={{ amount: cardAmount }}
                customization={{ paymentMethods: { types: { excluded: ['debit_card', 'prepaid_card'] } } }}
                onSubmit={submitCard}
                onError={() => setError('Não foi possível carregar ou validar o formulário de cartão.')}
              />
            </div>
          )}
        </div>
      )}

      {payment?.provider?.status === 'rejected' ? <div className="form-alert error">Pagamento recusado. Você pode tentar novamente com outra forma.</div> : null}
    </section>
  )
}
