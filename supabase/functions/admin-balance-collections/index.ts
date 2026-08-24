import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
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

function evidence(req: Request) {
  const ip = (req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0] ?? '').trim()
  const userAgent = (req.headers.get('user-agent') ?? '').trim()
  const requestId = (req.headers.get('x-request-id') ?? crypto.randomUUID()).trim()
  if (!ip || !userAgent || !requestId) throw new Error('AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED')
  return { ip: ip.slice(0, 64), userAgent: userAgent.slice(0, 1000), requestId: requestId.slice(0, 200) }
}

async function cancelCollectionProvider(input: {
  collectionId: string
  adminId: string
  reason: 'SETTLED'
  evidence: ReturnType<typeof evidence>
}): Promise<{ ok: boolean; status: number; body: Record<string, unknown> }> {
  const base = Deno.env.get('SUPABASE_URL')?.trim().replace(/\/$/, '') ?? ''
  const secret = Deno.env.get('INTEGRATION_INTERNAL_SECRET')?.trim() ?? ''
  if (!base || !secret) throw new Error('BALANCE_PROVIDER_CANCEL_RUNTIME_MISSING')
  const response = await fetch(`${base}/functions/v1/balance-collection-provider-cancel`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', 'x-internal-secret': secret },
    body: JSON.stringify({
      collection_id: input.collectionId,
      reason: input.reason,
      admin_id: input.adminId,
      ip: input.evidence.ip,
      user_agent: input.evidence.userAgent,
      request_id: input.evidence.requestId,
    }),
  })
  const body = await response.json().catch(() => ({})) as Record<string, unknown>
  return { ok: response.ok, status: response.status, body }
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
      const mode = url.searchParams.get('mode')?.trim().toLowerCase() || 'open'
      if (scope && scope !== 'BLACKSHEEP' && scope !== 'SABRINA') throw new Error('ADMIN_OPERATION_SCOPE_INVALID')
      if (mode !== 'open' && mode !== 'overdue') throw new Error('ADMIN_BALANCE_MODE_INVALID')

      let query = client
        .from(mode === 'overdue' ? 'appointment_overdue_balances' : 'appointment_open_balances')
        .select('*')
        .order('start_at', { ascending: true })
        .limit(200)
      if (scope) query = query.eq('operation_scope', scope)
      const { data, error } = await query
      if (error) throw new Error(mode === 'overdue' ? 'ADMIN_OVERDUE_BALANCES_QUERY_FAILED' : 'ADMIN_OPEN_BALANCES_QUERY_FAILED')
      return json({ mode, rows: data ?? [], generated_at: new Date().toISOString() })
    }

    if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    if (!(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : ''
    const appointmentId = uuid(body.appointment_id)

    if (action === 'REISSUE') {
      const { data, error } = await client.rpc('service_admin_reissue_balance_collection', {
        p_appointment_id: appointmentId,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json({ data }, 201)
    }

    if (action === 'RECORD_MANUAL_PAYMENT') {
      const amount = Number(body.amount)
      const method = typeof body.method === 'string' ? body.method.trim().toUpperCase() : ''
      if (!Number.isFinite(amount) || amount <= 0) throw new Error('MANUAL_PAYMENT_AMOUNT_INVALID')
      if (method !== 'CASH' && method !== 'OTHER') throw new Error('MANUAL_PAYMENT_METHOD_INVALID')
      const requestEvidence = evidence(req)
      const { data, error } = await client.rpc('service_record_manual_contract_payment', {
        p_appointment_id: appointmentId,
        p_admin_id: admin.adminId,
        p_amount: Math.round(amount * 100) / 100,
        p_method: method,
        p_ip: requestEvidence.ip,
        p_user_agent: requestEvidence.userAgent,
        p_request_id: requestEvidence.requestId,
      })
      if (error) throw new Error(error.message)
      const result = data && typeof data === 'object' ? data as Record<string, unknown> : {}
      const activeCollectionId = typeof result.active_collection_id === 'string' ? result.active_collection_id : null
      const settled = result.settled === true

      // Human decision deliberately preserved: a partial in-person payment changes the
      // reservation balance, but we do not cancel/reissue the existing provider charge
      // until the commercial policy for that case is explicitly defined.
      if (activeCollectionId && !settled) {
        return json({
          data: result,
          partial_collection_policy_pending: true,
          existing_collection_preserved: true,
        }, 201)
      }

      // Full in-person settlement must invalidate any still-payable provider collection.
      if (activeCollectionId && settled) {
        const cancellation = await cancelCollectionProvider({
          collectionId: activeCollectionId,
          adminId: admin.adminId,
          reason: 'SETTLED',
          evidence: requestEvidence,
        })
        if (!cancellation.ok) {
          return json({
            error: { code: 'BALANCE_PROVIDER_CANCEL_DIVERGENCE' },
            payment_recorded: true,
            provider_cleanup_pending: true,
            data: result,
          }, 409)
        }
      }

      return json({ data: result })
    }

    throw new Error('ADMIN_BALANCE_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_BALANCE_COLLECTION_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'BALANCE_COLLECTION_STILL_ACTIVE' ? 409
      : code === 'BALANCE_COLLECTION_REISSUE_NOT_ALLOWED' ? 409
      : code === 'BALANCE_COLLECTION_REISSUE_LIMIT_REACHED' ? 409
      : code === 'BALANCE_PROVIDER_CLEANUP_PENDING' ? 409
      : code === 'BALANCE_COLLECTION_NOT_DUE' ? 409
      : code === 'APPOINTMENT_ALREADY_SETTLED' ? 409
      : 400
    return json({ error: { code } }, status)
  }
})
