import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

const financePendingKinds = new Set([
  'PAYMENT_AWAITING',
  'BALANCE_DUE_PENDING',
  'RESCHEDULE_PENALTY_PENDING',
  'CANCELLATION_REFUND_PENDING',
])

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function requiredIso(url: URL, key: string): string {
  const raw = url.searchParams.get(key)?.trim() ?? ''
  const parsed = new Date(raw)
  if (!raw) throw new Error(`ADMIN_${key.toUpperCase()}_REQUIRED`)
  if (Number.isNaN(parsed.getTime())) throw new Error(`ADMIN_${key.toUpperCase()}_INVALID`)
  return parsed.toISOString()
}

function redactFinancialPendingItems(data: unknown): unknown {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return data
  const output = { ...(data as Record<string, unknown>) }
  if (Array.isArray(output.pending_items)) {
    output.pending_items = output.pending_items.filter((item) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) return true
      const kind = String((item as Record<string, unknown>).kind ?? '')
      return !financePendingKinds.has(kind)
    })
  }
  return output
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, 'DASHBOARD_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const canSeeFinance = await hasAdminPermission(admin.adminId, 'FINANCE_VIEW')

    const url = new URL(req.url)
    const scopeRaw = url.searchParams.get('operation_scope')?.trim().toUpperCase() ?? ''
    const operationScope = scopeRaw || null
    if (operationScope !== null && operationScope !== 'BLACKSHEEP' && operationScope !== 'SABRINA') {
      throw new Error('ADMIN_DASHBOARD_OPERATION_SCOPE_INVALID')
    }

    const client = adminClient()
    const { data, error } = await client.rpc('service_admin_get_dashboard', {
      p_start_at: requiredIso(url, 'start_at'),
      p_end_at: requiredIso(url, 'end_at'),
      p_operation_scope: operationScope,
    })
    if (error) throw new Error(error.message)

    const output = data && typeof data === 'object' && !Array.isArray(data)
      ? { ...(data as Record<string, unknown>) }
      : { pending_items: [] }

    if (canSeeFinance) {
      let openQuery = client.from('appointment_open_balances').select('*').order('start_at', { ascending: true }).limit(200)
      if (operationScope) openQuery = openQuery.eq('operation_scope', operationScope)
      const { data: balances, error: balanceError } = await openQuery
      if (balanceError) throw new Error('ADMIN_OPEN_BALANCES_QUERY_FAILED')

      const current = Array.isArray(output.pending_items) ? output.pending_items : []
      output.pending_items = [
        ...current,
        ...(balances ?? []).map((row) => ({
          kind: 'BALANCE_DUE_PENDING',
          entity_type: 'APPOINTMENT',
          entity_id: row.appointment_id,
          appointment_id: row.appointment_id,
          customer_id: row.customer_id,
          customer_name: row.customer_name,
          service_id: row.service_id,
          service_name: row.service_name,
          operation_scope: row.operation_scope,
          status: row.financial_status,
          start_at: row.start_at,
          amount_paid: row.paid_value,
          amount_due: row.balance_value,
          total_value: row.total_value,
          collection_id: row.active_collection_id,
          collection_sequence: row.collection_sequence,
          expires_at: row.collection_expires_at,
        })),
      ]
      return json(output)
    }

    return json(redactFinancialPendingItems(output))
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_DASHBOARD_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
