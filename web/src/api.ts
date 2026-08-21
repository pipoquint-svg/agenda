import { functionsBaseUrl, publicApiKey } from './supabase'
import { trackDemandLead } from './tracking'

export type DemandConfig = {
  brands: string[]
  services: Array<{ id: string; name: string }>
  consent: { text: string; version: string }
}

export type DemandRecord = {
  id: string
  created_at: string
  name: string
  whatsapp: string
  email: string
  brand: string
  service_label: string
  desired_date: string | null
  desired_period: string | null
  campaign: string | null
  status: 'NEW' | 'CONTACTED' | 'CONVERTED' | 'DISCARDED'
}

export type DemandSummary = {
  total: number
  by_date: Array<{ date: string; count: number }>
  by_period: Array<{ period: string; count: number }>
  by_service: Array<{ service: string; count: number }>
}

export type DemandFilters = {
  brand?: string
  campaign?: string
  service?: string
  created_from?: string
  created_to?: string
  desired_from?: string
  desired_to?: string
  status?: string
}

export class ApiError extends Error {
  code: string
  constructor(code: string) {
    super(code)
    this.code = code
  }
}

async function request(path: string, init: RequestInit = {}, accessToken?: string): Promise<Response> {
  const headers = new Headers(init.headers)
  headers.set('apikey', publicApiKey)
  headers.set('authorization', `Bearer ${accessToken ?? publicApiKey}`)
  if (init.body && !headers.has('content-type')) headers.set('content-type', 'application/json')
  const response = await fetch(`${functionsBaseUrl}/${path}`, { ...init, headers })
  if (!response.ok) {
    let code = 'REQUEST_FAILED'
    try {
      const body = await response.json()
      code = body?.error?.code ?? code
    } catch {
      // Keep the stable generic code when the response is not JSON.
    }
    throw new ApiError(code)
  }
  return response
}

export async function getDemandConfig(): Promise<DemandConfig> {
  return (await request('demand-capture')).json()
}

export async function submitDemand(body: Record<string, unknown>): Promise<void> {
  await request('demand-capture', { method: 'POST', body: JSON.stringify(body) })
  const brand = typeof body.brand === 'string' ? body.brand : ''
  const serviceId = typeof body.service_id === 'string' ? body.service_id : ''
  const campaign = typeof body.campaign === 'string' ? body.campaign : null
  if (brand && serviceId) trackDemandLead({ brand, serviceId, campaign })
}

function filterParams(filters: DemandFilters): URLSearchParams {
  const params = new URLSearchParams()
  for (const [key, value] of Object.entries(filters)) {
    if (value) params.set(key, value)
  }
  return params
}

export async function getDemandAdmin(filters: DemandFilters, accessToken: string) {
  const params = filterParams(filters)
  params.set('page_size', '100')
  return (await request(`demand-capture-admin?${params.toString()}`, {}, accessToken)).json() as Promise<{
    records: DemandRecord[]
    pagination: { page: number; page_size: number; total: number }
    summary: DemandSummary
  }>
}

export async function updateDemandStatus(
  id: string,
  status: DemandRecord['status'],
  accessToken: string,
): Promise<void> {
  await request('demand-capture-admin', {
    method: 'PATCH',
    body: JSON.stringify({ id, status }),
  }, accessToken)
}

export async function downloadDemandCsv(filters: DemandFilters, accessToken: string): Promise<void> {
  const params = filterParams(filters)
  params.set('format', 'csv')
  const response = await request(`demand-capture-admin?${params.toString()}`, {}, accessToken)
  const blob = await response.blob()
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = 'captura-demanda.csv'
  document.body.appendChild(link)
  link.click()
  link.remove()
  URL.revokeObjectURL(url)
}
