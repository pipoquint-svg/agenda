import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, 'DASHBOARD_VIEW'))) {
      throw new Error('ADMIN_PERMISSION_DENIED')
    }

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
    return json(data)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_DASHBOARD_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
