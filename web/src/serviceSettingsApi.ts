import { functionsBaseUrl, publicApiKey } from './supabase'

export type OperationScope = 'SABRINA' | 'BLACKSHEEP'
export type ServiceFieldType = 'TEXT' | 'TEXTAREA' | 'NUMBER' | 'DATE' | 'SELECT' | 'MULTISELECT' | 'BOOLEAN'
export type PricingActionType = 'REPLACE_PRICE' | 'ADD_AMOUNT' | 'ADD_PERCENT'

export type DurationPricingTier = { id?: string; min_blocks: number; max_blocks: number | null; price_per_block: number | string; is_active: boolean; sort_order: number }
export type DurationPreset = { id?: string; block_count: number; title: string; description: string | null; badge: string | null; is_featured: boolean; is_active: boolean; sort_order: number }
export type ServiceCustomField = { id?: string; field_key: string; label: string; field_type: ServiceFieldType; help_text: string | null; placeholder: string | null; is_required: boolean; sort_order: number; options_json: string[] | null; is_active: boolean }

export type ServiceCategory = { id: string; name: string; slug: string; operation_scope: OperationScope | null; sort_order: number; is_active: boolean; service_count: number }
export type ExtraCatalogItem = { id: string; name: string; description: string | null; price: number | string; duration_delta_minutes: number; is_active: boolean; service_count: number }
export type ServiceExtra = { extra_id: string; name: string; description: string | null; price: number | string; duration_delta_minutes: number; is_active: boolean; sort_order: number; is_required: boolean; max_quantity: number; schedule_placement: 'PREPEND' | 'APPEND'; default_schedule_minutes: number }
export type DayTimePricingRule = { id?: string; name: string; days_of_week: number[] | null; start_local_time: string | null; end_local_time: string | null; valid_from_date: string | null; valid_until_date: string | null; action_type: PricingActionType; amount: number | string | null; percentage: number | string | null; priority: number; is_active: boolean }

export type PenaltyType = 'NONE' | 'FIXED' | 'PERCENT'
export type ChangePolicy = {
  notice_hours: number; reschedule_first_penalty_type: PenaltyType; reschedule_first_penalty_value: number | string
  reschedule_repeat_penalty_type: PenaltyType; reschedule_repeat_penalty_value: number | string; reschedule_late_penalty_type: PenaltyType
  reschedule_late_penalty_value: number | string; cancellation_early_penalty_type: PenaltyType; cancellation_early_penalty_value: number | string
  cancellation_late_penalty_type: PenaltyType; cancellation_late_penalty_value: number | string; cancellation_early_refund_allowed: boolean
  cancellation_early_credit_allowed: boolean; cancellation_late_refund_allowed: boolean; cancellation_late_credit_allowed: boolean; cancellation_credit_validity_days: number
}

export type ServiceSettings = {
  id: string; name: string; slug: string; short_description: string | null; full_description: string | null
  category_id: string | null; category_name: string | null; operation_scope: OperationScope | null; is_active: boolean; sort_order: number
  duration_mode: 'FIXED' | 'BLOCKS'; base_duration_minutes: number; slot_interval_minutes: number; booking_block_minutes: number | null; minimum_booking_blocks: number | null
  maximum_booking_blocks: number | null; price_per_block: number | string | null; base_price: number | string; minimum_people: number
  maximum_people: number; price_per_extra_person: number | string; buffer_before_minutes: number; buffer_after_minutes: number
  custom_fields: ServiceCustomField[]; day_time_pricing_rules: DayTimePricingRule[]; service_extras: ServiceExtra[]
  pricing_tiers: DurationPricingTier[]; duration_presets: DurationPreset[]; change_policy: ChangePolicy | null
}

export type ServiceCatalogBundle = { services: ServiceSettings[]; categories: ServiceCategory[]; extras: ExtraCatalogItem[] }
type TimingPayload = { service_id: string; action: 'TIMING'; duration_mode: 'FIXED' | 'BLOCKS'; base_duration_minutes: number; slot_interval_minutes: number; booking_block_minutes: number | null; minimum_booking_blocks: number | null; maximum_booking_blocks: number | null; base_price: number; price_per_block: number | null; buffer_before_minutes: number; buffer_after_minutes: number }
type DurationConfigurationPayload = { service_id: string; action: 'DURATION_CONFIGURATION'; pricing_tiers: DurationPricingTier[]; duration_presets: DurationPreset[] }

