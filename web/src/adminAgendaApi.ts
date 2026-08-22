import { functionsBaseUrl, publicApiKey } from './supabase'

export type AdminResource = {
  id?: string
  resource_id?: string
  allocation_id?: string
  name?: string
  resource_name?: string
  type?: string
  resource_type?: string
  status?: string
  occupied_start_at?: string
  occupied_end_at?: string
  start_at?: string
  end_at?: string
}

export type AdminAppointment = {
  id: string
  public_code: string
  status: string
  financial_status: string
  start_at: string
  end_at: string
  duration_minutes: number
  duration_blocks: number | null
  contracted_minutes: number | null
  people_count: number
  origin: string
  service_name: string
  duration_mode: 'FIXED' | 'BLOCKS' | string
  buffer_before_minutes: number
  buffer_after_minutes: number
  employee_name: string | null
  customer: { id: string | null; name: string | null; phone: string | null; email: string | null }
  commercial_value: number
  financial: Record<string, unknown>
  resources: AdminResource[]
}

export type AdminExternalBlock = {
  allocation_id: string
  resource_id: string
  resource_name: string
  start_at: string
  end_at: string
  status: string
  reason: string | null
  source: string
  calendar_name: string | null
  event_summary: string | null
  event_qualification: string | null
}

export type AdminAgendaResponse = {
  range: { start_at: string; end_at: string }
  appointments: AdminAppointment[]
  external_blocks: AdminExternalBlock[]
}

export type AppointmentDetailResponse = {
  appointment: AdminAppointment & Record<string, unknown>
  customer: Record<string, unknown> | null
  financial: Record<string, unknown>
  extras: Array<Record<string, unknown>>
  answers: Array<Record<string, unknown>>
  terms: Array<Record<string, unknown>>
  payments: Array<Record<string, unknown>>
  package_usage: Record<string, unknown> | null
  resources: AdminResource[]
}

export type AmeliaHistoryRecord = {
  id: string
  amelia_booking_id: string
  customer_name: string | null
  customer_email: string | null
  customer_phone: string | null
  service_name: string | null
  employee_name: string | null
  start_at: string | null
  end_at: string | null
  status_raw: string | null
  payment_status_raw: string | null
  operational_authority: string
  record_mode: string
}

export class AdminAgendaApiError extends Error {
  code: string
  constructor(code: string) {
    super(code)
    this.code = code
  }
}

async function adminRequest(path: string, accessToken: string): Promise<Response> {
  const response = await fetch(`${functionsBaseUrl}/${path}`, {
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${accessToken}`,
    },
  })

  if (!response.ok) {
    let code = 'ADMIN_AGENDA_REQUEST_FAILED'
    try {
      const body = await response.json()
      code = body?.error?.code ?? code
    } catch {
      // Stable generic code for non-JSON failures.
    }
    throw new AdminAgendaApiError(code)
  }
  return response
}

export async function getAdminAgenda(
  startAt: string,
  endAt: string,
  accessToken: string,
): Promise<AdminAgendaResponse> {
  const params = new URLSearchParams({ action: 'agenda', start_at: startAt, end_at: endAt })
  return (await adminRequest(`admin-agenda?${params}`, accessToken)).json()
}

export async function getAdminAppointment(
  id: string,
  accessToken: string,
): Promise<AppointmentDetailResponse> {
  const params = new URLSearchParams({ action: 'appointment', id })
  return (await adminRequest(`admin-agenda?${params}`, accessToken)).json()
}

export async function getAmeliaHistory(
  startAt: string,
  endAt: string,
  search: string,
  accessToken: string,
): Promise<{ records: AmeliaHistoryRecord[] }> {
  const params = new URLSearchParams({ action: 'amelia', start_at: startAt, end_at: endAt })
  if (search.trim()) params.set('search', search.trim())
  return (await adminRequest(`admin-agenda?${params}`, accessToken)).json()
}
