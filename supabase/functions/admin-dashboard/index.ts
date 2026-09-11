import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

const financePendingKinds = new Set([
  'PAYMENT_AWAITING',
  'BALANCE_DUE_PENDING',
  'RESCHEDULE_PENALTY_PENDING',
  'CANCELLATION_REFUND_PENDING',
])

const homeMovementActions = [
  'PAYMENT_HOLD_EXPIRED',
  'APPOINTMENT_CANCELLED',
  'APPOINTMENT_RESCHEDULED',
]

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function requiredIso(url: URL, key: string): string {
  const raw = url.searchParams.get(key)?.trim() ?? ''
  const parsed = new Date(raw)
  if (!raw) throw new Error(`ADMIN_${key.toUpperCase()}_REQUIRED`)
  if (Number.isNaN(parsed.getTime())) throw new Error(`ADMIN_${key.toUpperCase()}_INVALID`)
  return parsed.toISOString()
}

function redactFinancialPendingItems(data: unknown): unknown {
  if (!data || typeof data !== 'object' || Array.isArray(data)) return data
  const output: Record<string, unknown> = { ...(data as Record<string, unknown>) }
  if (Array.isArray(output.pending_items)) {
    output.pending_items = output.pending_items.filter((item) => {
      if (!item || typeof item !== 'object' || Array.isArray(item)) return true
      const kind = String((item as Record<string, unknown>).kind ?? '')
      return !financePendingKinds.has(kind)
    })
  }
  return output
}

