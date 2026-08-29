import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'
import { appointmentTimelineCsv } from '../_shared/audit-csv.ts'
import { customerFinancialTermsChanged } from './customerTermsPermission.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

const financeKeys = new Set([
  'commercial_value', 'financial_status', 'financial', 'payments',
  'base_price_snapshot', 'variable_price_adjustment', 'extras_total', 'coupon_discount',
  'gross_contract_settled', 'gross_cash_received', 'refunded_contract_amount', 'refunded_cash_amount',
  'contract_settled', 'cash_received', 'cash_contract_net', 'contract_balance',
  'customer_balance_applied', 'customer_funds_under_reservation', 'customer_cash_cover_of_contract',
  'customer_excess_held', 'penalties_retained',
  'penalty_percent', 'theoretical_penalty', 'penalty_retained', 'penalty_amount',
  'refund_due', 'refundable_amount', 'contract_value', 'new_contract_value',
  'customer_funds_before', 'contract_applied_before', 'excess_before', 'applicable_amount',
  'excess_amount', 'difference_due', 'customer_funds_after_penalty',
  'billing_mode', 'invoice_due_days', 'invoice_due_days_snapshot',
  'invoice_due_basis', 'invoice_due_base_at', 'invoice_due_at', 'invoice_authorized_by_admin_id',
])

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

function redactKeys(value: unknown, keys: Set<string>): unknown {
  if (Array.isArray(value)) return value.map((item) => redactKeys(item, keys))
  if (!value || typeof value !== 'object') return value
  const result: Record<string, unknown> = {}
  for (const [key, nested] of Object.entries(value as Record<string, unknown>)) {
    if (keys.has(key)) continue
    result[key] = redactKeys(nested, keys)
  }
  return result
}

function redactFinance(value: unknown): unknown {
  return redactKeys(value, financeKeys)
}

function parseChangeOrigin(url: URL): 'CLIENT' | 'OPERATION' {
  const value = clean(url.searchParams.get('change_origin'))?.toUpperCase()
  if (value !== 'CLIENT' && value !== 'OPERATION') throw new Error('CHANGE_ORIGIN_REQUIRED')
  return value
}

function parseNewContractValue(url: URL, required: boolean): number | null {
  const raw = clean(url.searchParams.get('new_contract_value'))
  if (!raw) {
    if (required) throw new Error('NEW_CONTRACT_VALUE_REQUIRED')
    return null
  }
  const value = Number(raw)
  if (!Number.isFinite(value) || value < 0) throw new Error('NEW_CONTRACT_VALUE_INVALID')
  return Math.round(value * 100) / 100
}

