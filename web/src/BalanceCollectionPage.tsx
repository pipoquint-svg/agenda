import { FormEvent, useState } from 'react'
import { BalanceCollectionApiError, verifyBalanceCollection } from './balanceCollectionApi'
import { PaymentPanel } from './PaymentPanel'

function collectionId(): string {
  return new URLSearchParams(window.location.search).get('collection')?.trim() ?? ''
}

function message(error: unknown): string {
  const code = error instanceof BalanceCollectionApiError ? error.code : 'BALANCE_COLLECTION_TEMPORARY_FAILURE'
  if (code === 'BALANCE_COLLECTION_INVALID_OR_EXPIRED') return 'Este link expirou. Entre em contato com a equipe para receber uma nova cobrança.'
  if (code === 'BALANCE_COLLECTION_ALREADY_PAID') return 'Este saldo já foi pago. Não há cobrança em aberto neste link.'
  if (code === 'BALANCE_COLLECTION_VERIFICATION_FAILED') return 'Não foi possível confirmar o e-mail informado. Confira os dados ou fale com a equipe.'
  if (code === 'BALANCE_COLLECTION_RATE_LIMITED') return 'Foram feitas muitas tentativas. Aguarde alguns minutos e tente novamente.'
  return 'Não foi possível abrir a cobrança agora. Tente novamente em instantes.'
}

export function BalanceCollectionPage() {
  const id = collectionId()
  const [email, setEmail] = useState('')
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  async function submit(event: FormEvent) {
    event.preventDefault()
    setBusy(true)
    setError('')
    try {
      const result = await verifyBalanceCollection({ collectionId: id, email })
      setAccessToken(result.access_token)
    } catch (cause) {
      setError(message(cause))
    } finally {
      setBusy(false)
    }
  }

  if (!id) {
    return <main className="checkout-shell"><section className="checkout-card"><h1>Link inválido</h1><p>Este link de pagamento não está completo.</p></section></main>
  }

  if (accessToken) {
    return <main className="checkout-shell"><section className="checkout-card"><PaymentPanel accessToken={accessToken} /></section></main>
  }

  return (
    <main className="checkout-shell">
      <section className="checkout-card">
        <span className="agenda-eyebrow">BlackSheep Estúdio Criativo</span>
        <h1>Pagamento do saldo da locação</h1>
        <p>Para sua segurança, confirme o e-mail usado na reserva. Este link fica disponível por 48 horas a partir da emissão.</p>
        <form onSubmit={submit} className="checkout-form">
          <label>
            <span>E-mail da reserva</span>
            <input type="email" required autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} />
          </label>
          {error ? <div className="form-alert error" role="alert">{error}</div> : null}
          <button className="primary" type="submit" disabled={busy}>{busy ? 'Confirmando…' : 'Continuar para o pagamento'}</button>
        </form>
      </section>
    </main>
  )
}
