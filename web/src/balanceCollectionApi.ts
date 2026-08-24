import { functionsBaseUrl, publicApiKey } from './supabase'

export class BalanceCollectionApiError extends Error {
  constructor(public code: string) {
    super(code)
  }
}

export async function verifyBalanceCollection(input: { collectionId: string; email: string }): Promise<{
  access_token: string
  expires_at: string
  amount: number | string
}> {
  const response = await fetch(`${functionsBaseUrl}/balance-collection-access`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', apikey: publicApiKey },
    body: JSON.stringify({ collection_id: input.collectionId, email: input.email }),
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new BalanceCollectionApiError(body?.error?.code ?? 'BALANCE_COLLECTION_ACCESS_FAILED')
  return body.data
}

export async function reissueBalanceCollection(input: { appointmentId: string; accessToken: string }): Promise<void> {
  const response = await fetch(`${functionsBaseUrl}/admin-balance-collections`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      apikey: publicApiKey,
      authorization: `Bearer ${input.accessToken}`,
    },
    body: JSON.stringify({ action: 'REISSUE', appointment_id: input.appointmentId }),
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new BalanceCollectionApiError(body?.error?.code ?? 'ADMIN_BALANCE_COLLECTION_FAILED')
}
