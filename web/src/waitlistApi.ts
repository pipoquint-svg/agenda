import { functionsBaseUrl, publicApiKey } from './supabase'

export class WaitlistApiError extends Error {
  constructor(public code: string, public status: number) {
    super(code)
  }
}

export type WaitlistSignupInput = {
  bookingPageSlug: string
  serviceId: string
  name: string
  email: string
  whatsapp: string
}

export type WaitlistSignupResult = {
  ok: true
  waitlist_entry_id: string
  created_at: string
  message: string
}

export async function submitWaitlist(input: WaitlistSignupInput): Promise<WaitlistSignupResult> {
  const response = await fetch(`${functionsBaseUrl}/waitlist-signup`, {
    method: 'POST',
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      booking_page_slug: input.bookingPageSlug,
      service_id: input.serviceId,
      name: input.name,
      email: input.email,
      whatsapp: input.whatsapp,
    }),
  })

  const body = await response.json().catch(() => ({})) as Record<string, any>
  if (!response.ok) throw new WaitlistApiError(String(body?.error?.code ?? 'WAITLIST_SIGNUP_FAILED'), response.status)
  return body as WaitlistSignupResult
}