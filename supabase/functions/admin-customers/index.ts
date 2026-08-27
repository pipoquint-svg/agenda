import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, PUT, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' } })
}

function clean(value: unknown): string | null {
  return typeof value === 'string' && value.trim() ? value.trim() : null
}

function uuid(value: unknown): string {
  const id = clean(value) ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) throw new Error('CUSTOMER_ID_INVALID')
  return id
}

function integer(value: unknown, code: string, nullable = false): number | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  const parsed = Number(value)
  if (!Number.isInteger(parsed) || parsed < 0) throw new Error(code)
  return parsed
}

function birthDate(value: unknown): string | null {
  if (value === null || value === undefined || value === '') return null
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error('CUSTOMER_BIRTH_DATE_INVALID')
  const parsed = new Date(`${value}T00:00:00Z`)
  if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) throw new Error('CUSTOMER_BIRTH_DATE_INVALID')
  if (value > new Date().toISOString().slice(0, 10)) throw new Error('CUSTOMER_BIRTH_DATE_FUTURE')
  return value
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'CUSTOMERS_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const url = new URL(req.url)
      const customerId = clean(url.searchParams.get('customer_id'))
      if (customerId) {
        const id = uuid(customerId)
        const [
          { data: profile, error },
          { data: services, error: servicesError },
          { data: identity, error: identityError },
          { data: birthDateReconciliation, error: reconciliationError },
        ] = await Promise.all([
          client.rpc('service_admin_get_customer_commercial_profile', { p_customer_id: id }),
          client.from('services').select('id,name,slug,operation_scope').eq('is_active', true).not('operation_scope', 'is', null).order('sort_order').order('name'),
          client.from('customers').select('birth_date').eq('id', id).maybeSingle(),
          client.rpc('service_admin_list_customer_birth_date_candidates', { p_customer_id: id, p_admin_id: admin.adminId }),
        ])
        if (error) throw new Error(error.message)
        if (servicesError) throw new Error('CUSTOMER_SERVICES_QUERY_FAILED')
        if (identityError) throw new Error('CUSTOMER_IDENTITY_QUERY_FAILED')
        if (reconciliationError) throw new Error('CUSTOMER_BIRTH_DATE_RECONCILIATION_QUERY_FAILED')
        const enriched = profile && typeof profile === 'object' && !Array.isArray(profile)
          ? { ...profile, customer: { ...((profile as Record<string, unknown>).customer as Record<string, unknown> ?? {}), birth_date: identity?.birth_date ?? null } }
          : profile
        return json({
          profile: enriched,
          services: services ?? [],
          birth_date_reconciliation: birthDateReconciliation ?? { canonical_birth_date: identity?.birth_date ?? null, candidates: [] },
        })
      }

      const search = clean(url.searchParams.get('search'))
      const limitRaw = url.searchParams.get('limit')
      const limit = limitRaw ? Number(limitRaw) : 50
      if (!Number.isInteger(limit) || limit < 1 || limit > 100) throw new Error('CUSTOMER_LIMIT_INVALID')
      const { data, error } = await client.rpc('service_admin_list_customers', { p_search: search, p_limit: limit })
      if (error) throw new Error(error.message)
      return json(data ?? { customers: [] })
    }

    if (!(await hasAdminPermission(admin.adminId, 'CUSTOMERS_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const customerId = uuid(body.customer_id)

    if (body.action === 'birth_date') {
      const nextBirthDate = birthDate(body.birth_date)
      const { error } = await client.rpc('service_admin_set_customer_birth_date', {
        p_customer_id: customerId,
        p_birth_date: nextBirthDate,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      const [{ data: profile, error: profileError }, { data: identity, error: identityError }] = await Promise.all([
        client.rpc('service_admin_get_customer_commercial_profile', { p_customer_id: customerId }),
        client.from('customers').select('birth_date').eq('id', customerId).maybeSingle(),
      ])
      if (profileError) throw new Error(profileError.message)
      if (identityError) throw new Error('CUSTOMER_IDENTITY_QUERY_FAILED')
      const enriched = profile && typeof profile === 'object' && !Array.isArray(profile)
        ? { ...profile, customer: { ...((profile as Record<string, unknown>).customer as Record<string, unknown> ?? {}), birth_date: identity?.birth_date ?? null } }
        : profile
      return json({ profile: enriched })
    }

    const billingMode = (clean(body.billing_mode) ?? '').toUpperCase()
    if (!['CHECKOUT', 'INVOICE'].includes(billingMode)) throw new Error('BILLING_MODE_INVALID')
    if (typeof body.can_prebook !== 'boolean' || typeof body.requires_manual_confirmation !== 'boolean' || typeof body.is_active !== 'boolean') {
      throw new Error('CUSTOMER_TERMS_BOOLEAN_INVALID')
    }
    if (!Array.isArray(body.authorized_service_ids) || body.authorized_service_ids.some((id) => typeof id !== 'string')) throw new Error('AUTHORIZED_SERVICES_INVALID')

    const { data: current, error: currentError } = await client.rpc('service_admin_get_customer_commercial_profile', { p_customer_id: customerId })
    if (currentError) throw new Error(currentError.message)
    const currentTerms = (current as { terms?: Record<string, unknown> } | null)?.terms ?? null
    const invoiceDueDays = integer(body.invoice_due_days, 'INVOICE_DUE_DAYS_INVALID', true)
    const financialChange = !currentTerms
      || String(currentTerms.billing_mode ?? '') !== billingMode
      || Number(currentTerms.invoice_due_days ?? -1) !== Number(invoiceDueDays ?? -1)
    if (financialChange && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')

    const { data, error } = await client.rpc('service_admin_set_customer_commercial_terms', {
      p_customer_id: customerId,
      p_can_prebook: body.can_prebook,
      p_prebook_hold_minutes: integer(body.prebook_hold_minutes, 'PREBOOK_HOLD_MINUTES_INVALID'),
      p_max_active_prebooks: integer(body.max_active_prebooks, 'MAX_ACTIVE_PREBOOKS_INVALID'),
      p_requires_manual_confirmation: body.requires_manual_confirmation,
      p_billing_mode: billingMode,
      p_invoice_due_days: invoiceDueDays,
      p_is_active: body.is_active,
      p_authorized_service_ids: body.authorized_service_ids,
      p_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return json({ profile: data })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'CUSTOMER_ADMIN_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' || code === 'ADMIN_FINANCE_PERMISSION_REQUIRED' ? 403
      : 400
    return json({ error: { code } }, status)
  }
})
