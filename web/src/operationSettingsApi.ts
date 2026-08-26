import { functionsBaseUrl, publicApiKey } from './supabase'

export type OperationScope = 'SABRINA' | 'BLACKSHEEP'
export type OperationSettingsKey =
  | 'public_name' | 'public_email' | 'public_phone' | 'public_address' | 'public_site_url'
  | 'timezone' | 'default_currency' | 'checkout_hold_minutes' | 'payment_hold_minutes'
  | 'agency_hold_minutes' | 'default_confirmation_percentage' | 'pix_discount_percent'
  | 'default_slot_interval_minutes'

export type OperationSettingsValues = Record<OperationSettingsKey, string | number | null>
export type OperationSettingsPatch = Partial<OperationSettingsValues>
export type OperationSettingsResolved = OperationSettingsValues & {
  operation_scope: OperationScope
  source?: { base?: string; override_present?: boolean }
}
export type OperationSettingsOverride = Partial<OperationSettingsValues> & { operation_scope?: OperationScope; id?: string }
export type OperationSettingsBundle = { resolved: OperationSettingsResolved; override: OperationSettingsOverride | null }

async function request<T>(accessToken: string, url: string, init?: RequestInit): Promise<T> {
  const response = await fetch(url, {
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
  return body as T
}

export function loadOperationSettings(scope: OperationScope, accessToken: string) {
  return request<OperationSettingsBundle>(accessToken, `${functionsBaseUrl}/admin-operation-settings?operation_scope=${encodeURIComponent(scope)}&include_override=1`)
}

export function updateOperationSettings(scope: OperationScope, patch: OperationSettingsPatch, accessToken: string) {
  return request<OperationSettingsBundle>(accessToken, `${functionsBaseUrl}/admin-operation-settings`, {
    method: 'PUT',
    body: JSON.stringify({ operation_scope: scope, patch }),
  })
}
