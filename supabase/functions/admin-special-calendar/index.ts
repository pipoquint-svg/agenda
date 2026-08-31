import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function uuid(value: unknown, code = 'SPECIAL_DATE_ID_INVALID'): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string') throw new Error(code)
  const next = value.trim()
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error(code)
  }
  return next
}

function year(value: string | null, fallback: number): number {
  if (!value) return fallback
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 2000 || parsed > 2200) throw new Error('SPECIAL_CALENDAR_YEAR_RANGE_INVALID')
  return parsed
}

function localDate(value: unknown): string {
  const next = text(value)
  if (!/^\d{4}-\d{2}-\d{2}$/.test(next)) throw new Error('SPECIAL_DATE_DATE_INVALID')
  const parsed = new Date(`${next}T12:00:00Z`)
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== next) throw new Error('SPECIAL_DATE_DATE_INVALID')
  return next
}

function enumValue(value: unknown, allowed: string[], code: string): string {
  const next = text(value).toUpperCase()
  if (!allowed.includes(next)) throw new Error(code)
  return next
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST', 'PUT', 'DELETE'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'SERVICES_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const url = new URL(req.url)
      const currentYear = new Date().getUTCFullYear()
      const startYear = year(url.searchParams.get('start_year'), currentYear)
      const endYear = year(url.searchParams.get('end_year'), startYear)
      if (endYear < startYear || endYear - startYear > 20) throw new Error('SPECIAL_CALENDAR_YEAR_RANGE_INVALID')

      const { data, error } = await client.rpc('service_admin_list_special_calendar_dates', {
        p_start_year: startYear,
        p_end_year: endYear,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json({ dates: Array.isArray(data) ? data : [] })
    }

    if (!(await hasAdminPermission(admin.adminId, 'SERVICES_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')

    const body = await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('SPECIAL_DATE_PAYLOAD_INVALID')
    const record = body as Record<string, unknown>

    if (req.method === 'DELETE') {
      const id = uuid(record.id)
      if (!id) throw new Error('SPECIAL_DATE_ID_INVALID')
      const { data, error } = await client.rpc('service_admin_delete_special_calendar_date_audited', {
        p_id: id,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    const id = req.method === 'PUT' ? uuid(record.id) : null
    if (req.method === 'PUT' && !id) throw new Error('SPECIAL_DATE_ID_INVALID')
    const date = localDate(record.local_date)
    const name = text(record.name)
    if (!name || name.length > 160) throw new Error('SPECIAL_DATE_NAME_INVALID')
    const category = enumValue(record.category, ['NATIONAL', 'STATE', 'MUNICIPAL', 'FACULTATIVE', 'MANUAL'], 'SPECIAL_DATE_CATEGORY_INVALID')
    const treatment = enumValue(record.treatment, ['SURCHARGE', 'NORMAL', 'CLOSED'], 'SPECIAL_DATE_TREATMENT_INVALID')
    const sourceStatus = enumValue(record.source_status, ['OFFICIAL', 'PROJECTED', 'MANUAL'], 'SPECIAL_DATE_SOURCE_STATUS_INVALID')
    const notes = text(record.notes) || null

    const { data, error } = await client.rpc('service_admin_upsert_special_calendar_date_audited', {
      p_id: id,
      p_local_date: date,
      p_name: name,
      p_category: category,
      p_treatment: treatment,
      p_source_status: sourceStatus,
      p_notes: notes,
      p_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return json(data, req.method === 'POST' ? 201 : 200)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'SPECIAL_CALENDAR_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED'
        ? 403
        : code === 'SPECIAL_DATE_ALREADY_EXISTS'
          ? 409
          : code === 'SPECIAL_DATE_NOT_FOUND'
            ? 404
            : 400
    return json({ error: { code } }, status)
  }
})
