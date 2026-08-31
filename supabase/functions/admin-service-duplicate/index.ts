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

function uuid(value: unknown): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error('SERVICE_ID_INVALID')
  }
  return next
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const can = (permission: string) => hasAdminPermission(admin.adminId, permission)
    if (!(await can('SERVICES_MANAGE')) || !(await can('FINANCE_MANAGE'))) {
      throw new Error('ADMIN_PERMISSION_DENIED')
    }

    const body = await req.json()
    const serviceId = uuid(body?.service_id)
    const name = text(body?.name)
    const slug = text(body?.slug)
    if (!name) throw new Error('SERVICE_DUPLICATE_NAME_REQUIRED')
    if (!slug || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) throw new Error('SERVICE_SLUG_INVALID')

    const { data, error } = await adminClient().rpc('service_admin_duplicate_service_audited', {
      p_service_id: serviceId,
      p_name: name,
      p_slug: slug,
      p_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return json(data, 201)
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'SERVICE_DUPLICATE_FAILED'
    const known = [
      'ADMIN_PERMISSION_DENIED',
      'SERVICE_NOT_FOUND',
      'SERVICE_ID_INVALID',
      'SERVICE_DUPLICATE_NAME_REQUIRED',
      'SERVICE_SLUG_INVALID',
      'SERVICE_SLUG_ALREADY_EXISTS',
    ].find((code) => raw.includes(code))
    const code = known ?? (raw.startsWith('ADMIN_AUTH_') || raw.includes('ADMIN_ACCESS_DENIED') ? 'ADMIN_ACCESS_DENIED' : 'SERVICE_DUPLICATE_FAILED')
    const status = code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED'
        ? 403
        : code === 'SERVICE_NOT_FOUND'
          ? 404
          : code === 'SERVICE_SLUG_ALREADY_EXISTS'
            ? 409
            : 400
    return json({ error: { code } }, status)
  }
})
