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

function appointmentId(url: URL): string {
  const id = clean(url.searchParams.get('id'))
  if (!id || !/^[0-9a-f-]{36}$/i.test(id)) throw new Error('APPOINTMENT_ID_INVALID')
  return id
}

function brandFilter(url: URL): string | null {
  const brand = clean(url.searchParams.get('brand_key'))?.toUpperCase() ?? null
  if (brand && !['BLACKSHEEP', 'SABRINA'].includes(brand)) throw new Error('ADMIN_BRAND_FILTER_INVALID')
  return brand
}

function redactFinance(value: unknown): unknown {
  if (!value || typeof value !== 'object') return value
  const data = structuredClone(value as Record<string, unknown>)
  if (Array.isArray(data.appointments)) {
    data.appointments = data.appointments.map((item) => {
      const next = { ...(item as Record<string, unknown>) }
      delete next.commercial_value
      delete next.financial
      delete next.financial_status
      return next
    })
  }
  if (data.appointment && typeof data.appointment === 'object') {
    const appointment = { ...(data.appointment as Record<string, unknown>) }
    for (const key of ['commercial_value','base_price','variable_price_adjustment','extras_total','coupon_discount','financial_status']) delete appointment[key]
    data.appointment = appointment
  }
  delete data.financial
  delete data.payments
  return data
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const url = new URL(req.url)
    const action = clean(url.searchParams.get('action')) ?? 'agenda'
    const moduleKey = action === 'permissions' ? undefined
      : action === 'amelia' ? 'AMELIA'
      : action === 'dashboard' ? 'DASHBOARD'
      : 'AGENDA'
    const admin = await requireAdmin(req, moduleKey)
    const client = adminClient()
    const canSeeFinance = admin.role === 'OWNER' || admin.permissions.FINANCE === true

    if (action === 'permissions') {
      const { data, error } = await client.rpc('service_admin_get_permissions', { p_admin_user_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'dashboard') {
      const { data, error } = await client.rpc('service_admin_dashboard', {
        p_start_at: requiredIso(url, 'start_at'),
        p_end_at: requiredIso(url, 'end_at'),
        p_brand_key: brandFilter(url),
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'appointment') {
      const { data, error } = await client.rpc('service_admin_get_appointment', { p_appointment_id: appointmentId(url) })
      if (error) throw new Error(error.message)
      return json(canSeeFinance ? data : redactFinance(data))
    }

    if (action === 'change_preview') {
      const changeType = clean(url.searchParams.get('change_type'))
      if (changeType !== 'RESCHEDULE' && changeType !== 'CANCEL') throw new Error('INVALID_CHANGE_ACTION')
      const requestedAt = clean(url.searchParams.get('requested_at'))
      const parsedRequestedAt = requestedAt ? new Date(requestedAt) : new Date()
      if (Number.isNaN(parsedRequestedAt.getTime())) throw new Error('REQUESTED_AT_INVALID')

      const { data, error } = await client.rpc('calculate_appointment_change_policy', {
        p_appointment_id: appointmentId(url),
        p_action_type: changeType,
        p_requested_at: parsedRequestedAt.toISOString(),
      })
      if (error) throw new Error(error.message)
      if (!canSeeFinance) {
        const next = { ...(data as Record<string, unknown>) }
        for (const key of ['contract_value','net_paid','penalty_value','penalty_amount','penalty_due_now','refundable_amount','credit_amount','cancellation_penalty_outstanding']) delete next[key]
        return json(next)
      }
      return json(data)
    }

    if (action === 'amelia') {
      const { data, error } = await client.rpc('service_admin_list_amelia_history', {
        p_start_at: requiredIso(url, 'start_at'),
        p_end_at: requiredIso(url, 'end_at'),
        p_search: clean(url.searchParams.get('search')),
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action !== 'agenda') throw new Error('ADMIN_ACTION_INVALID')

    const { data, error } = await client.rpc('service_admin_list_agenda', {
      p_start_at: requiredIso(url, 'start_at'),
      p_end_at: requiredIso(url, 'end_at'),
    })
    if (error) throw new Error(error.message)
    return json(canSeeFinance ? data : redactFinance(data))
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_AGENDA_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_MODULE_ACCESS_DENIED' ? 403
      : 400
    return json({ error: { code } }, status)
  }
})
