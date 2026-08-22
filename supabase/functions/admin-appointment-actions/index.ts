import { adminClient, requireAdmin } from '../_shared/supabase.ts'

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

function uuid(value: unknown): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error('APPOINTMENT_ID_INVALID')
  }
  return next
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const body = await req.json()
    const action = typeof body?.action === 'string' ? body.action.trim().toUpperCase() : ''
    const appointmentId = uuid(body?.appointment_id)
    const client = adminClient()

    if (action === 'CANCEL') {
      const settlement = body?.settlement_choice === null || body?.settlement_choice === undefined || body?.settlement_choice === ''
        ? null
        : String(body.settlement_choice).trim().toUpperCase()
      if (settlement !== null && settlement !== 'REFUND' && settlement !== 'CREDIT') {
        throw new Error('INVALID_CANCELLATION_SETTLEMENT')
      }

      const reason = typeof body?.reason === 'string' ? body.reason.trim().slice(0, 500) : null
      const { data, error } = await client.rpc('service_admin_cancel_appointment', {
        p_appointment_id: appointmentId,
        p_settlement_choice: settlement,
        p_reason: reason || null,
        p_requested_at: new Date().toISOString(),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    throw new Error('APPOINTMENT_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_APPOINTMENT_ACTION_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401 : 400
    return json({ error: { code } }, status)
  }
})
