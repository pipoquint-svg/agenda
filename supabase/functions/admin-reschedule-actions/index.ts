import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown, code: string): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error(code)
  }
  return next
}

function localDate(value: unknown): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^\d{4}-\d{2}-\d{2}$/.test(next)) throw new Error('RESCHEDULE_DATE_INVALID')
  return next
}

function isoDateTime(value: unknown): string {
  const next = typeof value === 'string' ? value.trim() : ''
  const parsed = new Date(next)
  if (!next || Number.isNaN(parsed.getTime())) throw new Error('RESCHEDULE_TIME_INVALID')
  return parsed.toISOString()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const body = await req.json()
    const action = typeof body?.action === 'string' ? body.action.trim().toUpperCase() : ''
    const appointmentId = uuid(body?.appointment_id, 'APPOINTMENT_ID_INVALID')
    const client = adminClient()
    const requirePermission = async (permission: string) => {
      if (!(await hasAdminPermission(admin.adminId, permission))) throw new Error('ADMIN_PERMISSION_DENIED')
    }

    if (action === 'LIST_SLOTS') {
      await requirePermission('AGENDA_MANAGE')
      const date = localDate(body?.local_date)
      const { data, error } = await client.rpc('service_admin_list_reschedule_slots', {
        p_appointment_id: appointmentId,
        p_local_date: date,
      })
      if (error) throw new Error(error.message)
      return json({ appointment_id: appointmentId, local_date: date, slots: data ?? [] })
    }

    if (action === 'CREATE_HOLD') {
      await requirePermission('AGENDA_MANAGE')
      const requestedStartAt = isoDateTime(body?.requested_start_at)
      const { data, error } = await client.rpc('service_admin_create_reschedule_hold', {
        p_appointment_id: appointmentId,
        p_requested_start_at: requestedStartAt,
        p_requested_at: new Date().toISOString(),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'REGISTER_PENALTY') {
      await requirePermission('AGENDA_MANAGE')
      await requirePermission('FINANCE_MANAGE')
      const policyActionId = uuid(body?.policy_action_id, 'POLICY_ACTION_ID_INVALID')
      const method = typeof body?.method === 'string' ? body.method.trim().toUpperCase() : ''
      if (!['PIX', 'CARD', 'CASH', 'TRANSFER', 'OTHER'].includes(method)) throw new Error('INVALID_PENALTY_PAYMENT_METHOD')
      const notes = typeof body?.notes === 'string' ? body.notes.trim().slice(0, 500) : null
      const { data, error } = await client.rpc('service_admin_register_reschedule_penalty_payment', {
        p_policy_action_id: policyActionId,
        p_method: method,
        p_notes: notes || null,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'APPLY') {
      await requirePermission('AGENDA_MANAGE')
      const policyActionId = uuid(body?.policy_action_id, 'POLICY_ACTION_ID_INVALID')
      const { data, error } = await client.rpc('service_admin_apply_reschedule', {
        p_policy_action_id: policyActionId,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    throw new Error('RESCHEDULE_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_RESCHEDULE_ACTION_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : 400
    return json({ error: { code } }, status)
  }
})
