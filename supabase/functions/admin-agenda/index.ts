import { adminClient, requireAdmin } from '../_shared/supabase.ts'

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

function clean(value: string | null): string | null {
  const next = value?.trim() ?? ''
  return next || null
}

function requiredIso(url: URL, key: string): string {
  const raw = clean(url.searchParams.get(key))
  if (!raw) throw new Error(`ADMIN_${key.toUpperCase()}_REQUIRED`)
  const parsed = new Date(raw)
  if (Number.isNaN(parsed.getTime())) throw new Error(`ADMIN_${key.toUpperCase()}_INVALID`)
  return parsed.toISOString()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    await requireAdmin(req)
    const client = adminClient()
    const url = new URL(req.url)
    const action = clean(url.searchParams.get('action')) ?? 'agenda'

    if (action === 'appointment') {
      const id = clean(url.searchParams.get('id'))
      if (!id || !/^[0-9a-f-]{36}$/i.test(id)) throw new Error('APPOINTMENT_ID_INVALID')
      const { data, error } = await client.rpc('service_admin_get_appointment', { p_appointment_id: id })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'amelia') {
      const startAt = requiredIso(url, 'start_at')
      const endAt = requiredIso(url, 'end_at')
      const { data, error } = await client.rpc('service_admin_list_amelia_history', {
        p_start_at: startAt,
        p_end_at: endAt,
        p_search: clean(url.searchParams.get('search')),
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action !== 'agenda') throw new Error('ADMIN_ACTION_INVALID')

    const startAt = requiredIso(url, 'start_at')
    const endAt = requiredIso(url, 'end_at')
    const { data, error } = await client.rpc('service_admin_list_agenda', {
      p_start_at: startAt,
      p_end_at: endAt,
    })
    if (error) throw new Error(error.message)
    return json(data)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_AGENDA_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401 : 400
    return json({ error: { code } }, status)
  }
})
