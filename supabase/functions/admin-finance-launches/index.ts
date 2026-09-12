import { adminClient, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, OPTIONS',
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const url = new URL(req.url)
    const from = clean(url.searchParams.get('from'))
    const to = clean(url.searchParams.get('to'))
    const operationScope = clean(url.searchParams.get('operation_scope'))

    if (!from || !to || !Number.isFinite(Date.parse(from)) || !Number.isFinite(Date.parse(to))) {
      throw new Error('FINANCE_PERIOD_INVALID')
    }

    const client = adminClient()
    const { data, error } = await client.rpc('service_admin_finance_launches_range', {
      p_from: new Date(from).toISOString(),
      p_to: new Date(to).toISOString(),
      p_operation_scope: !operationScope || operationScope.toUpperCase() === 'ALL' ? null : operationScope.toUpperCase(),
      p_admin_id: admin.adminId,
    })

    if (error) throw new Error(error.message)
    return json((data ?? {}) as Row)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_FINANCE_LAUNCHES_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : 400
    return json({ error: { code } }, status)
  }
})
