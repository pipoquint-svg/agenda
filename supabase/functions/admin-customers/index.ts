import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, DELETE, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' } })
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

function csvCell(value: unknown): string {
  const raw = value === null || value === undefined ? '' : String(value)
  const safe = /^[=+\-@]/.test(raw) ? `'${raw}` : raw
  return `"${safe.replaceAll('"', '""')}"`
}

function customerCsv(rows: Array<Record<string, unknown>>): string {
  const header = ['Nome', 'E-mail', 'Telefone', 'Endereço', 'Data de nascimento', 'Tipo', 'Anonimizado em']
  const lines = rows.map((row) => [
    row.name,
    row.email,
    row.phone,
    row.address,
    row.birth_date,
    row.customer_type,
    row.anonymized_at,
  ].map(csvCell).join(','))
  return `\uFEFF${header.map(csvCell).join(',')}\r\n${lines.join('\r\n')}\r\n`
}

async function listPage(client: ReturnType<typeof adminClient>, search: string | null, limit: number, offset: number) {
  const { data, error } = await client.rpc('service_admin_list_customers_page', {
    p_search: search,
    p_limit: limit,
    p_offset: offset,
  })
  if (error) throw new Error(error.message)
  return (data ?? { customers: [], total: 0, limit, offset, has_more: false }) as Record<string, unknown>
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST', 'PUT', 'DELETE'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

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
          { data: birthDateReconciliation, error: reconciliationError },
        ] = await Promise.all([
          client.rpc('service_admin_get_customer_commercial_profile', { p_customer_id: id }),
          client.rpc('service_admin_list_customer_service_options'),
          client.rpc('service_admin_list_customer_birth_date_candidates', { p_customer_id: id, p_admin_id: admin.adminId }),
        ])
        if (error) throw new Error(error.message)
        if (servicesError) throw new Error('CUSTOMER_SERVICES_QUERY_FAILED')
        const customer = profile && typeof profile === 'object' && !Array.isArray(profile)
          ? ((profile as Record<string, unknown>).customer as Record<string, unknown> | undefined)
          : undefined
        const reconciliationFallback = {
          canonical_birth_date: customer?.birth_date ?? null,
          birth_date_locked: false,
          has_conflict: false,
          candidates: [],
        }
        if (reconciliationError) {
          console.warn('CUSTOMER_BIRTH_DATE_RECONCILIATION_UNAVAILABLE', { customer_id: id, message: reconciliationError.message })
        }
        return json({
          profile,
          services: Array.isArray(services) ? services : [],
          birth_date_reconciliation: reconciliationError ? reconciliationFallback : (birthDateReconciliation ?? reconciliationFallback),
        })
      }

      const search = clean(url.searchParams.get('search'))
      if (url.searchParams.get('export') === 'csv') {
        if (!(await hasAdminPermission(admin.adminId, 'CUSTOMERS_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
        const rows: Array<Record<string, unknown>> = []
        const pageSize = 200
        let offset = 0
        let total = 0
        do {
          const page = await listPage(client, search, pageSize, offset)
          const customers = Array.isArray(page.customers) ? page.customers as Array<Record<string, unknown>> : []
          rows.push(...customers)
          total = Number(page.total ?? rows.length)
          offset += pageSize
        } while (offset < total)
        return new Response(customerCsv(rows), {
          status: 200,
          headers: {
            ...corsHeaders,
            'content-type': 'text/csv; charset=utf-8',
            'content-disposition': 'attachment; filename="clientes.csv"',
            'cache-control': 'no-store',
          },
        })
      }

      const limit = Number(url.searchParams.get('limit') ?? '50')
      const offset = Number(url.searchParams.get('offset') ?? '0')
      if (!Number.isInteger(limit) || limit < 1 || limit > 200) throw new Error('CUSTOMER_LIMIT_INVALID')
      if (!Number.isInteger(offset) || offset < 0) throw new Error('CUSTOMER_OFFSET_INVALID')
      return json(await listPage(client, search, limit, offset))
    }

    if (!(await hasAdminPermission(admin.adminId, 'CUSTOMERS_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const body = await req.json().catch(() => ({})) as Record<string, unknown>

    if (req.method === 'POST') {
      const customerType = (clean(body.customer_type) ?? 'PERSON').toUpperCase()
      const { data, error } = await client.rpc('service_admin_create_customer', {
        p_customer_type: customerType,
        p_name: clean(body.name),
        p_cpf_cnpj: clean(body.cpf_cnpj),
        p_email: clean(body.email),
        p_phone: clean(body.phone),
        p_address: clean(body.address),
        p_birth_date: birthDate(body.birth_date),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json({ profile: data }, 201)
    }

    const customerId = uuid(body.customer_id)

    if (req.method === 'DELETE') {
      if (body.confirmation !== 'ANONYMIZE') throw new Error('CUSTOMER_ANONYMIZE_CONFIRMATION_REQUIRED')
      const { data, error } = await client.rpc('service_admin_anonymize_customer', {
        p_customer_id: customerId,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json({ profile: data, anonymized: true, financial_history_preserved: true })
    }

    if (body.action === 'identity') {
      const { data, error } = await client.rpc('service_admin_update_customer_identity', {
        p_customer_id: customerId,
        p_name: clean(body.name),
        p_cpf_cnpj: clean(body.cpf_cnpj),
        p_email: clean(body.email),
        p_phone: clean(body.phone),
        p_address: clean(body.address),
        p_birth_date: birthDate(body.birth_date),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json({ profile: data })
    }

    if (body.action === 'birth_date') {
      const nextBirthDate = birthDate(body.birth_date)
      const { error } = await client.rpc('service_admin_set_customer_birth_date', {
        p_customer_id: customerId,
        p_birth_date: nextBirthDate,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      const { data: profile, error: profileError } = await client.rpc('service_admin_get_customer_commercial_profile', { p_customer_id: customerId })
      if (profileError) throw new Error(profileError.message)
      return json({ profile })
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
      : code === 'CUSTOMER_NOT_FOUND' ? 404
      : code === 'CUSTOMER_EMAIL_ALREADY_EXISTS' || code === 'CUSTOMER_ANONYMIZED_READ_ONLY' ? 409
      : 400
    return json({ error: { code } }, status)
  }
})
