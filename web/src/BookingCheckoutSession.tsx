import { useEffect, useState } from 'react'
import { BookingCheckout } from './BookingCheckout'
import type { CheckoutHold } from './bookingApi'

type StoredHold = {
  token: string
  id: string
  pageSlug: string
  serviceId: string
  serviceName: string
  expiresAt: string
}

function readStoredHold(): StoredHold | null {
  try {
    const raw = sessionStorage.getItem('bs_checkout_hold')
    if (!raw) return null
    const parsed = JSON.parse(raw) as Partial<StoredHold>
    if (!parsed.token || !parsed.id || !parsed.expiresAt) return null
    return parsed as StoredHold
  } catch {
    return null
  }
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

  useEffect(() => {
    const timer = window.setInterval(() => {
      const current = readStoredHold()
      if (!stored && current) {
        setStored(current)
        return
      }

      if (stored && !current) {
        const completed = sessionStorage.getItem('bs_appointment_manage')
        if (!completed && new Date(stored.expiresAt).getTime() <= Date.now()) setStored(null)
      }
    }, 400)
    return () => window.clearInterval(timer)
  }, [stored])

  if (!stored) return null

  return (
    <main className="booking-shell booking-checkout-shell">
      <section className="booking-card">
        <BookingCheckout hold={asCheckoutHold(stored)} />
      </section>
    </main>
  )
}
