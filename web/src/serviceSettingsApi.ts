import { functionsBaseUrl, publicApiKey } from './supabase'

export type DurationPricingTier = {
  id?: string
  min_blocks: number
  max_blocks: number | null
  price_per_block: number | string
  is_active: boolean
  sort_order: number
}

export type DurationPreset = {
  id?: string
  block_count: number
  title: string
  description: string | null
  badge: string | null
  is_featured: boolean
  is_active: boolean
  sort_order: number
}

export type ServiceFieldType = 'TEXT' | 'TEXTAREA' | 'NUMBER' | 'DATE' | 'SELECT' | 'MULTISELECT' | 'BOOLEAN'

export type ServiceCustomField = {
  id?: string
  field_key: string
  label: string
  field_type: ServiceFieldType
  help_text: string | null
  placeholder: string | null
  is_required: boolean
  sort_order: number
  options_json: string[] | null
  is_active: boolean
}

export type OperationScope = 'SABRINA' | 'BLACKSHEEP'

export type PenaltyType = 'NONE' | 'FIXED' | 'PERCENT'

export type ChangePolicy = {
  notice_hours: number
  reschedule_first_penalty_type: PenaltyType
  reschedule_first_penalty_value: number | string
  reschedule_repeat_penalty_type: PenaltyType
  reschedule_repeat_penalty_value: number | string
  reschedule_late_penalty_type: PenaltyType
  reschedule_late_penalty_value: number | string
  cancellation_early_penalty_type: PenaltyType
  cancellation_early_penalty_value: number | string
  cancellation_late_penalty_type: PenaltyType
  cancellation_late_penalty_value: number | string
  cancellation_early_refund_allowed: boolean
  cancellation_early_credit_allowed: boolean
  cancellation_late_refund_allowed: boolean
  cancellation_late_credit_allowed: boolean
  cancellation_credit_validity_days: number
}

export type ServiceSettings = {
  id: string
  name: string
  slug: string
  short_description: string | null
  full_description: string | null
  operation_scope: OperationScope | null
  is_active: boolean
  sort_order: number
  duration_mode: 'FIXED' | 'BLOCKS'
  base_duration_minutes: number
  booking_block_minutes: number | null
  minimum_booking_blocks: number | null
  maximum_booking_blocks: number | null
  price_per_block: number | string | null
  base_price: number | string
  buffer_before_minutes: number
  buffer_after_minutes: number
  custom_fields: ServiceCustomField[]
  pricing_tiers: DurationPricingTier[]
  duration_presets: DurationPreset[]
  change_policy: ChangePolicy | null
}

type TimingPayload = {
  service_id: string
  action: 'TIMING'
  duration_mode: 'FIXED' | 'BLOCKS'
  base_duration_minutes: number
  booking_block_minutes: number | null
  minimum_booking_blocks: number | null
  maximum_booking_blocks: number | null
  base_price: number
  price_per_block: number | null
  buffer_before_minutes: number
  buffer_after_minutes: number
}

type DurationConfigurationPayload = {
  service_id: string
  action: 'DURATION_CONFIGURATION'
  pricing_tiers: DurationPricingTier[]
  duration_presets: DurationPreset[]
}

export type CreateServicePayload = {
  name: string
  slug: string
  operation_scope: OperationScope
  short_description?: string | null
  full_description?: string | null
  duration_mode?: 'FIXED' | 'BLOCKS'
  base_duration_minutes?: number
  base_price?: number
  buffer_before_minutes?: number
  buffer_after_minutes?: number
}

export type UpdateServiceCatalogPayload = {
  service_id: string
  action: 'CATALOG'
  name: string
  slug: string
  operation_scope: OperationScope
  short_description: string | null
  full_description: string | null
  is_active: boolean
  sort_order: number
}

export class ServiceSettingsApiError extends Error {
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
      'content-type': 'application/json',
      ...(init?.headers ?? {}),
    },
  })

  if (!response.ok) {
    let code = 'SERVICE_SETTINGS_REQUEST_FAILED'
    try {
      const body = await response.json()
      code = body?.error?.code ?? code
    } catch {
      // Keep stable generic code for non-JSON failures.
    }
    throw new ServiceSettingsApiError(code)
  }
  return response
}

export async function listServiceSettings(accessToken: string): Promise<ServiceSettings[]> {
  const body = await (await request('admin-service-settings', accessToken)).json()
  return body.services ?? []
}

export async function createService(payload: CreateServicePayload, accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, { method: 'POST', body: JSON.stringify(payload) })
}

export async function saveServiceCatalog(payload: UpdateServiceCatalogPayload, accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify(payload) })
}

export async function removeService(serviceId: string, accessToken: string): Promise<{ removed: boolean; archived: boolean }> {
  const response = await request('admin-service-settings', accessToken, { method: 'DELETE', body: JSON.stringify({ service_id: serviceId }) })
  return response.json()
}

export async function saveCustomFields(serviceId: string, fields: ServiceCustomField[], accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, {
    method: 'PUT',
    body: JSON.stringify({ service_id: serviceId, action: 'CUSTOM_FIELDS', fields }),
  })
}

export async function saveServiceTiming(payload: TimingPayload, accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify(payload) })
}

export async function saveDurationConfiguration(payload: DurationConfigurationPayload, accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify(payload) })
}

export async function saveChangePolicy(serviceId: string, policy: ChangePolicy, accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, {
    method: 'PUT',
    body: JSON.stringify({ service_id: serviceId, action: 'CHANGE_POLICY', policy }),
  })
}
