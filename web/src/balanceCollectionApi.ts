import { functionsBaseUrl, publicApiKey } from './supabase'

export class BalanceCollectionApiError extends Error {
  constructor(public code: string) {
    super(code)
  }
}

export type AdminBalanceRow = {
  appointment_id: string
  public_code: string | null
  customer_id: string | null
  customer_name: string | null
  service_name: string | null
  operation_scope: string | null
  appointment_status: string | null
  financial_status: string | null
  billing_mode_snapshot: string | null
  start_at: string | null
  core_end_at: string | null
  total_value: number | string
  paid_value: number | string
  balance_value: number | string
  active_collection_id: string | null
  collection_sequence: number | null
  collection_expires_at: string | null
  collection_status: string | null
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

export async function listAdminBalances(input: {
  accessToken: string
  mode: 'open' | 'overdue'
  operationScope?: '' | 'BLACKSHEEP' | 'SABRINA'
}): Promise<AdminBalanceRow[]> {
  const params = new URLSearchParams({ mode: input.mode })
  if (input.operationScope) params.set('operation_scope', input.operationScope)
  const response = await fetch(`${functionsBaseUrl}/admin-balance-collections?${params}`, {
    headers: { apikey: publicApiKey, authorization: `Bearer ${input.accessToken}` },
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new BalanceCollectionApiError(body?.error?.code ?? 'ADMIN_BALANCE_COLLECTION_FAILED')
  return body.rows ?? []
}

export async function reissueBalanceCollection(input: { appointmentId: string; accessToken: string }): Promise<void> {
  const response = await fetch(`${functionsBaseUrl}/admin-balance-collections`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json', apikey: publicApiKey,
      authorization: `Bearer ${input.accessToken}`,
      'x-request-id': crypto.randomUUID(),
    },
    body: JSON.stringify({ action: 'REISSUE', appointment_id: input.appointmentId }),
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new BalanceCollectionApiError(body?.error?.code ?? 'ADMIN_BALANCE_COLLECTION_FAILED')
}

export async function recordManualBalancePayment(input: {
  appointmentId: string
  accessToken: string
  amount: number
  method: 'CASH' | 'OTHER'
}): Promise<{
  payment_recorded?: boolean
  provider_cleanup_pending?: boolean
  data?: Record<string, unknown>
}> {
  const response = await fetch(`${functionsBaseUrl}/admin-balance-collections`, {
    method: 'POST',
    headers: {
      'content-type': 'application/json', apikey: publicApiKey,
      authorization: `Bearer ${input.accessToken}`,
      'x-request-id': crypto.randomUUID(),
    },
    body: JSON.stringify({
      action: 'RECORD_MANUAL_PAYMENT', appointment_id: input.appointmentId,
      amount: input.amount, method: input.method,
    }),
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok && body?.payment_recorded !== true) throw new BalanceCollectionApiError(body?.error?.code ?? 'ADMIN_BALANCE_COLLECTION_FAILED')
  if (!response.ok && body?.payment_recorded === true) {
    return { payment_recorded: true, provider_cleanup_pending: true, data: body.data }
  }
  return body
}
