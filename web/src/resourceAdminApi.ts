import { functionsBaseUrl, publicApiKey } from './supabase'

export type ResourceAvailabilityRule = {
  id?: string
  weekday: number
  start_local_time: string
  end_local_time: string
  is_active: boolean
}

export type ResourceException = {
  id: string
  exception_type: 'BLOCK' | 'OPEN'
  start_at: string
  end_at: string
  reason: string | null
  created_at: string
}

export type ResourceServiceBinding = {
  service_id: string
  service_name: string
  operation_scope: 'SABRINA' | 'BLACKSHEEP' | null
  is_required: boolean
}

export type ResourceRow = {
  id: string
  name: string
  resource_type: string
  is_active: boolean
  availability_rules: ResourceAvailabilityRule[]
  exceptions: ResourceException[]
  service_bindings: ResourceServiceBinding[]
}

async function request(accessToken: string, init?: RequestInit): Promise<any> {
  const response = await fetch(`${functionsBaseUrl}/admin-resource-settings`, {
    ...init,
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json',
      ...(init?.headers ?? {}),
    },
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(body?.error?.code ?? `HTTP_${response.status}`)
  return body
}

export async function loadResources(token: string): Promise<ResourceRow[]> {
  const body = await request(token)
  return Array.isArray(body?.resources) ? body.resources : []
}

export const replaceResourceAvailability = (
  resourceId: string,
  rules: ResourceAvailabilityRule[],
  token: string,
) => request(token, { method: 'PUT', body: JSON.stringify({ resource_id: resourceId, rules }) })

export const addResourceException = (
  input: { resource_id: string; exception_type: 'BLOCK' | 'OPEN'; start_at: string; end_at: string; reason: string },
  token: string,
) => request(token, { method: 'POST', body: JSON.stringify({ action: 'EXCEPTION_ADD', ...input }) })

export const removeResourceException = (exceptionId: string, token: string) =>
  request(token, { method: 'DELETE', body: JSON.stringify({ action: 'EXCEPTION_DELETE', exception_id: exceptionId }) })
