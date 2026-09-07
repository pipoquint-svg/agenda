import { functionsBaseUrl, publicApiKey } from './supabase'
import type { CheckoutHold, ExtraSelection } from './bookingApi'

export type PrivateInviteExtra = {
  id: string
  name: string
  description: string | null
  price: number | string
  is_required: boolean
  max_quantity: number
}

export type PrivateInviteService = {
  id: string
  name: string
  base_price: number | string
  minimum_people: number
  maximum_people: number
  service_employee_id: string
  extras: PrivateInviteExtra[]
}

export type PrivateInviteContext = {
  invite_id: string
  slot_id: string
  invitee_name: string
  start_at: string
  expires_at: string
  slot_status: 'OPEN' | 'CLAIMED' | 'FILLED' | 'CLOSED' | 'EXPIRED'
  availability: 'OPEN' | 'CLAIMED' | 'FILLED' | 'UNAVAILABLE' | 'IN_PROGRESS'
  booking_page_slug: string
  brand_key: string
  services: PrivateInviteService[]
}

export type PrivateInviteHold = CheckoutHold & {
  booking_page_slug: string
  service_name: string
}

async function call<T>(body: Record<string, unknown>): Promise<T> {
  const res = await fetch(`${functionsBaseUrl}/waitlist-private-invite`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
    },
    body: JSON.stringify(body),
  })
  const payload = await res.json().catch(() => ({})) as { data?: T; hold?: T; error?: { code?: string } }
  if (!res.ok) throw new Error(payload.error?.code ?? `HTTP_${res.status}`)
  const value = payload.data ?? payload.hold
  if (value === undefined) throw new Error('WAITLIST_PRIVATE_INVALID_RESPONSE')
  return value
}

export function loadPrivateInviteContext(accessToken: string): Promise<PrivateInviteContext> {
  return call<PrivateInviteContext>({ action: 'CONTEXT', access_token: accessToken })
}

export function createPrivateInviteHold(input: {
  accessToken: string
  serviceId: string
  extras: ExtraSelection[]
  peopleCount: number
}): Promise<PrivateInviteHold> {
  return call<PrivateInviteHold>({
    action: 'CREATE_HOLD',
    access_token: input.accessToken,
    service_id: input.serviceId,
    extra_selections: input.extras,
    people_count: input.peopleCount,
  })
}
