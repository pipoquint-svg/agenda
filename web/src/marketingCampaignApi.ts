import { functionsBaseUrl, publicApiKey } from './supabase'

export type MarketingService = { id: string; name: string; slug: string }
export type MarketingCampaign = { id: string; campaign_key: string; internal_name: string; public_name: string | null; description: string | null; state: string; active_version_id: string | null; created_at: string }
export type MarketingVersion = { id: string; campaign_id: string; version_number: number; publication_status: string; discount_type: string; discount_value: number; validity_basis: string; validity_days: number; eligibility_rules: { service_ids?: string[] }; created_at: string; published_at: string | null }
export type MarketingCampaignBundle = { campaigns: MarketingCampaign[]; versions: MarketingVersion[]; services: MarketingService[]; delivery: { status: 'FROZEN'; channel: 'WHATSAPP'; reason: string } }

async function request(accessToken: string, init?: RequestInit): Promise<unknown> {
  const response = await fetch(`${functionsBaseUrl}/admin-marketing-campaigns`, { ...init, headers: { apikey: publicApiKey, authorization: `Bearer ${accessToken}`, ...(init?.body ? { 'content-type': 'application/json' } : {}), ...(init?.headers ?? {}) } })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(payload?.error?.code ?? `HTTP_${response.status}`)
  return payload
}
export async function loadMarketingCampaigns(accessToken: string) { return await request(accessToken) as MarketingCampaignBundle }
export async function createMarketingCampaign(input: Record<string, unknown>, accessToken: string) { return await request(accessToken, { method: 'POST', body: JSON.stringify({ ...input, action: 'CREATE', request_id: crypto.randomUUID() }) }) }
export async function transitionMarketingCampaign(input: Record<string, unknown>, accessToken: string) { return await request(accessToken, { method: 'POST', body: JSON.stringify({ ...input, action: 'TRANSITION', request_id: crypto.randomUUID() }) }) }
