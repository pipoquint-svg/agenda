import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, PUT, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function text(value: unknown, nullable = false): string | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  if (typeof value !== 'string') throw new Error('BIRTHDAY_TEXT_INVALID')
  const next = value.trim()
  if (!next && !nullable) throw new Error('BIRTHDAY_TEXT_INVALID')
  return next || null
}

function booleanValue(value: unknown, name: string): boolean {
  if (typeof value !== 'boolean') throw new Error(`${name}_INVALID`)
  return value
}

function integer(value: unknown, nullable = true): number | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  const next = Number(value)
  if (!Number.isInteger(next) || next < 0) throw new Error('BIRTHDAY_INTEGER_INVALID')
  return next
}

function decimal(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null
  const next = Number(value)
  if (!Number.isFinite(next) || next < 0) throw new Error('BIRTHDAY_DECIMAL_INVALID')
  return next
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'SERVICES_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const { data, error } = await client.rpc('service_admin_list_birthday_automation_settings')
      if (error) throw new Error(error.message)
      return json({ settings: data ?? [] })
    }

    if (!(await hasAdminPermission(admin.adminId, 'SERVICES_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const body = await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('BIRTHDAY_PAYLOAD_INVALID')
    const record = body as Record<string, unknown>
    const operationScope = (text(record.operation_scope) as string).toUpperCase()
    if (!['SABRINA', 'BLACKSHEEP'].includes(operationScope)) throw new Error('BIRTHDAY_OPERATION_SCOPE_INVALID')

    const generateCoupon = booleanValue(record.generate_coupon, 'BIRTHDAY_GENERATE_COUPON')
    const couponDiscountType = text(record.coupon_discount_type, true)?.toUpperCase() ?? null
    if (couponDiscountType !== null && !['PERCENT', 'FIXED'].includes(couponDiscountType)) throw new Error('BIRTHDAY_COUPON_DISCOUNT_TYPE_INVALID')

    const payload = {
      p_operation_scope: operationScope,
      p_is_active: booleanValue(record.is_active, 'BIRTHDAY_ACTIVE'),
      p_send_message: booleanValue(record.send_message, 'BIRTHDAY_SEND_MESSAGE'),
      p_generate_coupon: generateCoupon,
      p_send_on_birthday: booleanValue(record.send_on_birthday, 'BIRTHDAY_SEND_ON_BIRTHDAY'),
      p_days_before: integer(record.days_before),
      p_coupon_prefix: text(record.coupon_prefix, true),
      p_coupon_discount_type: couponDiscountType,
      p_coupon_discount_value: decimal(record.coupon_discount_value),
      p_coupon_validity_days: integer(record.coupon_validity_days),
      p_coupon_max_uses: integer(record.coupon_max_uses),
      p_coupon_max_uses_per_customer: integer(record.coupon_max_uses_per_customer),
      p_actor_admin_id: admin.adminId,
    }

    const { data, error } = await client.rpc('service_admin_update_birthday_automation_settings', payload)
    if (error) throw new Error(error.message)
    return json({ id: data })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'BIRTHDAY_ADMIN_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' || code === 'ADMIN_FINANCE_PERMISSION_REQUIRED'
        ? 403
        : 400
    return json({ error: { code } }, status)
  }
})
