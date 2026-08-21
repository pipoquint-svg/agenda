import { useEffect, useState } from 'react'
import { BookingCheckout } from './BookingCheckout'
import { PaymentPanel } from './PaymentPanel'
import type { CheckoutHold } from './bookingApi'

type StoredHold = {
  token: string
  id: string
  pageSlug: string
  serviceId: string
  serviceName: string
  expiresAt: string
}

type StoredManage = {
  appointmentId: string
  publicCode: string
  accessToken: string
  status: 'AWAITING_PAYMENT' | 'CONFIRMED'
}

function readJson<T>(key: string): T | null {
  try {
    const raw = sessionStorage.getItem(key)
    return raw ? JSON.parse(raw) as T : null
  } catch {
    return null
  }
}

function readStoredHold(): StoredHold | null {
  const parsed = readJson<Partial<StoredHold>>('bs_checkout_hold')
  if (!parsed?.token || !parsed.id || !parsed.expiresAt) return null
  return parsed as StoredHold
}

function readManage(): StoredManage | null {
  const parsed = readJson<Partial<StoredManage>>('bs_appointment_manage')
  if (!parsed?.appointmentId || !parsed.publicCode || !parsed.accessToken || !parsed.status) return null
  return parsed as StoredManage
}

function asCheckoutHold(stored: StoredHold): CheckoutHold {
  return {
    checkout_hold_token: stored.token,
    checkout_hold_id: stored.id,
    status: 'ACTIVE',
    expires_at: stored.expiresAt,
    slot_start_at: '',
    slot_end_at: '',
    core_start_at: '',
    core_end_at: '',
    pre_service_minutes: 0,
    post_service_minutes: 0,
    commercial_value: 0,
    duration_minutes: 1,
    pricing_version: '',
  }
}

export function BookingCheckoutSession() {
  const [stored, setStored] = useState<StoredHold | null>(() => readStoredHold())
  const [manage, setManage] = useState<StoredManage | null>(() => readManage())

  useEffect(() => {
    const timer = window.setInterval(() => {
      const currentHold = readStoredHold()
      const currentManage = readManage()

      if (!stored && currentHold) setStored(currentHold)
      if (stored && !currentHold && !currentManage && new Date(stored.expiresAt).getTime() <= Date.now()) setStored(null)

      if (currentManage?.accessToken !== manage?.accessToken || currentManage?.status !== manage?.status) {
        setManage(currentManage)
      }
    }, 400)
    return () => window.clearInterval(timer)
  }, [stored, manage])

  function markConfirmed() {
    if (!manage) return
    const next: StoredManage = { ...manage, status: 'CONFIRMED' }
    sessionStorage.setItem('bs_appointment_manage', JSON.stringify(next))
    setManage(next)
  }

  if (!stored && !manage) return null

  return (
    <main className="booking-shell booking-checkout-shell">
      {stored ? (
        <section className="booking-card">
          <BookingCheckout hold={asCheckoutHold(stored)} />
        </section>
      ) : null}

      {manage?.status === 'AWAITING_PAYMENT' ? (
        <section className="booking-card payment-card">
          <PaymentPanel accessToken={manage.accessToken} onConfirmed={markConfirmed} />
        </section>
      ) : null}

      {!stored && manage?.status === 'CONFIRMED' ? (
        <section className="booking-card checkout-result">
          <small>Reserva confirmada</small>
          <h2>Pagamento confirmado</h2>
          <p>Código da reserva: <strong>{manage.publicCode}</strong></p>
        </section>
      ) : null}
    </main>
  )
}
