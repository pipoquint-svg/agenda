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

function uuid(value: unknown, code = 'ID_INVALID'): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error(code)
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
  for (const key of ['base_price', 'price_per_block', 'price_per_extra_person', 'price', 'change_policy']) delete item[key]
  if (Array.isArray(item.pricing_tiers)) item.pricing_tiers = redactCommercial(item.pricing_tiers)
  if (Array.isArray(item.day_time_pricing_rules)) item.day_time_pricing_rules = (item.day_time_pricing_rules as unknown[]).map((rule) => {
    if (!rule || typeof rule !== 'object' || Array.isArray(rule)) return rule
    const next = { ...(rule as Record<string, unknown>) }
    delete next.amount
    delete next.percentage
    return next
  })
  if (Array.isArray(item.service_extras)) item.service_extras = redactCommercial(item.service_extras)
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
      const [servicesResult, categoriesResult, extrasResult] = await Promise.all([
        client.rpc('service_admin_list_service_settings'),
        client.rpc('service_admin_list_categories'),
        client.rpc('service_admin_list_extras'),
      ])
      if (servicesResult.error) throw new Error(servicesResult.error.message)
      if (categoriesResult.error) throw new Error(categoriesResult.error.message)
      if (extrasResult.error) throw new Error(extrasResult.error.message)
      return json({
        services: canSeeFinance ? servicesResult.data : redactCommercial(servicesResult.data),
        categories: categoriesResult.data ?? [],
        extras: canSeeFinance ? extrasResult.data : redactCommercial(extrasResult.data),
      })
    }

    await requirePermission('SERVICES_MANAGE')
    const body = await req.json()
    const entity = text(body?.entity || 'SERVICE').toUpperCase()

    if (entity === 'CATEGORY') {
      if (req.method === 'POST') {
        const { data, error } = await client.rpc('service_admin_create_category_audited', {
          p_name: text(body?.name), p_slug: text(body?.slug), p_operation_scope: operationScope(body?.operation_scope), p_admin_id: admin.adminId,
        })
        if (error) throw new Error(error.message)
        return json(data, 201)
      }
      const categoryId = uuid(body?.category_id, 'CATEGORY_ID_INVALID')
      if (req.method === 'DELETE') {
        const { data, error } = await client.rpc('service_admin_remove_category_audited', { p_category_id: categoryId, p_admin_id: admin.adminId })
        if (error) throw new Error(error.message)
        return json(data)
      }
      const { data, error } = await client.rpc('service_admin_update_category_audited', {
        p_category_id: categoryId,
        p_name: text(body?.name), p_slug: text(body?.slug), p_operation_scope: operationScope(body?.operation_scope),
        p_sort_order: integer(body?.sort_order ?? 0, 'sort_order'), p_is_active: body?.is_active !== false, p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (entity === 'EXTRA') {
      const canManageFinance = await can('FINANCE_MANAGE')
      if (!canManageFinance) throw new Error('ADMIN_PERMISSION_DENIED')
      if (req.method === 'POST') {
        const { data, error } = await client.rpc('service_admin_create_extra_audited', {
          p_name: text(body?.name), p_description: text(body?.description) || null,
          p_price: numeric(body?.price ?? 0, 'price'), p_duration_delta_minutes: integer(body?.duration_delta_minutes ?? 0, 'duration_delta_minutes'),
          p_admin_id: admin.adminId,
        })
        if (error) throw new Error(error.message)
        return json(data, 201)
      }
      const extraId = uuid(body?.extra_id, 'EXTRA_ID_INVALID')
      if (req.method === 'DELETE') {
        const { data, error } = await client.rpc('service_admin_remove_extra_audited', { p_extra_id: extraId, p_admin_id: admin.adminId })
        if (error) throw new Error(error.message)
        return json(data)
      }
      const { data, error } = await client.rpc('service_admin_update_extra_audited', {
        p_extra_id: extraId, p_name: text(body?.name), p_description: text(body?.description) || null,
        p_price: numeric(body?.price, 'price'), p_duration_delta_minutes: integer(body?.duration_delta_minutes, 'duration_delta_minutes'),
        p_is_active: body?.is_active !== false, p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (entity !== 'SERVICE') throw new Error('SERVICE_SETTINGS_ENTITY_INVALID')

    if (req.method === 'POST') {
      const canManageFinance = await can('FINANCE_MANAGE')
      const requestedBasePrice = numeric(body?.base_price ?? 0, 'base_price') ?? 0
      const requestedExtraPersonPrice = numeric(body?.price_per_extra_person ?? 0, 'price_per_extra_person') ?? 0
      if ((requestedBasePrice !== 0 || requestedExtraPersonPrice !== 0) && !canManageFinance) throw new Error('ADMIN_PERMISSION_DENIED')
      const { data, error } = await client.rpc('service_admin_create_service_catalog_audited', {
        p_category_id: uuid(body?.category_id, 'CATEGORY_ID_INVALID'),
        p_name: text(body?.name), p_slug: text(body?.slug), p_operation_scope: operationScope(body?.operation_scope),
        p_short_description: text(body?.short_description) || null, p_full_description: text(body?.full_description) || null,
        p_duration_mode: body?.duration_mode === 'BLOCKS' ? 'BLOCKS' : 'FIXED',
        p_base_duration_minutes: integer(body?.base_duration_minutes ?? 60, 'base_duration_minutes'), p_base_price: requestedBasePrice,
        p_buffer_before_minutes: integer(body?.buffer_before_minutes ?? 0, 'buffer_before_minutes'),
        p_buffer_after_minutes: integer(body?.buffer_after_minutes ?? 0, 'buffer_after_minutes'),
        p_minimum_people: integer(body?.minimum_people ?? 1, 'minimum_people'), p_maximum_people: integer(body?.maximum_people ?? 1, 'maximum_people'),
        p_price_per_extra_person: requestedExtraPersonPrice, p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data, 201)
    }

    const serviceId = uuid(body?.service_id, 'SERVICE_ID_INVALID')
    if (req.method === 'DELETE') {
      const { data, error } = await client.rpc('service_admin_remove_service_audited', { p_service_id: serviceId, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }

    const action = text(body?.action).toUpperCase()
    if (action === 'CATALOG') {
      const currentBasePriceChange = Number(body?.price_per_extra_person ?? 0) !== 0
      if (currentBasePriceChange) await requirePermission('FINANCE_MANAGE')
      const { data, error } = await client.rpc('service_admin_update_service_catalog_audited', {
        p_service_id: serviceId, p_category_id: uuid(body?.category_id, 'CATEGORY_ID_INVALID'),
        p_name: text(body?.name), p_slug: text(body?.slug), p_operation_scope: operationScope(body?.operation_scope),
        p_short_description: text(body?.short_description) || null, p_full_description: text(body?.full_description) || null,
        p_minimum_people: integer(body?.minimum_people ?? 1, 'minimum_people'), p_maximum_people: integer(body?.maximum_people ?? 1, 'maximum_people'),
        p_price_per_extra_person: numeric(body?.price_per_extra_person ?? 0, 'price_per_extra_person'),
        p_is_active: body?.is_active !== false, p_sort_order: integer(body?.sort_order ?? 0, 'sort_order'), p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'CUSTOM_FIELDS') {
      const fields = Array.isArray(body?.fields) ? body.fields : null
      if (!fields) throw new Error('SERVICE_FIELDS_INVALID')
      const { data, error } = await client.rpc('service_admin_replace_custom_fields_audited', { p_service_id: serviceId, p_fields: fields, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'DAY_TIME_PRICING') {
      await requirePermission('FINANCE_MANAGE')
      if (!Array.isArray(body?.rules)) throw new Error('PRICING_RULES_INVALID')
      const { data, error } = await client.rpc('service_admin_replace_day_time_pricing_audited', { p_service_id: serviceId, p_rules: body.rules, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'SERVICE_EXTRAS') {
      if (!Array.isArray(body?.extras)) throw new Error('SERVICE_EXTRAS_INVALID')
      const { data, error } = await client.rpc('service_admin_replace_service_extras_audited', { p_service_id: serviceId, p_extras: body.extras, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'OPERATION_SCOPE') {
      const { data, error } = await client.rpc('service_admin_update_operation_scope', {
        p_service_id: serviceId, p_operation_scope: operationScope(body?.operation_scope), p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'TIMING') {
      const mode = body?.duration_mode === 'BLOCKS' ? 'BLOCKS' : body?.duration_mode === 'FIXED' ? 'FIXED' : null
      if (!mode) throw new Error('INVALID_DURATION_MODE')
      const canSeeFinance = await can('FINANCE_VIEW')
      const { data, error } = await client.rpc('service_admin_update_timing_audited', {
        p_service_id: serviceId, p_duration_mode: mode,
        p_base_duration_minutes: integer(body.base_duration_minutes, 'base_duration_minutes'),
        p_booking_block_minutes: integer(body.booking_block_minutes, 'booking_block_minutes', mode === 'FIXED'),
        p_minimum_booking_blocks: integer(body.minimum_booking_blocks, 'minimum_booking_blocks', mode === 'FIXED'),
        p_maximum_booking_blocks: integer(body.maximum_booking_blocks, 'maximum_booking_blocks', mode === 'FIXED'),
        p_base_price: numeric(body.base_price, 'base_price', true), p_price_per_block: numeric(body.price_per_block, 'price_per_block', true),
        p_buffer_before_minutes: integer(body.buffer_before_minutes, 'buffer_before_minutes'), p_buffer_after_minutes: integer(body.buffer_after_minutes, 'buffer_after_minutes'),
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
        p_service_id: serviceId, p_pricing_tiers: tiers, p_duration_presets: presets, p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'CHANGE_POLICY') {
      await requirePermission('FINANCE_MANAGE')
      if (!body?.policy || typeof body.policy !== 'object' || Array.isArray(body.policy)) throw new Error('INVALID_CHANGE_POLICY')
      const { data, error } = await client.rpc('service_admin_upsert_change_policy_audited', { p_service_id: serviceId, p_policy: body.policy, p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }

    throw new Error('SERVICE_SETTINGS_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'SERVICE_SETTINGS_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401 : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})
