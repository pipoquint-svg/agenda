import { useEffect, useState } from 'react'
import {
  createInfinitePayCheckout,
  getInfinitePayContext,
  type InfinitePayContext,
} from './infinitepayPaymentApi'

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

function numeric(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function infinitePayError(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'INFINITEPAY_PAYMENT_ERROR'
  const messages: Array<[string, string]> = [
    ['INFINITEPAY_LIVE_LINKS_DISABLED', 'O checkout InfinitePay ainda não está liberado para uso.'],
    ['INFINITEPAY_LINK_CREATION_UNCERTAIN', 'A criação do checkout ficou inconclusiva. Não tente novamente; entre em contato com a equipe.'],
    ['INFINITEPAY_LINK_REJECTED', 'A InfinitePay não conseguiu criar este checkout. Entre em contato com a equipe.'],
    ['PAYMENT_HOLD_EXPIRED', 'O prazo para pagamento terminou. O horário foi liberado.'],
    ['APPOINTMENT_TOKEN_INVALID', 'O link de pagamento não é válido.'],
    ['APPOINTMENT_TOKEN_EXPIRED', 'O link de pagamento expirou.'],
    ['RATE_LIMITED', 'Muitas tentativas em sequência. Aguarde alguns minutos.'],
  ]
  return messages.find(([code]) => raw.includes(code))?.[1]
    ?? 'Não foi possível preparar o checkout InfinitePay.'
}

function secondsUntil(value: string | null | undefined): number | null {
  if (!value) return null
  const expiresAt = Date.parse(value)
  if (!Number.isFinite(expiresAt)) return null
  return Math.max(0, Math.ceil((expiresAt - Date.now()) / 1000))
}

function countdown(value: number): string {
  const minutes = Math.floor(value / 60)
  const seconds = value % 60
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
}

export function InfinitePayPaymentPanel({ accessToken, onConfirmed, mode = 'BOOKING' }: {
  accessToken: string
  onConfirmed?: () => void
  mode?: 'BOOKING' | 'BALANCE'
}) {
  const balanceMode = mode === 'BALANCE'
  const [context, setContext] = useState<InfinitePayContext | null>(null)
  const [kind, setKind] = useState<'MINIMUM' | 'FULL'>(balanceMode ? 'FULL' : 'MINIMUM')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [remainingSeconds, setRemainingSeconds] = useState<number | null>(null)

  useEffect(() => {
    let cancelled = false
    getInfinitePayContext(accessToken)
      .then((next) => {
        if (cancelled) return
        setContext(next)
        if (balanceMode || !next.financial.minimum_available) setKind('FULL')
        const settled = numeric(next.financial.contract_balance) <= 0
        const confirmed = !balanceMode && next.appointment.appointment_status === 'CONFIRMED'
        if (settled || confirmed) onConfirmed?.()
      })
      .catch((cause) => { if (!cancelled) setError(infinitePayError(cause)) })
    return () => { cancelled = true }
  }, [accessToken, balanceMode, onConfirmed])

  useEffect(() => {
    if (balanceMode || !context?.appointment.hold_expires_at) {
      setRemainingSeconds(null)
      return
    }

    const refresh = () => setRemainingSeconds(secondsUntil(context.appointment.hold_expires_at))
    refresh()
    const timer = window.setInterval(refresh, 1000)
    return () => window.clearInterval(timer)
  }, [balanceMode, context?.appointment.hold_expires_at])

  const expired = !balanceMode && remainingSeconds !== null && remainingSeconds <= 0

  async function continueToCheckout() {
    if (!context?.payment_provider.hosted_checkout_available) return
    if (!balanceMode && secondsUntil(context.appointment.hold_expires_at) === 0) {
      setRemainingSeconds(0)
      setError('O prazo para pagamento terminou. O horário foi liberado.')
      return
    }

    setBusy(true)
    setError(null)
    try {
      const result = await createInfinitePayCheckout(accessToken, kind, crypto.randomUUID())
      window.location.assign(result.checkout.url)
    } catch (cause) {
      setError(infinitePayError(cause))
      setBusy(false)
    }
  }

  if (!context) {
    return (
      <section className="payment-panel">
        {error ? <div className="form-alert error" role="alert">{error}</div> : <p>Preparando pagamento…</p>}
      </section>
    )
  }

  const available = context.payment_provider.hosted_checkout_available
  const amount = kind === 'FULL'
    ? numeric(context.financial.contract_balance)
    : numeric(context.financial.minimum_due_contract_amount)

  return (
    <section className="payment-panel">
      <div className="payment-heading">
        <small>Pagamento seguro</small>
        <h3>{balanceMode ? 'Pague o saldo' : 'Confirme sua reserva'}</h3>
        <p>O valor abaixo é o valor-base da Agenda. Pix, cartão e parcelamento são escolhidos no checkout seguro da InfinitePay.</p>
      </div>

      {!balanceMode && remainingSeconds !== null ? (
        <div className={`form-alert ${expired ? 'error' : ''}`} role="status" aria-live="polite">
          <strong>{expired ? 'Prazo encerrado' : `Seu horário está reservado por mais ${countdown(remainingSeconds)}`}</strong>
          <p>
            {expired
              ? 'O horário voltou automaticamente para a agenda e não é mais possível iniciar este pagamento.'
              : 'Conclua o pagamento dentro deste prazo. Depois do vencimento, o horário volta automaticamente para a agenda. Um pagamento realizado após esse prazo não garante a sessão e precisará ser tratado pela equipe.'}
          </p>
        </div>
      ) : null}

      {error ? <div className="form-alert error" role="alert">{error}</div> : null}

      {!available ? (
        <div className="form-alert error" role="status">
          <strong>Checkout ainda não liberado.</strong>
          <p>Esta integração está preparada, mas a criação de pagamentos InfinitePay permanece desligada.</p>
        </div>
      ) : null}

      <div className="payment-kind-grid">
        {!balanceMode && context.financial.minimum_available ? (
          <label className={`payment-choice ${kind === 'MINIMUM' ? 'selected' : ''}`}>
            <input
              type="radio"
              name="infinitepay-payment-kind"
              checked={kind === 'MINIMUM'}
              onChange={() => setKind('MINIMUM')}
            />
            <span>
              <strong>Pagar entrada</strong>
              <small>{money.format(numeric(context.financial.minimum_due_contract_amount))}</small>
            </span>
          </label>
        ) : null}

        {context.financial.full_available ? (
          <label className={`payment-choice ${kind === 'FULL' ? 'selected' : ''}`}>
            <input
              type="radio"
              name="infinitepay-payment-kind"
              checked={kind === 'FULL'}
              disabled={balanceMode}
              onChange={() => setKind('FULL')}
            />
            <span>
              <strong>{balanceMode ? 'Pagar saldo integral' : 'Pagar valor integral'}</strong>
              <small>{money.format(numeric(context.financial.contract_balance))}</small>
            </span>
          </label>
        ) : null}
      </div>

      <div className="payment-method-body">
        <div className="payment-amount">
          <span>Valor-base enviado à InfinitePay</span>
          <strong>{money.format(amount)}</strong>
          <small>A InfinitePay apresenta Pix ou cartão e calcula as condições de parcelamento conforme a configuração da conta.</small>
        </div>
        <button type="button" className="primary" disabled={!available || busy || expired || amount <= 0} onClick={continueToCheckout}>
          {expired ? 'Prazo de pagamento encerrado' : busy ? 'Abrindo checkout…' : 'Continuar para a InfinitePay'}
        </button>
      </div>
    </section>
  )
}