// category/people fields are optional at the TypeScript boundary only so the legacy advanced
// policy editor keeps compiling. The Edge Function remains authoritative and rejects catalog
// creation/mutation without a real category and full people contract.
export type CreateServicePayload = {
  entity?: 'SERVICE'; name: string; slug: string; category_id?: string; operation_scope: OperationScope
  short_description?: string | null; full_description?: string | null; duration_mode?: 'FIXED' | 'BLOCKS'; base_duration_minutes?: number
  base_price?: number; buffer_before_minutes?: number; buffer_after_minutes?: number; minimum_people?: number; maximum_people?: number; price_per_extra_person?: number
}
export type UpdateServiceCatalogPayload = {
  entity?: 'SERVICE'; service_id: string; action: 'CATALOG'; name: string; slug: string; category_id?: string; operation_scope: OperationScope
  short_description: string | null; full_description: string | null; minimum_people?: number; maximum_people?: number; price_per_extra_person?: number
  is_active: boolean; sort_order: number
}

export class ServiceSettingsApiError extends Error { constructor(public code: string) { super(code) } }
async function request(path: string, accessToken: string, init?: RequestInit): Promise<Response> {
  const response = await fetch(`${functionsBaseUrl}/${path}`, { ...init, headers: { apikey: publicApiKey, authorization: `Bearer ${accessToken}`, 'content-type': 'application/json', ...(init?.headers ?? {}) } })
  if (!response.ok) { let code = 'SERVICE_SETTINGS_REQUEST_FAILED'; try { const body = await response.json(); code = body?.error?.code ?? code } catch { /* stable fallback */ }; throw new ServiceSettingsApiError(code) }
  return response
}

export async function loadServiceCatalog(accessToken: string): Promise<ServiceCatalogBundle> {
  const body = await (await request('admin-service-settings', accessToken)).json()
  const services = Array.isArray(body.services)
    ? body.services.map((service: ServiceSettings) => ({ ...service, slot_interval_minutes: Number(service?.slot_interval_minutes ?? 30) }))
    : []
  return { services, categories: body.categories ?? [], extras: body.extras ?? [] }
}
export async function listServiceSettings(accessToken: string): Promise<ServiceSettings[]> { return (await loadServiceCatalog(accessToken)).services }
export async function createCategory(payload: { name: string; slug: string; operation_scope: OperationScope }, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'POST', body: JSON.stringify({ entity: 'CATEGORY', ...payload }) }) }
export async function saveCategory(payload: ServiceCategory, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'CATEGORY', category_id: payload.id, name: payload.name, slug: payload.slug, operation_scope: payload.operation_scope, sort_order: payload.sort_order, is_active: payload.is_active }) }) }
export async function removeCategory(categoryId: string, accessToken: string): Promise<{ removed: boolean; archived: boolean }> { return (await request('admin-service-settings', accessToken, { method: 'DELETE', body: JSON.stringify({ entity: 'CATEGORY', category_id: categoryId }) })).json() }
export async function createExtra(payload: { name: string; description: string | null; price: number; duration_delta_minutes: number }, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'POST', body: JSON.stringify({ entity: 'EXTRA', ...payload }) }) }
export async function saveExtra(payload: ExtraCatalogItem, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'EXTRA', extra_id: payload.id, name: payload.name, description: payload.description, price: Number(payload.price), duration_delta_minutes: payload.duration_delta_minutes, is_active: payload.is_active }) }) }
export async function removeExtra(extraId: string, accessToken: string): Promise<{ removed: boolean; archived: boolean }> { return (await request('admin-service-settings', accessToken, { method: 'DELETE', body: JSON.stringify({ entity: 'EXTRA', extra_id: extraId }) })).json() }
export async function createService(payload: CreateServicePayload, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'POST', body: JSON.stringify({ entity: 'SERVICE', ...payload }) }) }
export async function saveServiceCatalog(payload: UpdateServiceCatalogPayload, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'SERVICE', ...payload }) }) }
export async function removeService(serviceId: string, accessToken: string): Promise<{ removed: boolean; archived: boolean }> { return (await request('admin-service-settings', accessToken, { method: 'DELETE', body: JSON.stringify({ entity: 'SERVICE', service_id: serviceId }) })).json() }
export async function saveCustomFields(serviceId: string, fields: ServiceCustomField[], accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'SERVICE', service_id: serviceId, action: 'CUSTOM_FIELDS', fields }) }) }
export async function saveDayTimePricing(serviceId: string, rules: DayTimePricingRule[], accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'SERVICE', service_id: serviceId, action: 'DAY_TIME_PRICING', rules }) }) }
export async function saveServiceExtras(serviceId: string, extras: Array<{ extra_id: string; sort_order: number; is_required: boolean; max_quantity: number; schedule_placement: 'PREPEND' | 'APPEND'; default_schedule_minutes: number | null }>, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'SERVICE', service_id: serviceId, action: 'SERVICE_EXTRAS', extras }) }) }
export async function saveServiceTiming(payload: TimingPayload, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'SERVICE', ...payload }) }) }
export async function saveDurationConfiguration(payload: DurationConfigurationPayload, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'SERVICE', ...payload }) }) }
export async function saveChangePolicy(serviceId: string, policy: ChangePolicy, accessToken: string): Promise<void> { await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify({ entity: 'SERVICE', service_id: serviceId, action: 'CHANGE_POLICY', policy }) }) }