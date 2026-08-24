import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown): string {
  const text = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(text)) {
    throw new Error('APPOINTMENT_ID_INVALID')
  }
  return text
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'FINANCE_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const url = new URL(req.url)
      const scope = url.searchParams.get('operation_scope')?.trim().toUpperCase() ?? ''
      if (scope && scope !== 'BLACKSHEEP' && scope !== 'SABRINA') throw new Error('ADMIN_OPERATION_SCOPE_INVALID')

      let query = client
        .from('appointment_open_balances')
        .select('*')
        .order('start_at', { ascending: true })
        .limit(200)
      if (scope) query = query.eq('operation_scope', scope)
      const { data, error } = await query
      if (error) throw new Error('ADMIN_OPEN_BALANCES_QUERY_FAILED')
      return json({ rows: data ?? [], generated_at: new Date().toISOString() })
    }

    if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    if (!(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')

    const body = await req.json().catch(() => ({}))
    const action = typeof body?.action === 'string' ? body.action.trim().toUpperCase() : ''
    if (action !== 'REISSUE') throw new Error('ADMIN_BALANCE_ACTION_INVALID')

    const appointmentId = uuid(body?.appointment_id)
    const { data, error } = await client.rpc('service_admin_reissue_balance_collection', {
      p_appointment_id: appointmentId,
      p_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return json({ data }, 201)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_BALANCE_COLLECTION_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'BALANCE_COLLECTION_NOT_DUE' ? 409
      : 400
    return json({ error: { code } }, status)
  }
})
