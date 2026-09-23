import { PaymentPanel } from './PaymentPanel'
import './payment.css'
import './checkout.css'

function accessToken(): string {
  return new URLSearchParams(window.location.search).get('token')?.trim() ?? ''
}

export function PreReservationPaymentPage() {
  const token = accessToken()

  if (token.length < 32) {
    return (
      <main className="checkout-shell">
        <section className="checkout-card">
          <span className="agenda-eyebrow">BlackSheep Estúdio Criativo</span>
          <h1>Link de pré-reserva inválido</h1>
          <p>Este link não está completo. Confira o e-mail recebido ou entre em contato com a equipe.</p>
        </section>
      </main>
    )
  }

  return (
    <main className="checkout-shell">
      <section className="checkout-card payment-card">
        <span className="agenda-eyebrow">BlackSheep Estúdio Criativo</span>
        <h1>Confirme sua pré-reserva</h1>
        <p>Confira abaixo as condições de confirmação desta pré-reserva e o prazo informado no e-mail.</p>
        <PaymentPanel accessToken={token} />
      </section>
    </main>
  )
}