function requestEvidence(req: Request) {
  const ip = (req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0] ?? '').trim()
  const userAgent = (req.headers.get('user-agent') ?? '').trim()
  const requestId = (req.headers.get('x-request-id') ?? crypto.randomUUID()).trim()
  if (!ip || !userAgent || !requestId) throw new Error('AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED')
  return { ip, userAgent, requestId }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET' && req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()
    const url = new URL(req.url)
    const can = (permission: string) => hasAdminPermission(admin.adminId, permission)
    const requirePermission = async (permission: string) => {
      if (!(await can(permission))) throw new Error('ADMIN_PERMISSION_DENIED')
    }
    const canViewFinance = await can('FINANCE_VIEW')
    const canManageFinance = await can('FINANCE_MANAGE')

    if (req.method === 'POST') {
      const body = await req.json().catch(() => ({})) as Record<string, unknown>
      const action = clean(typeof body.action === 'string' ? body.action : null)

      if (action === 'set_customer_terms') {
        await requirePermission('CUSTOMERS_MANAGE')
        const customerIdValue = uuid(body.customer_id, 'CUSTOMER_ID_INVALID')
        const serviceIds = Array.isArray(body.authorized_service_ids)
          ? body.authorized_service_ids.map((value) => uuid(value, 'AUTHORIZED_SERVICE_INVALID'))
          : []
        const prebookHoldMinutes = Number(body.prebook_hold_minutes)
        const maxActivePrebooks = Number(body.max_active_prebooks)

        if (!Number.isInteger(prebookHoldMinutes) || prebookHoldMinutes <= 0) throw new Error('PREBOOK_HOLD_MINUTES_INVALID')
        if (!Number.isInteger(maxActivePrebooks) || maxActivePrebooks <= 0) throw new Error('MAX_ACTIVE_PREBOOKS_INVALID')

        const { data: currentTerms, error: currentTermsError } = await client
          .from('customer_commercial_terms')
          .select('billing_mode,invoice_due_days')
          .eq('customer_id', customerIdValue)
          .maybeSingle()
        if (currentTermsError) throw new Error(currentTermsError.message)

        const hasBillingMode = Object.prototype.hasOwnProperty.call(body, 'billing_mode')
        const hasInvoiceDueDays = Object.prototype.hasOwnProperty.call(body, 'invoice_due_days')
        const requestedBillingMode = hasBillingMode && typeof body.billing_mode === 'string'
          ? body.billing_mode.toUpperCase()
          : null
        const requestedInvoiceDueDays = hasInvoiceDueDays
          ? body.invoice_due_days === null || body.invoice_due_days === undefined
            ? null
            : Number(body.invoice_due_days)
          : null

        if (!currentTerms && !canManageFinance) throw new Error('ADMIN_PERMISSION_DENIED')
        const billingMode = requestedBillingMode ?? currentTerms?.billing_mode ?? ''
        const invoiceDueDays = hasInvoiceDueDays ? requestedInvoiceDueDays : currentTerms?.invoice_due_days ?? null
        if (billingMode !== 'CHECKOUT' && billingMode !== 'INVOICE') throw new Error('BILLING_MODE_INVALID')
        if (invoiceDueDays !== null && (!Number.isInteger(invoiceDueDays) || invoiceDueDays < 0)) throw new Error('INVOICE_DUE_DAYS_INVALID')
        if (billingMode === 'INVOICE' && invoiceDueDays === null) throw new Error('INVOICE_DUE_DAYS_REQUIRED')

        if (customerFinancialTermsChanged(currentTerms, { billing_mode: billingMode, invoice_due_days: invoiceDueDays })) {
          await requirePermission('FINANCE_MANAGE')
        }

        const { data, error } = await client.rpc('service_admin_set_customer_commercial_terms', {
          p_customer_id: customerIdValue,
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
        return json(canViewFinance ? data : redactFinance(data))
      }

      if (action === 'authorize_invoice') {
        await requirePermission('FINANCE_MANAGE')
        const { data, error } = await client.rpc('service_admin_authorize_invoiced_appointment', {
          p_appointment_id: uuid(body.appointment_id, 'APPOINTMENT_ID_INVALID'),
          p_admin_id: admin.adminId,
        })
        if (error) throw new Error(error.message)
        return json(data)
      }

      if (action === 'set_permission') {
        await requirePermission('TEAM_MANAGE')
        const { data, error } = await client.rpc('service_admin_set_permission', {
          p_target_admin_id: uuid(body.admin_user_id, 'ADMIN_USER_ID_INVALID'),
          p_permission: typeof body.permission === 'string' ? body.permission : '',
          p_is_granted: body.is_granted === true,
          p_actor_admin_id: admin.adminId,
        })
        if (error) throw new Error(error.message)
        return json(data)
      }

      if (action === 'unlock_token_verification') {
        await requirePermission('AGENDA_MANAGE')
        await requirePermission('AUDIT_VIEW')
        const evidence = requestEvidence(req)
        const reason = typeof body.reason === 'string' ? body.reason.trim().slice(0, 500) : ''
        if (!reason) throw new Error('UNLOCK_REASON_REQUIRED')
        const { data, error } = await client.rpc('service_admin_unlock_appointment_token_verification', {
          p_appointment_id: uuid(body.appointment_id, 'APPOINTMENT_ID_INVALID'),
          p_admin_id: admin.adminId,
          p_reason: reason,
          p_ip: evidence.ip,
          p_user_agent: evidence.userAgent,
          p_request_id: evidence.requestId,
          p_session_id: null,
        })
        if (error) throw new Error(error.message)
        return json(data)
      }

      throw new Error('ADMIN_ACTION_INVALID')
    }

    const action = clean(url.searchParams.get('action')) ?? 'agenda'

    if (action === 'access_profile') {
      const { data, error } = await client.rpc('service_admin_get_access_profile', { p_admin_id: admin.adminId })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'appointment') {
      await requirePermission('AGENDA_VIEW')
      const { data, error } = await client.rpc('service_admin_get_appointment', { p_appointment_id: appointmentId(url) })
      if (error) throw new Error(error.message)
      return json(canViewFinance ? data : redactFinance(data))
    }

    if (action === 'timeline' || action === 'timeline_export') {
      await requirePermission('AUDIT_VIEW')
      const id = appointmentId(url)
      const { data, error } = await client.rpc('service_admin_get_appointment_timeline', {
        p_appointment_id: id,
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      const safeData = canViewFinance ? data : redactFinance(data)
      if (action === 'timeline_export') {
        return new Response(appointmentTimelineCsv(safeData), {
          status: 200,
          headers: {
            ...corsHeaders,
            'content-type': 'text/csv; charset=utf-8',
            'content-disposition': `attachment; filename="agenda-${id}-timeline.csv"`,
          },
        })
      }
      return json(safeData)
    }

    if (action === 'change_preview') {
      await requirePermission('AGENDA_MANAGE')
      const changeType = clean(url.searchParams.get('change_type'))
      if (changeType !== 'RESCHEDULE' && changeType !== 'CANCEL') throw new Error('INVALID_CHANGE_ACTION')
      const requestedAt = clean(url.searchParams.get('requested_at'))
      const parsedRequestedAt = requestedAt ? new Date(requestedAt) : new Date()
      if (Number.isNaN(parsedRequestedAt.getTime())) throw new Error('REQUESTED_AT_INVALID')
      const origin = parseChangeOrigin(url)
      const newContractValue = parseNewContractValue(url, changeType === 'RESCHEDULE')

      const { data, error } = await client.rpc('calculate_reservation_change', {
        p_appointment_id: appointmentId(url),
        p_action_type: changeType,
        p_requested_at: parsedRequestedAt.toISOString(),
        p_change_origin: origin,
        p_new_contract_value: newContractValue,
      })
      if (error) throw new Error(error.message)
      return json(canViewFinance ? data : redactFinance(data))
    }

    if (action === 'amelia') {
      await requirePermission('AGENDA_VIEW')
      const startAt = requiredIso(url, 'start_at')
      const endAt = requiredIso(url, 'end_at')
      const { data, error } = await client.rpc('service_admin_list_amelia_history', {
        p_start_at: startAt,
        p_end_at: endAt,
        p_search: clean(url.searchParams.get('search')),
      })
      if (error) throw new Error(error.message)
      return json(canViewFinance ? data : redactFinance(data))
    }

    if (action === 'customers') {
      await requirePermission('CUSTOMERS_VIEW')
      const limitRaw = Number(url.searchParams.get('limit') ?? '50')
      const limit = Number.isInteger(limitRaw) ? Math.max(1, Math.min(limitRaw, 100)) : 50
      const { data, error } = await client.rpc('service_admin_list_customers', {
        p_search: clean(url.searchParams.get('search')),
        p_limit: limit,
      })
      if (error) throw new Error(error.message)
      return json(canViewFinance ? data : redactFinance(data))
    }

    if (action === 'customer_profile') {
      await requirePermission('CUSTOMERS_VIEW')
      const { data, error } = await client.rpc('service_admin_get_customer_commercial_profile', {
        p_customer_id: customerId(url),
      })
      if (error) throw new Error(error.message)
      if (!data) throw new Error('CUSTOMER_NOT_FOUND')
      return json(canViewFinance ? data : redactFinance(data))
    }

    if (action === 'customer_services') {
      await requirePermission('CUSTOMERS_VIEW')
      const { data, error } = await client
        .from('services')
        .select('id,name,slug,duration_mode,is_active,sort_order')
        .eq('is_active', true)
        .order('sort_order', { ascending: true })
        .order('name', { ascending: true })
      if (error) throw new Error(error.message)
      return json({ services: data ?? [] })
    }

    if (action === 'manual_booking_options') {
      await requirePermission('AGENDA_MANAGE')
      const [{ data: services, error: servicesError }, { data: assignments, error: assignmentsError }] = await Promise.all([
        client.from('services')
          .select('id,name,slug,duration_mode,base_duration_minutes,minimum_people,maximum_people,sort_order')
          .eq('is_active', true).order('sort_order', { ascending: true }).order('name', { ascending: true }),
        client.from('service_employees')
          .select('id,service_id,employee_id,employees!inner(id,name,is_active)')
          .eq('is_active', true).eq('employees.is_active', true),
      ])
      if (servicesError || assignmentsError) throw new Error('MANUAL_BOOKING_OPTIONS_FAILED')
      return json({ services: services ?? [], service_employees: assignments ?? [] })
    }

    if (action === 'manual_booking_slots') {
      await requirePermission('AGENDA_MANAGE')
      const localDate = clean(url.searchParams.get('local_date'))
      if (!localDate || !/^\d{4}-\d{2}-\d{2}$/.test(localDate)) throw new Error('LOCAL_DATE_INVALID')
      const peopleRaw = Number(url.searchParams.get('people_count') ?? '1')
      if (!Number.isInteger(peopleRaw) || peopleRaw < 1) throw new Error('INVALID_PEOPLE_COUNT')
      const durationRaw = clean(url.searchParams.get('duration_blocks'))
      const durationBlocks = durationRaw === null ? null : Number(durationRaw)
      if (durationBlocks !== null && (!Number.isInteger(durationBlocks) || durationBlocks < 1)) throw new Error('INVALID_DURATION_BLOCKS')
      const { data, error } = await client.rpc('list_available_slots', {
        p_service_id: uuid(url.searchParams.get('service_id'), 'SERVICE_ID_INVALID'),
        p_service_employee_id: uuid(url.searchParams.get('service_employee_id'), 'SERVICE_EMPLOYEE_ID_INVALID'),
        p_extra_selections: [],
        p_people_count: peopleRaw,
        p_local_date: localDate,
        p_duration_blocks: durationBlocks,
      })
      if (error) throw new Error(error.message)
      return json({ slots: data ?? [], timezone: 'America/Sao_Paulo' })
    }

    if (action !== 'agenda') throw new Error('ADMIN_ACTION_INVALID')

    await requirePermission('AGENDA_VIEW')
    const startAt = requiredIso(url, 'start_at')
    const endAt = requiredIso(url, 'end_at')
    const { data, error } = await client.rpc('service_admin_list_agenda', {
      p_start_at: startAt,
      p_end_at: endAt,
    })
    if (error) throw new Error(error.message)
    return json(canViewFinance ? data : redactFinance(data))
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_AGENDA_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})