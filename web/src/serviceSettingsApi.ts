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

export type ServiceSettings = {
  id: string
  name: string
  slug: string
  category: string | null
  is_active: boolean
  duration_mode: 'FIXED' | 'BLOCKS'
  base_duration_minutes: number
  booking_block_minutes: number | null
  minimum_booking_blocks: number | null
  maximum_booking_blocks: number | null
  price_per_block: number | string | null
  base_price: number | string
  buffer_before_minutes: number
  buffer_after_minutes: number
  pricing_tiers: DurationPricingTier[]
  duration_presets: DurationPreset[]
  change_policy: Record<string, unknown> | null
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

export async function saveServiceTiming(payload: TimingPayload, accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify(payload) })
}

export async function saveDurationConfiguration(payload: DurationConfigurationPayload, accessToken: string): Promise<void> {
  await request('admin-service-settings', accessToken, { method: 'PUT', body: JSON.stringify(payload) })
}
