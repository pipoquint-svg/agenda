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

function uuid(value: unknown, code: string): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) throw new Error(code)
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

function changeOrigin(value: unknown): 'CLIENT' | 'OPERATION' {
  const next = typeof value === 'string' ? value.trim().toUpperCase() : ''
  if (next !== 'CLIENT' && next !== 'OPERATION') throw new Error('CHANGE_ORIGIN_REQUIRED')
  return next
}

function requestEvidence(req: Request, body: Record<string, unknown>) {
  const ip = (req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0] ?? '').trim()
  const userAgent = (req.headers.get('user-agent') ?? '').trim()
  const requestId = (req.headers.get('x-request-id') ?? crypto.randomUUID()).trim()
  const reference = typeof body.admin_request_reference === 'string' ? body.admin_request_reference.trim().slice(0, 500) : ''
  if (!ip || !userAgent || !requestId) throw new Error('BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED')
  if (!reference) throw new Error('BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED')
  return { ip, userAgent, requestId, reference }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const body = await req.json() as Record<string, unknown>
    const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : ''
    const appointmentId = uuid(body.appointment_id, 'APPOINTMENT_ID_INVALID')
    const client = adminClient()
    const requirePermission = async (permission: string) => {
      if (!(await hasAdminPermission(admin.adminId, permission))) throw new Error('ADMIN_PERMISSION_DENIED')
    }

    if (action === 'LIST_SLOTS') {
      await requirePermission('AGENDA_MANAGE')
      const date = localDate(body.local_date)
      const { data, error } = await client.rpc('service_admin_list_reschedule_slots', {
        p_appointment_id: appointmentId,
        p_local_date: date,
      })
      if (error) throw new Error(error.message)
      return json({ appointment_id: appointmentId, local_date: date, slots: data ?? [] })
    }

    if (action === 'CREATE_HOLD') {
      await requirePermission('AGENDA_MANAGE')
      const requestedStartAt = isoDateTime(body.requested_start_at)
      const origin = changeOrigin(body.change_origin)
      const { data, error } = await client.rpc('service_admin_create_reschedule_hold', {
        p_appointment_id: appointmentId,
        p_requested_start_at: requestedStartAt,
        p_requested_at: new Date().toISOString(),
        p_change_origin: origin,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'APPLY_CUSTOMER_BALANCE') {
      await requirePermission('AGENDA_MANAGE')
      await requirePermission('FINANCE_MANAGE')
      const policyActionId = uuid(body.policy_action_id, 'POLICY_ACTION_ID_INVALID')
      const evidence = requestEvidence(req, body)
      const { data, error } = await client.rpc('service_apply_customer_balance_to_appointment', {
        p_appointment_id: appointmentId,
        p_policy_action_id: policyActionId,
        p_choice_origin: 'ADMIN_UI',
        p_admin_id: admin.adminId,
        p_ip: evidence.ip,
        p_user_agent: evidence.userAgent,
        p_request_id: evidence.requestId,
        p_admin_request_reference: evidence.reference,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'APPLY') {
      await requirePermission('AGENDA_MANAGE')
      const policyActionId = uuid(body.policy_action_id, 'POLICY_ACTION_ID_INVALID')
      const { data, error } = await client.rpc('service_admin_apply_reschedule', {
        p_policy_action_id: policyActionId,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'REGISTER_PENALTY') throw new Error('RESCHEDULE_PENALTY_PAYMENT_FLOW_REMOVED')
    throw new Error('RESCHEDULE_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_RESCHEDULE_ACTION_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : 400
    return json({ error: { code } }, status)
  }
})
