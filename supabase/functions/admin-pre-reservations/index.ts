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

function clean(value: unknown): string | null {
  const next = typeof value === 'string' ? value.trim() : ''
  return next || null
}

function uuid(value: unknown, code: string): string {
  const id = clean(value) ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error(code)
  }
  return id
}

function iso(value: unknown, code: string): string {
  const raw = clean(value)
  if (!raw) throw new Error(code)
  const parsed = new Date(raw)
  if (Number.isNaN(parsed.getTime())) throw new Error(code)
  return parsed.toISOString()
}

async function sendAppointmentConfirmation(appointmentId: string, entityVersion: number): Promise<Record<string, unknown>> {
  const baseUrl = (Deno.env.get('SUPABASE_URL') ?? '').trim().replace(/\/$/, '')
  const internalSecret = (Deno.env.get('INTEGRATION_INTERNAL_SECRET') ?? '').trim()
  if (!baseUrl || !internalSecret) throw new Error('CONFIRMATION_EMAIL_NOT_CONFIGURED')
  const response = await fetch(`${baseUrl}/functions/v1/email-send`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-internal-secret': internalSecret },
    body: JSON.stringify({ appointment_id: appointmentId, entity_version: entityVersion, reason: 'ADMIN_MANUAL_BOOKING' }),
  })
  const payload = await response.json().catch(() => ({})) as Record<string, unknown>
  if (!response.ok) {
    const nested = payload.error && typeof payload.error === 'object'
      ? (payload.error as Record<string, unknown>).code
      : null
    throw new Error(`CONFIRMATION_EMAIL_FAILED:${typeof nested === 'string' ? nested : response.status}`)
  }
  return payload
}

function redactFinance(value: unknown): unknown {
  const blocked = new Set([
    'commercial_value', 'billing_mode', 'invoice_due_days', 'invoice_due_basis',
    'invoice_due_base_at', 'invoice_due_at', 'financial_status',
  ])

  const walk = (current: unknown): unknown => {
    if (Array.isArray(current)) return current.map(walk)
    if (!current || typeof current !== 'object') return current
    const result: Record<string, unknown> = {}
    for (const [key, nested] of Object.entries(current as Record<string, unknown>)) {
      if (!blocked.has(key)) result[key] = walk(nested)
    }
    return result
  }

  return walk(value)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, 'AGENDA_MANAGE'))) {
      throw new Error('ADMIN_PERMISSION_DENIED')
    }

    const canViewFinance = await hasAdminPermission(admin.adminId, 'FINANCE_VIEW')
    const client = adminClient()
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = (clean(body.action) ?? '').toUpperCase()

    if (action === 'CREATE') {
      const durationBlocks = body.duration_blocks === null || body.duration_blocks === undefined
        ? null
        : Number(body.duration_blocks)
      const peopleCount = body.people_count === null || body.people_count === undefined
        ? 1
        : Number(body.people_count)

      if (durationBlocks !== null && (!Number.isInteger(durationBlocks) || durationBlocks < 1)) {
        throw new Error('INVALID_DURATION_BLOCKS')
      }
      if (!Number.isInteger(peopleCount) || peopleCount < 1) throw new Error('INVALID_PEOPLE_COUNT')
      if (body.extra_selections !== undefined && !Array.isArray(body.extra_selections)) {
        throw new Error('INVALID_EXTRA')
      }

      const { data, error } = await client.rpc('service_admin_create_pre_reservation', {
        p_customer_id: uuid(body.customer_id, 'CUSTOMER_ID_INVALID'),
        p_service_id: uuid(body.service_id, 'SERVICE_ID_INVALID'),
        p_service_employee_id: uuid(body.service_employee_id, 'SERVICE_EMPLOYEE_ID_INVALID'),
        p_requested_start_at: iso(body.requested_start_at, 'REQUESTED_START_AT_INVALID'),
        p_admin_id: admin.adminId,
        p_duration_blocks: durationBlocks,
        p_extra_selections: body.extra_selections ?? [],
        p_people_count: peopleCount,
        p_notes: clean(body.notes),
      })
      if (error) throw new Error(error.message)
      return json({ data: canViewFinance ? data : redactFinance(data) })
    }

    if (action === 'CONFIRM') {
      const { data, error } = await client.rpc('service_admin_confirm_pre_reservation', {
        p_pre_reservation_id: uuid(body.pre_reservation_id, 'PRE_RESERVATION_ID_INVALID'),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      const appointmentId = data && typeof data === 'object'
        ? clean((data as Record<string, unknown>).appointment_id)
        : null
      if (!appointmentId) throw new Error('CONFIRMED_APPOINTMENT_ID_MISSING')
      const { data: appointment, error: appointmentError } = await client
        .from('appointments').select('version').eq('id', appointmentId).maybeSingle()
      if (appointmentError || !appointment) throw new Error('CONFIRMED_APPOINTMENT_LOOKUP_FAILED')
      const confirmation = await sendAppointmentConfirmation(appointmentId, Number(appointment.version))
      return json({ data: canViewFinance ? data : redactFinance(data), confirmation })
    }

    if (action === 'CANCEL') {
      const { data, error } = await client.rpc('service_admin_cancel_pre_reservation', {
        p_pre_reservation_id: uuid(body.pre_reservation_id, 'PRE_RESERVATION_ID_INVALID'),
        p_admin_id: admin.adminId,
        p_reason: clean(body.reason),
      })
      if (error) throw new Error(error.message)
      return json({ data })
    }

    throw new Error('PRE_RESERVATION_ACTION_INVALID')
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'PRE_RESERVATION_ACTION_FAILED'
    const code = raw.split(':')[0]
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED'
      ? 403
      : code === 'SLOT_NO_LONGER_AVAILABLE' || code === 'MAX_ACTIVE_PREBOOKS_REACHED'
      ? 409
      : code === 'CONFIRMATION_EMAIL_FAILED' || code === 'CONFIRMATION_EMAIL_NOT_CONFIGURED'
      ? 502
      : 400
    return json({ error: { code } }, status)
  }
})
