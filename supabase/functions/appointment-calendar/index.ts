import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
  'cache-control': 'no-store',
}

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function fail(status = 404): Response {
  // Public endpoint intentionally does not distinguish missing, invalid or unavailable codes.
  return response({ error: { code: 'CALENDAR_RESERVATION_UNAVAILABLE' } }, status)
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return fail(405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'appointment-calendar-read',
      limit: 30,
      windowSeconds: 60,
    })

    const url = new URL(req.url)
    const code = (url.searchParams.get('code') ?? '').trim().toUpperCase()
    if (!/^[A-F0-9]{12}$/.test(code)) return fail()

    const { data: appointment, error } = await client
      .from('appointments')
      .select('public_code,status,start_at,end_at,service_name_snapshot')
      .eq('public_code', code)
      .maybeSingle()

    if (error || !appointment) return fail()
    if (String(appointment.status ?? '').toUpperCase() !== 'CONFIRMED') return fail(410)

    const startAt = String(appointment.start_at ?? '')
    const endAt = String(appointment.end_at ?? '')
    const startMs = Date.parse(startAt)
    const endMs = Date.parse(endAt)
    if (!Number.isFinite(startMs) || !Number.isFinite(endMs) || endMs <= startMs) return fail()

    return response({
      public_code: code,
      service_name: String(appointment.service_name_snapshot ?? 'Reserva'),
      start_at: startAt,
      end_at: endAt,
      location: 'Rua Siena, 255 - Palhoça/SC',
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : ''
    if (code === 'RATE_LIMITED') return response({ error: { code: 'RATE_LIMITED' } }, 429)
    return response({ error: { code: 'CALENDAR_RESERVATION_UNAVAILABLE' } }, 503)
  }
})
