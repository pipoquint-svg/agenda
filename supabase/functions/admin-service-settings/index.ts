import { adminClient, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, PUT, OPTIONS',
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

function integer(value: unknown, field: string, nullable = false): number | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  const next = Number(value)
  if (!Number.isInteger(next)) throw new Error(`${field.toUpperCase()}_INVALID`)
  return next
}

function numeric(value: unknown, field: string, nullable = false): number | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  const next = Number(value)
  if (!Number.isFinite(next)) throw new Error(`${field.toUpperCase()}_INVALID`)
  return next
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      const { data, error } = await client.rpc('service_admin_list_service_settings')
      if (error) throw new Error(error.message)
      return json({ services: data })
    }

    const body = await req.json()
    const serviceId = uuid(body?.service_id)
    const action = typeof body?.action === 'string' ? body.action : ''

    if (action === 'TIMING') {
      const mode = body?.duration_mode === 'BLOCKS' ? 'BLOCKS' : body?.duration_mode === 'FIXED' ? 'FIXED' : null
      if (!mode) throw new Error('INVALID_DURATION_MODE')

      const { data, error } = await client.rpc('service_admin_update_timing', {
        p_service_id: serviceId,
        p_duration_mode: mode,
        p_base_duration_minutes: integer(body.base_duration_minutes, 'base_duration_minutes'),
        p_booking_block_minutes: integer(body.booking_block_minutes, 'booking_block_minutes', mode === 'FIXED'),
        p_minimum_booking_blocks: integer(body.minimum_booking_blocks, 'minimum_booking_blocks', mode === 'FIXED'),
        p_maximum_booking_blocks: integer(body.maximum_booking_blocks, 'maximum_booking_blocks', mode === 'FIXED'),
        p_base_price: numeric(body.base_price, 'base_price'),
        p_price_per_block: numeric(body.price_per_block, 'price_per_block', mode === 'FIXED'),
        p_buffer_before_minutes: integer(body.buffer_before_minutes, 'buffer_before_minutes'),
        p_buffer_after_minutes: integer(body.buffer_after_minutes, 'buffer_after_minutes'),
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'DURATION_CONFIGURATION') {
      const tiers = Array.isArray(body?.pricing_tiers) ? body.pricing_tiers : null
      const presets = Array.isArray(body?.duration_presets) ? body.duration_presets : null
      if (!tiers || !presets) throw new Error('INVALID_DURATION_CONFIGURATION')

      const { data, error } = await client.rpc('service_admin_replace_duration_configuration', {
        p_service_id: serviceId,
        p_pricing_tiers: tiers,
        p_duration_presets: presets,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    throw new Error('SERVICE_SETTINGS_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'SERVICE_SETTINGS_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401 : 400
    return json({ error: { code } }, status)
  }
})
