import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'
import { normalizeServicePaymentPolicy } from '../_shared/service-payment-policy.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, PUT, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error('SERVICE_ID_INVALID')
  }
  return next
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const can = (permission: string) => hasAdminPermission(admin.adminId, permission)
    const requirePermission = async (permission: string) => {
      if (!(await can(permission))) throw new Error('ADMIN_PERMISSION_DENIED')
    }

    await requirePermission('SERVICES_VIEW')
    await requirePermission('FINANCE_VIEW')

    const client = adminClient()
    const url = new URL(req.url)
    const body = req.method === 'PUT' ? await req.json() : null
    const serviceId = uuid(req.method === 'GET' ? url.searchParams.get('service_id') : body?.service_id)

    const { data: before, error: beforeError } = await client
      .from('services')
      .select('id,pix_discount_percent,payment_mode,card_max_installments')
      .eq('id', serviceId)
      .maybeSingle()
    if (beforeError) throw new Error(beforeError.message)
    if (!before?.id) throw new Error('SERVICE_NOT_FOUND')

    const { data: operationSettings, error: settingsError } = await client
      .from('operation_settings')
      .select('pix_discount_percent')
      .eq('id', 1)
      .maybeSingle()
    if (settingsError) throw new Error(settingsError.message)

    const globalPixDiscount = Number(operationSettings?.pix_discount_percent ?? 0)
    const serialize = (row: typeof before) => ({
      service_id: row.id,
      pix_discount_percent: row.pix_discount_percent === null ? null : Number(row.pix_discount_percent),
      effective_pix_discount_percent: row.pix_discount_percent === null
        ? (Number.isFinite(globalPixDiscount) ? globalPixDiscount : 0)
        : Number(row.pix_discount_percent),
      inherits_pix_discount: row.pix_discount_percent === null,
      payment_mode: row.payment_mode ?? 'MINIMUM_OR_FULL',
      card_max_installments: Number(row.card_max_installments ?? 6),
    })

    if (req.method === 'GET') return json(serialize(before))

    await requirePermission('SERVICES_MANAGE')
    await requirePermission('FINANCE_MANAGE')
    const policy = normalizeServicePaymentPolicy(body as Record<string, unknown>)

    const { data: after, error: updateError } = await client
      .from('services')
      .update(policy)
      .eq('id', serviceId)
      .select('id,pix_discount_percent,payment_mode,card_max_installments')
      .single()
    if (updateError) throw new Error(updateError.message)

    const { error: auditError } = await client.from('audit_logs').insert({
      admin_user_id: admin.adminId,
      entity_type: 'SERVICE',
      entity_id: serviceId,
      action: 'SERVICE_PAYMENT_POLICY_UPDATED',
      before_json: serialize(before),
      after_json: serialize(after),
      origin: 'ADMIN',
    })
    if (auditError) throw new Error(auditError.message)

    return json(serialize(after))
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'SERVICE_PAYMENT_POLICY_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED'
        ? 403
        : code === 'SERVICE_NOT_FOUND'
          ? 404
          : 400
    return json({ error: { code } }, status)
  }
})
