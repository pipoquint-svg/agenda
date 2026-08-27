import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function boundedInt(url: URL, key: string, fallback: number, min: number, max: number): number {
  const raw = url.searchParams.get(key)
  if (!raw) return fallback
  const value = Number(raw)
  if (!Number.isInteger(value) || value < min || value > max) throw new Error(`AUDIT_${key.toUpperCase()}_INVALID`)
  return value
}

function optionalIso(url: URL, key: string): string | null {
  const raw = url.searchParams.get(key)?.trim() ?? ''
  if (!raw) return null
  const parsed = new Date(raw)
  if (Number.isNaN(parsed.getTime())) throw new Error(`AUDIT_${key.toUpperCase()}_INVALID`)
  return parsed.toISOString()
}

function optionalUuid(url: URL, key: string): string | null {
  const raw = url.searchParams.get(key)?.trim() ?? ''
  if (!raw) return null
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(raw)) throw new Error(`AUDIT_${key.toUpperCase()}_INVALID`)
  return raw
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    await requireAdminPermission(req, 'AUDIT_VIEW')
    const url = new URL(req.url)
    const page = boundedInt(url, 'page', 1, 1, 100000)
    const limit = boundedInt(url, 'limit', 50, 1, 100)
    const startAt = optionalIso(url, 'start_at')
    const endAt = optionalIso(url, 'end_at')
    if (startAt && endAt && Date.parse(endAt) <= Date.parse(startAt)) throw new Error('AUDIT_PERIOD_INVALID')

    const actorId = optionalUuid(url, 'actor')
    const entityId = optionalUuid(url, 'entity_id')
    const entityType = url.searchParams.get('entity')?.trim().toUpperCase() || url.searchParams.get('entity_type')?.trim().toUpperCase() || ''
    const action = url.searchParams.get('action')?.trim().toUpperCase() ?? ''
    const offset = (page - 1) * limit
    const client = adminClient()

    let query = client
      .from('audit_logs')
      .select('id,admin_user_id,entity_type,entity_id,action,origin,request_id,created_at', { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(offset, offset + limit - 1)

    if (startAt) query = query.gte('created_at', startAt)
    if (endAt) query = query.lt('created_at', endAt)
    if (actorId) query = query.eq('admin_user_id', actorId)
    if (entityType) query = query.eq('entity_type', entityType)
    if (entityId) query = query.eq('entity_id', entityId)
    if (action) query = query.eq('action', action)

    const { data, error, count } = await query
    if (error) throw new Error('ADMIN_AUDIT_QUERY_FAILED')

    const actorIds = [...new Set((data ?? []).map((row) => row.admin_user_id).filter(Boolean).map(String))]
    const actors = new Map<string, { id: string; display_name: string | null; role: string | null }>()
    if (actorIds.length) {
      const { data: admins, error: adminError } = await client
        .from('admin_users')
        .select('id,display_name,role')
        .in('id', actorIds)
      if (adminError) throw new Error('ADMIN_AUDIT_ACTOR_QUERY_FAILED')
      for (const admin of admins ?? []) actors.set(String(admin.id), { id: String(admin.id), display_name: admin.display_name ?? null, role: admin.role ?? null })
    }

    const total = count ?? data?.length ?? 0
    return json({
      filters: {
        start_at: startAt,
        end_at: endAt,
        actor: actorId,
        entity_type: entityType || null,
        entity_id: entityId,
        action: action || null,
      },
      pagination: { page, limit, total, total_pages: total === 0 ? 0 : Math.ceil(total / limit) },
      events: (data ?? []).map((row) => ({
        id: row.id,
        action: row.action,
        entityType: row.entity_type,
        entityId: row.entity_id,
        occurredAt: row.created_at,
        actorId: row.admin_user_id,
        actor: row.admin_user_id ? actors.get(String(row.admin_user_id)) ?? null : null,
        metadata: {
          origin: row.origin ?? null,
          request_id: row.request_id ?? null,
        },
      })),
      redaction: {
        before_after_included: false,
        reason: 'General audit listing exposes event metadata only. Entity-specific evidence remains in dedicated audited views.',
      },
    })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_AUDIT_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
