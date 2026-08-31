import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'
import { normalizePublicMinimumBookingNoticeHours } from '../_shared/public-booking-notice.ts'

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
  if (req.method !== 'GET' && req.method !== 'PUT') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const permission = req.method === 'GET' ? 'SERVICES_VIEW' : 'SERVICES_MANAGE'
    const admin = await requireAdminPermission(req, permission)
    const client = adminClient()

    const url = new URL(req.url)
    const body = req.method === 'PUT' ? await req.json() : null
    const serviceId = uuid(req.method === 'GET' ? url.searchParams.get('service_id') : body?.service_id)

    const { data: current, error: currentError } = await client
      .from('services')
      .select('id,public_minimum_booking_notice_hours')
      .eq('id', serviceId)
      .maybeSingle()

    if (currentError) throw new Error(currentError.message)
    if (!current) throw new Error('SERVICE_NOT_FOUND')

    if (req.method === 'GET') {
      return json({
        service_id: current.id,
        public_minimum_booking_notice_hours: Number(current.public_minimum_booking_notice_hours ?? 0),
      })
    }

    const nextHours = normalizePublicMinimumBookingNoticeHours(body?.public_minimum_booking_notice_hours)
    const previousHours = Number(current.public_minimum_booking_notice_hours ?? 0)

    if (previousHours !== nextHours) {
      const { error: updateError } = await client
        .from('services')
        .update({ public_minimum_booking_notice_hours: nextHours })
        .eq('id', serviceId)
      if (updateError) throw new Error(updateError.message)

      const { error: auditError } = await client.from('audit_logs').insert({
        admin_user_id: admin.adminId,
        entity_type: 'SERVICE',
        entity_id: serviceId,
        action: 'SERVICE_PUBLIC_BOOKING_NOTICE_UPDATED',
        before_json: { public_minimum_booking_notice_hours: previousHours },
        after_json: { public_minimum_booking_notice_hours: nextHours },
        origin: 'ADMIN',
      })
      if (auditError) throw new Error(auditError.message)
    }

    return json({
      service_id: serviceId,
      public_minimum_booking_notice_hours: nextHours,
      changed: previousHours !== nextHours,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'SERVICE_PUBLIC_BOOKING_NOTICE_FAILED'
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
