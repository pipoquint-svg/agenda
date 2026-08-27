import { functionsBaseUrl, publicApiKey } from './supabase'

export type HourPackageStatus = 'ACTIVE' | 'EXHAUSTED' | 'EXPIRED' | 'CANCELLED'
export type HourPackageSummary = {
  id: string
  customer_id: string
  customer: { id: string; name: string | null } | null
  name: string
  status: HourPackageStatus | string
  total_minutes: number
  total_seconds: number
  consumed_seconds: number
  available_minutes: number
  available_seconds: number
  purchased_value: number
  reference_minute_value: number
  valid_from: string
  valid_until: string
}
export type HourPackagesResponse = {
  filters: { customer_id: string | null; status: string | null }
  pagination: { page: number; limit: number; total: number; total_pages: number }
  packages: HourPackageSummary[]
}
export type HourPackageLedgerEntry = Record<string, unknown> & {
  movement_id: string
  ledger_seq: number
  registered_at: string
  movement_type: string
  appointment_id: string | null
  seconds_delta: number
  balance_after_seconds: number
}
export type HourPackageLedgerResponse = {
  package: {
    id: string
    customer_id: string
    name: string
    status: string
    total_seconds: number
    available_seconds: number
    valid_from: string
    valid_until: string
  }
  ledger: HourPackageLedgerEntry[]
}

export type AuditEvent = {
  id: string
  action: string
  entityType: string
  entityId: string | null
  occurredAt: string
  actorId: string | null
  actor: { id: string; display_name: string | null; role: string | null } | null
  metadata: { origin: string | null; request_id: string | null }
}
export type AuditLogResponse = {
  pagination: { page: number; limit: number; total: number; total_pages: number }
  events: AuditEvent[]
  redaction: { before_after_included: boolean; reason: string }
}

export type TeamMember = {
  id: string
  auth_user_id: string
  display_name: string | null
  email: string | null
  role: string
  is_active: boolean
  created_at: string
  updated_at: string
  email_confirmed_at: string | null
  last_sign_in_at: string | null
  permissions: Record<string, boolean>
  permission_overrides: Array<{
    permission: string
    is_granted: boolean
    updated_by_admin_id: string | null
    updated_at: string
  }>
}
export type TeamMembersResponse = {
  members: TeamMember[]
  security: { session_tokens_exposed: false; password_data_exposed: false }
}
export type TeamPermissionChange = { permission: string; is_granted: boolean }

export type IntegrationStatus = 'CONNECTED' | 'PENDING' | 'BACKEND_ONLY'
export type IntegrationSummary = {
  key: string
  label: string
  status: IntegrationStatus
  last_sync_at: string | null
  detail: Record<string, unknown>
}
export type IntegrationsResponse = {
  integrations: IntegrationSummary[]
  safety: { credentials_exposed: false; providers_mutated: false }
  generated_at: string
}
export type IntegrationFailure = {
  id: string
  integration: string
  job_type: string
  entity_type: string
  entity_id: string
  appointment_id: string | null
  error_code: string | null
  occurred_at: string
  attempt_count: number
  max_attempts: number
  retriable: boolean
}
export type IntegrationFailuresResponse = {
  pagination: { page: number; limit: number; total: number; total_pages: number }
  failures: IntegrationFailure[]
  redaction: { raw_provider_errors_included: false; payloads_included: false }
}

export class AdminBackofficeApiError extends Error {
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
    let code = 'ADMIN_BACKOFFICE_REQUEST_FAILED'
    try { code = (await response.json())?.error?.code ?? code } catch { /* stable fallback */ }
    throw new AdminBackofficeApiError(code)
  }
  return response
}

export async function getHourPackages(input: { customerId?: string; status?: HourPackageStatus; page?: number; limit?: number; accessToken: string }): Promise<HourPackagesResponse> {
  const params = new URLSearchParams({ page: String(input.page ?? 1), limit: String(input.limit ?? 50) })
  if (input.customerId) params.set('customer_id', input.customerId)
  if (input.status) params.set('status', input.status)
  return (await request(`admin-hour-packages?${params}`, input.accessToken)).json()
}

export async function getHourPackageLedger(id: string, accessToken: string): Promise<HourPackageLedgerResponse> {
  return (await request(`admin-hour-packages/${encodeURIComponent(id)}/ledger`, accessToken)).json()
}

export async function getAuditLog(input: { startAt?: string; endAt?: string; actor?: string; entityType?: string; entityId?: string; action?: string; page?: number; limit?: number; accessToken: string }): Promise<AuditLogResponse> {
  const params = new URLSearchParams({ page: String(input.page ?? 1), limit: String(input.limit ?? 50) })
  if (input.startAt) params.set('start_at', input.startAt)
  if (input.endAt) params.set('end_at', input.endAt)
  if (input.actor) params.set('actor', input.actor)
  if (input.entityType) params.set('entity_type', input.entityType)
  if (input.entityId) params.set('entity_id', input.entityId)
  if (input.action) params.set('action', input.action)
  return (await request(`admin-audit-log?${params}`, input.accessToken)).json()
}

export async function getTeamMembers(accessToken: string): Promise<TeamMembersResponse> {
  return (await request('admin-team-members', accessToken)).json()
}

export async function updateTeamMemberPermissions(id: string, permissions: TeamPermissionChange[], accessToken: string): Promise<{ member_id: string; profile: Record<string, unknown> }> {
  return (await request(`admin-team-members/${encodeURIComponent(id)}/permissions`, accessToken, {
    method: 'PUT',
    body: JSON.stringify({ permissions }),
  })).json()
}

export async function getIntegrations(accessToken: string): Promise<IntegrationsResponse> {
  return (await request('admin-integrations', accessToken)).json()
}

export async function getIntegrationFailures(input: { page?: number; limit?: number; accessToken: string }): Promise<IntegrationFailuresResponse> {
  const params = new URLSearchParams({ page: String(input.page ?? 1), limit: String(input.limit ?? 50) })
  return (await request(`admin-integrations/sync-failures?${params}`, input.accessToken)).json()
}
