import { functionsBaseUrl, publicApiKey } from './supabase'

export type AdminFinancePeriod = { from: string; to: string }

export type AdminFinanceSummary = {
  range: AdminFinancePeriod
  cash: {
    gross_received: number
    refunded: number
    net_received: number
    operational_penalties_received: number
  }
  contract: {
    gross_settled: number
    refunded: number
    net_settled_delta: number
    payment_discounts_granted: number
  }
  pending: { charge_count: number; charge_cash_amount: number }
  activity: { transaction_count: number; approved_charge_count: number; approved_refund_count: number }
  by_method: Array<{ method: string; charge_cash: number; refund_cash: number; net_cash: number }>
  by_provider: Array<{ provider: string; charge_cash: number; refund_cash: number; net_cash: number }>
  customer_balance: Record<string, unknown>
  accounting: { customer_balance_classification: 'LIABILITY_NOT_REVENUE' | string; note: string }
}

export type AdminFinanceTransaction = {
  id: string
  occurred_at: string
  appointment_id: string
  appointment: {
    public_code: string | null
    service_name: string | null
    start_at: string | null
    status: string | null
    financial_status: string | null
  } | null
  customer: { id: string; name: string | null } | null
  transaction_type: string
  payment_purpose: string
  method: string
  provider: string
  provider_payment_id: string | null
  status: string
  contract_amount_settled: number
  payment_discount_amount: number
  cash_amount: number
  requested_percentage: number | null
  parent_transaction_id: string | null
  policy_action_id: string | null
  balance_collection_id: string | null
  created_by_admin_id: string | null
  notes: string | null
  paid_at: string | null
  created_at: string
  updated_at: string
}

export type AdminFinanceTransactionsResponse = {
  range: AdminFinancePeriod
  filters: Record<string, string | null>
  pagination: { page: number; limit: number; total: number; total_pages: number }
  transactions: AdminFinanceTransaction[]
}

export type AdminFinanceRefundResponse = {
  policy_action_id: string
  appointment_id: string
  refund_status: string
  refunded_now: Array<Record<string, unknown>>
  remaining_refund_cash: number | string
  manual_refund_cash: number | string
  completed: boolean
}

export class AdminFinanceApiError extends Error {
  constructor(public code: string) {
    super(code)
  }
}

async function request(path: string, accessToken: string, init?: RequestInit): Promise<Response> {
  const response = await fetch(`${functionsBaseUrl}/${path}`, {
    ...init,
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${accessToken}`,
      ...(init?.body ? { 'content-type': 'application/json', 'x-request-id': crypto.randomUUID() } : {}),
      ...(init?.headers ?? {}),
    },
  })

  if (!response.ok) {
    let code = 'ADMIN_FINANCE_REQUEST_FAILED'
    try {
      const body = await response.json()
      code = body?.error?.code ?? code
    } catch {
      // Preserve a stable generic error for non-JSON failures.
    }
    throw new AdminFinanceApiError(code)
  }
  return response
}

function periodParams(from: string, to: string) {
  return new URLSearchParams({ from, to })
}

export async function getAdminFinanceSummary(from: string, to: string, accessToken: string): Promise<AdminFinanceSummary> {
  return (await request(`admin-finance?${periodParams(from, to)}`, accessToken)).json()
}

export async function getAdminFinanceTransactions(input: {
  from: string
  to: string
  accessToken: string
  page?: number
  limit?: number
  transactionType?: string
  status?: string
  paymentPurpose?: string
  method?: string
  provider?: string
  appointmentId?: string
}): Promise<AdminFinanceTransactionsResponse> {
  const params = periodParams(input.from, input.to)
  if (input.page) params.set('page', String(input.page))
  if (input.limit) params.set('limit', String(input.limit))
  if (input.transactionType) params.set('transaction_type', input.transactionType)
  if (input.status) params.set('status', input.status)
  if (input.paymentPurpose) params.set('payment_purpose', input.paymentPurpose)
  if (input.method) params.set('method', input.method)
  if (input.provider) params.set('provider', input.provider)
  if (input.appointmentId) params.set('appointment_id', input.appointmentId)
  return (await request(`admin-finance/transactions?${params}`, input.accessToken)).json()
}

export async function processAdminFinanceRefund(policyActionId: string, accessToken: string): Promise<AdminFinanceRefundResponse> {
  return (await request('admin-finance/refund', accessToken, {
    method: 'POST',
    body: JSON.stringify({ policy_action_id: policyActionId }),
  })).json()
}