function objectValue(value: unknown, key: string): unknown {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return (value as Record<string, unknown>)[key] ?? null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, 'DASHBOARD_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const canSeeFinance = await hasAdminPermission(admin.adminId, 'FINANCE_VIEW')

    const url = new URL(req.url)
    const scopeRaw = url.searchParams.get('operation_scope')?.trim().toUpperCase() ?? ''
    const operationScope = scopeRaw || null
    if (operationScope !== null && operationScope !== 'BLACKSHEEP' && operationScope !== 'SABRINA') {
      throw new Error('ADMIN_DASHBOARD_OPERATION_SCOPE_INVALID')
    }

    const client = adminClient()
    const { data, error } = await client.rpc('service_admin_get_dashboard', {
      p_start_at: requiredIso(url, 'start_at'),
      p_end_at: requiredIso(url, 'end_at'),
      p_operation_scope: operationScope,
    })
    if (error) throw new Error(error.message)

    const output: Record<string, unknown> = data && typeof data === 'object' && !Array.isArray(data)
      ? { ...(data as Record<string, unknown>) }
      : { pending_items: [] as unknown[] }

    const [recentResult, movementsResult] = await Promise.all([
      client
        .from('appointments')
        .select('id,public_code,status,start_at,end_at,created_at,origin,service_id,primary_customer_id,service_name_snapshot')
        .is('deleted_at', null)
        .eq('status', 'CONFIRMED')
        .order('created_at', { ascending: false })
        .order('id', { ascending: false })
        .limit(20),
      client
        .from('audit_logs')
        .select('id,entity_id,action,before_json,after_json,created_at')
        .eq('entity_type', 'APPOINTMENT')
        .in('action', homeMovementActions)
        .order('created_at', { ascending: false })
        .order('id', { ascending: false })
        .limit(30),
    ])
    if (recentResult.error) throw new Error('ADMIN_RECENT_APPOINTMENTS_QUERY_FAILED')
    if (movementsResult.error) throw new Error('ADMIN_RECENT_MOVEMENTS_QUERY_FAILED')

    const recentRows = recentResult.data ?? []
    const movementRows = movementsResult.data ?? []
    const movementAppointmentIds = movementRows.map((row) => row.entity_id).filter(Boolean) as string[]

    let movementAppointments: Array<{
      id: string
      public_code: string | null
      status: string
      start_at: string
      end_at: string
      service_id: string | null
      primary_customer_id: string | null
      service_name_snapshot: string | null
    }> = []
    if (movementAppointmentIds.length > 0) {
      const { data: rows, error: movementAppointmentsError } = await client
        .from('appointments')
        .select('id,public_code,status,start_at,end_at,service_id,primary_customer_id,service_name_snapshot')
        .in('id', [...new Set(movementAppointmentIds)])
      if (movementAppointmentsError) throw new Error('ADMIN_RECENT_MOVEMENT_APPOINTMENTS_QUERY_FAILED')
      movementAppointments = rows ?? []
    }

    const allAppointmentRows = [...recentRows, ...movementAppointments]
    const customerIds = [...new Set(allAppointmentRows.map((row) => row.primary_customer_id).filter(Boolean))] as string[]
    const serviceIds = [...new Set(allAppointmentRows.map((row) => row.service_id).filter(Boolean))] as string[]

    let recentCustomers: Array<{ id: string; name: string | null }> = []
    if (customerIds.length > 0) {
      const { data: customers, error: customersError } = await client
        .from('customers')
        .select('id,name')
        .in('id', customerIds)
      if (customersError) throw new Error('ADMIN_RECENT_APPOINTMENT_CUSTOMERS_QUERY_FAILED')
      recentCustomers = customers ?? []
    }

    let recentServices: Array<{ id: string; name: string; operation_scope: string | null }> = []
    if (serviceIds.length > 0) {
      const { data: services, error: servicesError } = await client
        .from('services')
        .select('id,name,operation_scope')
        .in('id', serviceIds)
      if (servicesError) throw new Error('ADMIN_RECENT_APPOINTMENT_SERVICES_QUERY_FAILED')
      recentServices = services ?? []
    }

    const customerNames = new Map(recentCustomers.map((row) => [row.id, row.name]))
    const servicesById = new Map(recentServices.map((row) => [row.id, row]))
    const movementAppointmentsById = new Map(movementAppointments.map((row) => [row.id, row]))

    output.recent_appointments = recentRows
      .map((row) => {
        const service = row.service_id ? servicesById.get(row.service_id) : null
        return {
          id: row.id,
          public_code: row.public_code,
          status: row.status,
          start_at: row.start_at,
          end_at: row.end_at,
          created_at: row.created_at,
          origin: row.origin,
          customer_name: row.primary_customer_id ? customerNames.get(row.primary_customer_id) ?? null : null,
          service_name: row.service_name_snapshot || service?.name || null,
          operation_scope: service?.operation_scope ?? null,
        }
      })
      .filter((row) => !operationScope || row.operation_scope === operationScope)
      .slice(0, 5)

    output.recent_movements = movementRows
      .map((row) => {
        const appointment = movementAppointmentsById.get(String(row.entity_id))
        if (!appointment) return null
        const service = appointment.service_id ? servicesById.get(appointment.service_id) : null
        const movement = {
          id: row.id,
          appointment_id: appointment.id,
          public_code: appointment.public_code,
          action: row.action,
          occurred_at: row.created_at,
          customer_name: appointment.primary_customer_id ? customerNames.get(appointment.primary_customer_id) ?? null : null,
          service_name: appointment.service_name_snapshot || service?.name || null,
          operation_scope: service?.operation_scope ?? null,
          old_start_at: row.action === 'APPOINTMENT_RESCHEDULED' ? objectValue(row.before_json, 'start_at') : null,
          new_start_at: row.action === 'APPOINTMENT_RESCHEDULED' ? objectValue(row.after_json, 'start_at') : null,
          current_start_at: appointment.start_at,
          current_end_at: appointment.end_at,
        }
        return movement
      })
      .filter((row): row is NonNullable<typeof row> => row !== null)
      .filter((row) => !operationScope || row.operation_scope === operationScope)
      .slice(0, 10)

    if (canSeeFinance) {
      let openQuery = client.from('appointment_open_balances').select('*').order('start_at', { ascending: true }).limit(200)
      if (operationScope) openQuery = openQuery.eq('operation_scope', operationScope)
      const { data: balances, error: balanceError } = await openQuery
      if (balanceError) throw new Error('ADMIN_OPEN_BALANCES_QUERY_FAILED')

      const current: unknown[] = Array.isArray(output.pending_items) ? output.pending_items : []
      output.pending_items = [
        ...current,
        ...(balances ?? []).map((row) => ({
          kind: 'BALANCE_DUE_PENDING',
          entity_type: 'APPOINTMENT',
          entity_id: row.appointment_id,
          appointment_id: row.appointment_id,
          customer_id: row.customer_id,
          customer_name: row.customer_name,
          service_id: row.service_id,
          service_name: row.service_name,
          operation_scope: row.operation_scope,
          status: row.financial_status,
          start_at: row.start_at,
          amount_paid: row.paid_value,
          amount_due: row.balance_value,
          total_value: row.total_value,
          collection_id: row.active_collection_id,
          collection_sequence: row.collection_sequence,
          expires_at: row.collection_expires_at,
        })),
      ]
      return json(output)
    }

    return json(redactFinancialPendingItems(output))
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_DASHBOARD_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403 : 400
    return json({ error: { code } }, status)
  }
})