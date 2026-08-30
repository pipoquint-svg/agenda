import { functionsBaseUrl, publicApiKey } from './supabase'
import type { AppointmentCheckoutResult, ServiceAnswer } from './bookingApi'

export type CheckoutPrebookOption = {
  eligible: boolean
  available: boolean
  active_count: number
  max_active_prebooks: number
  hold_minutes: number
  reason: string | null
}

type PrebookCheckoutResult = AppointmentCheckoutResult & {
  pre_reservation?: boolean
  pre_reservation_id?: string
  pre_reservation_expires_at?: string | null
  pre_reservation_email_sent?: boolean
}

async function post<T>(path: string, body: Record<string, unknown>, resultKey: 'data' | 'appointment'): Promise<T> {
  const res = await fetch(`${functionsBaseUrl}/${path}`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
    },
    body: JSON.stringify(body),
  })
  const payload = await res.json().catch(() => ({})) as Record<string, unknown> & { error?: { code?: string } }
  if (!res.ok) throw new Error(payload.error?.code ?? `HTTP_${res.status}`)
  const value = payload[resultKey]
  if (value === undefined) throw new Error('PUBLIC_GATEWAY_INVALID_RESPONSE')
  return value as T
}

export async function loadCheckoutPrebookOption(token: string): Promise<CheckoutPrebookOption> {
  return post<CheckoutPrebookOption>('booking-checkout', {
    action: 'PREBOOK_OPTION',
    checkout_hold_token: token,
  }, 'data')
}

export async function submitPreReservationCheckout(input: {
  token: string
  termVersionIds: string[]
  answers: ServiceAnswer[]
}): Promise<PrebookCheckoutResult> {
  return post<PrebookCheckoutResult>('booking-submit', {
    checkout_hold_token: input.token,
    checkout_mode: 'PREBOOK',
    term_version_ids: input.termVersionIds,
    answers: input.answers,
  }, 'appointment')
}
