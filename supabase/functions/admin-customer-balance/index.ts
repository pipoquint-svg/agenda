import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

type Row = Record<string, unknown>

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function clean(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

function uuid(value: unknown, code: string): string {
  const id = clean(value) ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error(code)
  }
  return id
}

function authorshipEvidence(req: Request) {
  const ip = (
    req.headers.get('cf-connecting-ip') ??
    req.headers.get('x-real-ip') ??
    req.headers.get('x-forwarded-for')?.split(',')[0] ??
    ''
  ).trim()
  const userAgent = (req.headers.get('user-agent') ?? '').trim()
  const requestId = (req.headers.get('x-request-id') ?? crypto.randomUUID()).trim()
  if (!ip || !userAgent || !requestId) throw new Error('BALANCE_AUTHORSHIP_EVIDENCE_REQUIRED')
  return { ip, userAgent, requestId }
}

async function requireFinanceManage(req: Request) {
  const admin = await requireAdmin(req)
  if (!(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
  return admin
}

async function preview(appointmentId: string, adminId: string): Promise<Row> {
  const client = adminClient()
  const { data, error } = await client.rpc('service_admin_customer_balance_application_preview', {
    p_appointment_id: appointmentId,
    p_admin_id: adminId,
  })
  if (error) throw new Error(error.message)
  return (data ?? {}) as Row
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireFinanceManage(req)
    const url = new URL(req.url)

    if (req.method === 'GET') {
      const appointmentId = uuid(url.searchParams.get('appointment_id'), 'APPOINTMENT_ID_INVALID')
      return json(await preview(appointmentId, admin.adminId))
    }

    const body = await req.json().catch(() => ({})) as Row
    const action = (clean(body.action) ?? '').toUpperCase()
    if (action !== 'APPLY') return json({ error: { code: 'NOT_FOUND' } }, 404)

    const appointmentId = uuid(body.appointment_id, 'APPOINTMENT_ID_INVALID')
    const evidence = authorshipEvidence(req)
    const reference = clean(body.reference) ?? 'Gestão — aplicação de saldo do cliente'
    const client = adminClient()
    const { data, error } = await client.rpc('service_apply_customer_balance_to_appointment', {
      p_appointment_id: appointmentId,
      p_policy_action_id: null,
      p_choice_origin: 'ADMIN_UI',
      p_admin_id: admin.adminId,
      p_ip: evidence.ip,
      p_user_agent: evidence.userAgent,
      p_request_id: evidence.requestId,
      p_admin_request_reference: reference,
    })
    if (error) throw new Error(error.message)

    return json({ application: data, preview: await preview(appointmentId, admin.adminId) })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_CUSTOMER_BALANCE_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'APPOINTMENT_NOT_FOUND' ? 404
      : code === 'CUSTOMER_BALANCE_EMPTY' || code === 'NO_AMOUNT_DUE_FOR_BALANCE_APPLICATION' ? 409
      : 400
    return json({ error: { code } }, status)
  }
})
