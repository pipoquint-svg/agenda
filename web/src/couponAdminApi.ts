import { functionsBaseUrl, publicApiKey } from './supabase'

export type CouponAdminRow = {
  id: string
  code: string
  discount_type: 'FIXED' | 'PERCENT'
  discount_value: number | string
  valid_from: string | null
  valid_until: string | null
  is_active: boolean
  source: string
  customer_id: string | null
  customer_name: string | null
  source_appointment_id: string | null
  max_uses: number | null
  max_uses_per_customer: number | null
  used_count: number
  status: 'ACTIVE' | 'INACTIVE' | 'SCHEDULED' | 'EXPIRED' | 'EXHAUSTED'
  service_ids: string[]
}
export type CouponServiceOption = { id: string; name: string; category_id: string | null; category_name: string | null; operation_scope: 'SABRINA' | 'BLACKSHEEP' | null; is_active: boolean }
export type CouponCustomerOption = { id: string; name: string; email: string | null }
export type CouponAdminBundle = { coupons: CouponAdminRow[]; services: CouponServiceOption[]; customers: CouponCustomerOption[] }

async function request(accessToken: string, init?: RequestInit) {
  const response = await fetch(`${functionsBaseUrl}/admin-coupons`, {
    ...init,
    headers: { apikey: publicApiKey, authorization: `Bearer ${accessToken}`, 'content-type': 'application/json', ...(init?.headers ?? {}) },
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(payload?.error?.code ?? `HTTP_${response.status}`)
  return payload
}

export async function loadCoupons(accessToken: string): Promise<CouponAdminBundle> {
  const body = await request(accessToken)
  return { coupons: body.coupons ?? [], services: body.services ?? [], customers: body.customers ?? [] }
}

export type CouponMutation = {
  coupon_id?: string
  code: string
  discount_type: 'FIXED' | 'PERCENT'
  discount_value: number
  valid_from: string | null
  valid_until: string | null
  max_uses: number | null
  max_uses_per_customer: number | null
  customer_id: string | null
  service_ids: string[]
  is_active?: boolean
}

export async function createCoupon(input: CouponMutation, accessToken: string) {
  await request(accessToken, { method: 'POST', body: JSON.stringify(input) })
}
export async function updateCoupon(input: CouponMutation & { coupon_id: string; is_active: boolean }, accessToken: string) {
  await request(accessToken, { method: 'PUT', body: JSON.stringify(input) })
}
export async function removeCoupon(couponId: string, accessToken: string): Promise<{ removed: boolean; archived: boolean }> {
  return request(accessToken, { method: 'DELETE', body: JSON.stringify({ coupon_id: couponId }) })
}
