import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown, code = 'APPOINTMENT_ID_INVALID'): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) throw new Error(code)
  return next
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, 'AGENDA_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : ''
    const appointmentId = uuid(body.appointment_id)
    const client = adminClient()

    if (action === 'GET_OPTIONS') {
      const { data, error } = await client.rpc('service_admin_get_appointment_edit_options', {
        p_appointment_id: appointmentId,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'GET_POST_BOOKING_OPTIONS') {
      if (!(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const { data, error } = await client.rpc('service_admin_post_booking_extra_options', {
        p_appointment_id: appointmentId, p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'CONFIRM_UNPAID') {
      const reason = typeof body.reason === 'string' ? body.reason.trim().slice(0, 500) : ''
      if (!reason) throw new Error('CONFIRM_WITHOUT_PAYMENT_REASON_REQUIRED')
      const { data, error } = await client.rpc('service_admin_confirm_appointment_unpaid', {
        p_appointment_id: appointmentId,
        p_reason: reason,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'ADD_EXTRA') {
      const extraId = uuid(body.extra_id, 'EXTRA_ID_INVALID')
      const quantity = Number(body.quantity ?? 1)
      if (!Number.isInteger(quantity) || quantity < 1 || quantity > 99) throw new Error('APPOINTMENT_EXTRA_QUANTITY_INVALID')
      const { data, error } = await client.rpc('service_admin_add_appointment_extra', {
        p_appointment_id: appointmentId,
        p_extra_id: extraId,
        p_quantity: quantity,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'ADD_POST_BOOKING_EXTRA') {
      if (!(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const kind = typeof body.kind === 'string' ? body.kind.trim().toUpperCase() : ''
      if (!['EXTRA_TIME','ASSISTANCE','SOCIAL_COVERAGE','CATALOG_EXTRA'].includes(kind)) throw new Error('APPOINTMENT_EXTRA_KIND_INVALID')
      const extraId = kind === 'EXTRA_TIME' ? null : uuid(body.extra_id, 'EXTRA_ID_INVALID')
      const quantity = Number(body.quantity)
      if (!Number.isSafeInteger(quantity) || quantity < 1 || quantity > 2147483647) throw new Error('APPOINTMENT_EXTRA_QUANTITY_INVALID')
      const requestId = uuid(body.request_id, 'APPOINTMENT_EXTRA_REQUEST_INVALID')
      const { data, error } = await client.rpc('service_admin_add_post_booking_extra', {
        p_appointment_id: appointmentId, p_kind: kind, p_extra_id: extraId,
        p_quantity: quantity, p_admin_id: admin.adminId, p_request_id: requestId,
      })
      if (error) throw new Error(error.message)
      const result = data as Record<string, unknown>
      if (result.notification === 'PROVIDER_REFRESH_PENDING') {
        const base = Deno.env.get('SUPABASE_URL')?.trim().replace(/\/$/, '') ?? ''
        const secret = Deno.env.get('INTEGRATION_INTERNAL_SECRET')?.trim() ?? ''
        if (!base || !secret) return json({ ...result, provider_cleanup_pending: true }, 202)
        try {
          const response = await fetch(`${base}/functions/v1/balance-collection-provider-cancel`, {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'x-internal-secret': secret },
            body: JSON.stringify({ collection_id: result.collection_id, reason: 'BALANCE_CHANGED', admin_id: admin.adminId }),
          })
          if (!response.ok) return json({ ...result, provider_cleanup_pending: true }, 202)
          return json({ ...result, notification: 'LINK_UPDATED', provider_order_cancelled: true }, 201)
        } catch {
          return json({ ...result, provider_cleanup_pending: true }, 202)
        }
      }
      return json(result, 201)
    }

    throw new Error('APPOINTMENT_EDIT_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_APPOINTMENT_EDIT_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
