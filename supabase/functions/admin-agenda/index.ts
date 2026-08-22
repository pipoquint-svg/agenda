import { adminClient, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
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

function requiredIso(url: URL, key: string): string {
  const raw = clean(url.searchParams.get(key))
  if (!raw) throw new Error(`ADMIN_${key.toUpperCase()}_REQUIRED`)
  const parsed = new Date(raw)
  if (Number.isNaN(parsed.getTime())) throw new Error(`ADMIN_${key.toUpperCase()}_INVALID`)
  return parsed.toISOString()
}

function appointmentId(url: URL): string {
  return uuid(clean(url.searchParams.get('id')), 'APPOINTMENT_ID_INVALID')
}

function customerId(url: URL): string {
  return uuid(clean(url.searchParams.get('id')), 'CUSTOMER_ID_INVALID')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET' && req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()
    const url = new URL(req.url)

    if (req.method === 'POST') {
      const body = await req.json().catch(() => ({})) as Record<string, unknown>
      const action = clean(typeof body.action === 'string' ? body.action : null)

      if (action === 'set_customer_terms') {
        const serviceIds = Array.isArray(body.authorized_service_ids)
          ? body.authorized_service_ids.map((value) => uuid(value, 'AUTHORIZED_SERVICE_INVALID'))
          : []
        const billingMode = typeof body.billing_mode === 'string' ? body.billing_mode : ''
        const invoiceDueDays = body.invoice_due_days === null || body.invoice_due_days === undefined
          ? null
          : Number(body.invoice_due_days)
        const prebookHoldMinutes = Number(body.prebook_hold_minutes)
        const maxActivePrebooks = Number(body.max_active_prebooks)

        if (!Number.isInteger(prebookHoldMinutes) || prebookHoldMinutes <= 0) throw new Error('PREBOOK_HOLD_MINUTES_INVALID')
        if (!Number.isInteger(maxActivePrebooks) || maxActivePrebooks <= 0) throw new Error('MAX_ACTIVE_PREBOOKS_INVALID')
        if (invoiceDueDays !== null && (!Number.isInteger(invoiceDueDays) || invoiceDueDays < 0)) throw new Error('INVOICE_DUE_DAYS_INVALID')

        const { data, error } = await client.rpc('service_admin_set_customer_commercial_terms', {
          p_customer_id: uuid(body.customer_id, 'CUSTOMER_ID_INVALID'),
          p_can_prebook: body.can_prebook === true,
          p_prebook_hold_minutes: prebookHoldMinutes,
          p_max_active_prebooks: maxActivePrebooks,
          p_requires_manual_confirmation: body.requires_manual_confirmation !== false,
          p_billing_mode: billingMode,
          p_invoice_due_days: invoiceDueDays,
          p_is_active: body.is_active !== false,
          p_authorized_service_ids: serviceIds,
          p_admin_id: admin.adminId,
        })
        if (error) throw new Error(error.message)
        return json(data)
      }

      if (action === 'authorize_invoice') {
        const { data, error } = await client.rpc('service_admin_authorize_invoiced_appointment', {
          p_appointment_id: uuid(body.appointment_id, 'APPOINTMENT_ID_INVALID'),
          p_admin_id: admin.adminId,
        })
        if (error) throw new Error(error.message)
        return json(data)
      }

      throw new Error('ADMIN_ACTION_INVALID')
    }

    const action = clean(url.searchParams.get('action')) ?? 'agenda'

    if (action === 'appointment') {
      const { data, error } = await client.rpc('service_admin_get_appointment', { p_appointment_id: appointmentId(url) })
      if (error) throw new Error(error.message)
      return json(data)
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

    if (action === 'customers') {
      const limitRaw = Number(url.searchParams.get('limit') ?? '50')
      const limit = Number.isInteger(limitRaw) ? Math.max(1, Math.min(limitRaw, 100)) : 50
      const { data, error } = await client.rpc('service_admin_list_customers', {
        p_search: clean(url.searchParams.get('search')),
        p_limit: limit,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'customer_profile') {
      const { data, error } = await client.rpc('service_admin_get_customer_commercial_profile', {
        p_customer_id: customerId(url),
      })
      if (error) throw new Error(error.message)
      if (!data) throw new Error('CUSTOMER_NOT_FOUND')
      return json(data)
    }

    if (action === 'customer_services') {
      const { data, error } = await client
        .from('services')
        .select('id,name,slug,duration_mode,is_active,sort_order')
        .eq('is_active', true)
        .order('sort_order', { ascending: true })
        .order('name', { ascending: true })
      if (error) throw new Error(error.message)
      return json({ services: data ?? [] })
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
