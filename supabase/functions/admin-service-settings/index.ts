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

function operationScope(value: unknown): 'SABRINA' | 'BLACKSHEEP' {
  const scope = text(value).toUpperCase()
  if (scope !== 'SABRINA' && scope !== 'BLACKSHEEP') throw new Error('SERVICE_OPERATION_SCOPE_INVALID')
  return scope
}

function redactCommercial(data: unknown): unknown {
  if (Array.isArray(data)) return data.map((item) => redactCommercial(item))
  if (!data || typeof data !== 'object') return data
  const item = { ...(data as Record<string, unknown>) }
  delete item.base_price
  delete item.price_per_block
  delete item.change_policy
  if (Array.isArray(item.pricing_tiers)) {
    item.pricing_tiers = item.pricing_tiers.map((tier) => {
      if (!tier || typeof tier !== 'object' || Array.isArray(tier)) return tier
      const next = { ...(tier as Record<string, unknown>) }
      delete next.price_per_block
      return next
    })
  }
  return item
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST', 'PUT', 'DELETE'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const can = (permission: string) => hasAdminPermission(admin.adminId, permission)
    const requirePermission = async (permission: string) => {
      if (!(await can(permission))) throw new Error('ADMIN_PERMISSION_DENIED')
    }
    const client = adminClient()

    if (req.method === 'GET') {
      await requirePermission('SERVICES_VIEW')
      const canSeeFinance = await can('FINANCE_VIEW')
      const { data, error } = await client.rpc('service_admin_list_service_settings')
      if (error) throw new Error(error.message)
      return json({ services: canSeeFinance ? data : redactCommercial(data) })
    }

    await requirePermission('SERVICES_MANAGE')
    const body = await req.json()

    if (req.method === 'POST') {
      const canManageFinance = await can('FINANCE_MANAGE')
      const requestedBasePrice = numeric(body?.base_price ?? 0, 'base_price') ?? 0
      if (requestedBasePrice !== 0 && !canManageFinance) throw new Error('ADMIN_PERMISSION_DENIED')
      const { data, error } = await client.rpc('service_admin_create_service_audited', {
        p_name: text(body?.name),
        p_slug: text(body?.slug),
        p_operation_scope: operationScope(body?.operation_scope),
        p_short_description: text(body?.short_description) || null,
        p_full_description: text(body?.full_description) || null,
        p_duration_mode: body?.duration_mode === 'BLOCKS' ? 'BLOCKS' : 'FIXED',
        p_base_duration_minutes: integer(body?.base_duration_minutes ?? 60, 'base_duration_minutes'),
        p_base_price: requestedBasePrice,
        p_buffer_before_minutes: integer(body?.buffer_before_minutes ?? 0, 'buffer_before_minutes'),
        p_buffer_after_minutes: integer(body?.buffer_after_minutes ?? 0, 'buffer_after_minutes'),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data, 201)
    }

    const serviceId = uuid(body?.service_id)

    if (req.method === 'DELETE') {
      const { data, error } = await client.rpc('service_admin_remove_service_audited', {
        p_service_id: serviceId,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    const action = typeof body?.action === 'string' ? body.action : ''

    if (action === 'CATALOG') {
      const { data, error } = await client.rpc('service_admin_update_catalog_audited', {
        p_service_id: serviceId,
        p_name: text(body?.name),
        p_slug: text(body?.slug),
        p_operation_scope: operationScope(body?.operation_scope),
        p_short_description: text(body?.short_description) || null,
        p_full_description: text(body?.full_description) || null,
        p_is_active: body?.is_active !== false,
        p_sort_order: integer(body?.sort_order ?? 0, 'sort_order'),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'CUSTOM_FIELDS') {
      const fields = Array.isArray(body?.fields) ? body.fields : null
      if (!fields) throw new Error('SERVICE_FIELDS_INVALID')
      const { data, error } = await client.rpc('service_admin_replace_custom_fields_audited', {
        p_service_id: serviceId,
        p_fields: fields,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'OPERATION_SCOPE') {
      const { data, error } = await client.rpc('service_admin_update_operation_scope', {
        p_service_id: serviceId,
        p_operation_scope: operationScope(body?.operation_scope),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'TIMING') {
      const mode = body?.duration_mode === 'BLOCKS' ? 'BLOCKS' : body?.duration_mode === 'FIXED' ? 'FIXED' : null
      if (!mode) throw new Error('INVALID_DURATION_MODE')
      const canSeeFinance = await can('FINANCE_VIEW')

      const { data, error } = await client.rpc('service_admin_update_timing_audited', {
        p_service_id: serviceId,
        p_duration_mode: mode,
        p_base_duration_minutes: integer(body.base_duration_minutes, 'base_duration_minutes'),
        p_booking_block_minutes: integer(body.booking_block_minutes, 'booking_block_minutes', mode === 'FIXED'),
        p_minimum_booking_blocks: integer(body.minimum_booking_blocks, 'minimum_booking_blocks', mode === 'FIXED'),
        p_maximum_booking_blocks: integer(body.maximum_booking_blocks, 'maximum_booking_blocks', mode === 'FIXED'),
        p_base_price: numeric(body.base_price, 'base_price', true),
        p_price_per_block: numeric(body.price_per_block, 'price_per_block', true),
        p_buffer_before_minutes: integer(body.buffer_before_minutes, 'buffer_before_minutes'),
        p_buffer_after_minutes: integer(body.buffer_after_minutes, 'buffer_after_minutes'),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(canSeeFinance ? data : redactCommercial(data))
    }

    if (action === 'DURATION_CONFIGURATION') {
      await requirePermission('FINANCE_MANAGE')
      const tiers = Array.isArray(body?.pricing_tiers) ? body.pricing_tiers : null
      const presets = Array.isArray(body?.duration_presets) ? body.duration_presets : null
      if (!tiers || !presets) throw new Error('INVALID_DURATION_CONFIGURATION')

      const { data, error } = await client.rpc('service_admin_replace_duration_configuration_audited', {
        p_service_id: serviceId,
        p_pricing_tiers: tiers,
        p_duration_presets: presets,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'CHANGE_POLICY') {
      await requirePermission('FINANCE_MANAGE')
      if (!body?.policy || typeof body.policy !== 'object' || Array.isArray(body.policy)) {
        throw new Error('INVALID_CHANGE_POLICY')
      }
      const { data, error } = await client.rpc('service_admin_upsert_change_policy_audited', {
        p_service_id: serviceId,
        p_policy: body.policy,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    throw new Error('SERVICE_SETTINGS_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'SERVICE_SETTINGS_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
