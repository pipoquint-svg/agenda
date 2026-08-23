import { functionsBaseUrl, publicApiKey } from './supabase'

export type DashboardScope = '' | 'BLACKSHEEP' | 'SABRINA'

export type DashboardMetrics = {
  booking_count: number
  booked_minutes: number | string
  new_booking_count: number
  cancellations_count: number
  reschedules_count: number
  recurring_customers?: {
    available: boolean
    reason: string | null
    count: number | null
  }
}

export type DashboardEmployee = {
  employee_id: string | null
  employee_name: string | null
  booking_count: number
  booked_minutes: number | string
}

export type DashboardPendingItem = {
  kind: string
  entity_type: string
  entity_id: string
  appointment_id?: string | null
  customer_id?: string | null
  customer_name?: string | null
  service_id?: string | null
  service_name?: string | null
  operation_scope?: string | null
  status?: string | null
  start_at?: string | null
  expires_at?: string | null
  detected_at?: string | null
  reason?: string | null
  policy_action_id?: string | null
  resource_id?: string | null
}

export type DashboardOccupancy = {
  available: boolean
  reason: string | null
  resource_id: string | null
  capacity_minutes: number | string | null
  total_occupied_minutes: number | string | null
  appointment_minutes: number | string | null
  filtered_appointment_minutes: number | string | null
  external_block_minutes: number | string | null
  manual_block_minutes: number | string | null
  total_rate_percent: number | string | null
  appointment_rate_percent: number | string | null
  filtered_appointment_rate_percent: number | string | null
}

export type AdminDashboardResponse = {
  range: { start_at: string; end_at: string }
  operation_scope: 'BLACKSHEEP' | 'SABRINA' | null
  metrics: DashboardMetrics
  by_employee: DashboardEmployee[]
  pending_items: DashboardPendingItem[]
  occupancy: DashboardOccupancy
}

export class AdminDashboardApiError extends Error {
  constructor(public code: string) {
    super(code)
  }
}

export async function getAdminDashboard(input: {
  startAt: string
  endAt: string
  operationScope: DashboardScope
  accessToken: string
}): Promise<AdminDashboardResponse> {
  const params = new URLSearchParams({ start_at: input.startAt, end_at: input.endAt })
  if (input.operationScope) params.set('operation_scope', input.operationScope)

  const response = await fetch(`${functionsBaseUrl}/admin-dashboard?${params}`, {
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${input.accessToken}`,
    },
  })

  if (!response.ok) {
    let code = 'ADMIN_DASHBOARD_REQUEST_FAILED'
    try {
      const body = await response.json()
      code = body?.error?.code ?? code
    } catch {
      // Keep a stable generic error for non-JSON failures.
    }
    throw new AdminDashboardApiError(code)
  }

  return response.json()
}
