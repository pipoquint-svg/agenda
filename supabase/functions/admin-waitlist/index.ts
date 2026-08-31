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

function clean(value: string | null | undefined): string | null {
  const next = value?.trim() ?? ''
  return next || null
}

function uuid(value: unknown, code: string): string {
  const id = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) throw new Error(code)
  return id
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET' && req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()
    const requirePermission = async (permission: string) => {
      if (!(await hasAdminPermission(admin.adminId, permission))) throw new Error('ADMIN_PERMISSION_DENIED')
    }

    if (req.method === 'POST') {
      await requirePermission('WAITLIST_MANAGE')
      const body = await req.json().catch(() => ({})) as Record<string, unknown>
      if (body.action !== 'mark_contacted') throw new Error('WAITLIST_ACTION_INVALID')
      const { data, error } = await client.rpc('service_admin_mark_waitlist_contacted', {
        p_waitlist_entry_id: uuid(body.waitlist_entry_id, 'WAITLIST_ENTRY_ID_INVALID'),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    await requirePermission('WAITLIST_VIEW')
    const url = new URL(req.url)
    const action = clean(url.searchParams.get('action')) ?? 'list'

    if (action === 'services') {
      const { data, error } = await client.from('services')
        .select('id,name,operation_scope,sort_order')
        .eq('is_active', true)
        .eq('duration_mode', 'FIXED')
        .order('sort_order', { ascending: true })
        .order('name', { ascending: true })
      if (error) throw new Error('WAITLIST_SERVICES_LOAD_FAILED')
      return json({ services: data ?? [] })
    }

    if (action !== 'list') throw new Error('WAITLIST_ACTION_INVALID')
    const limitRaw = Number(url.searchParams.get('limit') ?? '50')
    const limit = Number.isInteger(limitRaw) ? Math.max(1, Math.min(limitRaw, 100)) : 50
    const serviceId = clean(url.searchParams.get('service_id'))
    const afterCreatedAt = clean(url.searchParams.get('after_created_at'))
    const afterId = clean(url.searchParams.get('after_id'))
    if ((afterCreatedAt === null) !== (afterId === null)) throw new Error('WAITLIST_CURSOR_INVALID')
    if (afterCreatedAt && Number.isNaN(new Date(afterCreatedAt).getTime())) throw new Error('WAITLIST_CURSOR_INVALID')

    const { data, error } = await client.rpc('service_admin_list_waitlist', {
      p_service_id: serviceId ? uuid(serviceId, 'WAITLIST_SERVICE_ID_INVALID') : null,
      p_limit: limit,
      p_after_created_at: afterCreatedAt,
      p_after_id: afterId ? uuid(afterId, 'WAITLIST_CURSOR_INVALID') : null,
      p_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)

    const rows = Array.isArray(data) ? data : []
    const items = rows.slice(0, limit)
    const hasMore = rows.length > limit
    const last = hasMore && items.length > 0 ? items[items.length - 1] as Record<string, unknown> : null
    return json({
      items,
      next_cursor: last ? { created_at: last.created_at, id: last.id } : null,
      page_size: limit,
      timezone: 'America/Sao_Paulo',
    })
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'WAITLIST_ADMIN_FAILED'
    const code = raw.match(/(ADMIN_[A-Z0-9_]+|WAITLIST_[A-Z0-9_]+)/)?.[1] ?? 'WAITLIST_ADMIN_FAILED'
    const status = code === 'ADMIN_PERMISSION_DENIED' || code.startsWith('ADMIN_AUTH_') ? 403
      : code === 'WAITLIST_ENTRY_NOT_FOUND' ? 404
      : 400
    return json({ error: { code } }, status)
  }
})