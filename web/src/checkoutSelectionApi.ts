import type { ExtraSelection } from './bookingApi'
import { functionsBaseUrl, publicApiKey } from './supabase'

export async function updateCheckoutSelection(input: {
  token: string
  extras: ExtraSelection[]
  peopleCount: number
}): Promise<void> {
  const response = await fetch(`${functionsBaseUrl}/booking-checkout`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: publicApiKey,
      authorization: `Bearer ${publicApiKey}`,
    },
    body: JSON.stringify({
      action: 'UPDATE_SELECTION',
      checkout_hold_token: input.token,
      extra_selections: input.extras,
      people_count: input.peopleCount,
    }),
  })

  const payload = await response.json().catch(() => ({})) as { error?: { code?: string } }
  if (!response.ok) throw new Error(payload.error?.code ?? `HTTP_${response.status}`)
}
