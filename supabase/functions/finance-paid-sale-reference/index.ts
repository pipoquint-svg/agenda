import { adminClient } from '../_shared/supabase.ts'
import {
  FINANCE_PAID_SALE_CONTRACT,
  firstQualifyingPaidSaleCharge,
  normalizePaidSaleReference,
  summarizeRefunds,
  type FinanceChargeRow,
  type FinanceRefundRow,
} from './contract.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, x-dracma-finance-secret, x-request-id',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function uuid(value: unknown, code: string): string {
  const id = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) throw new Error(code)
  return id
}

function positiveLeadId(value: unknown): number {
  const parsed = Number(value)
  if (!Number.isSafeInteger(parsed) || parsed <= 0) throw new Error('FINANCE_EXTERNAL_LEAD_ID_INVALID')
  return parsed
}

function requireMachineAuth(req: Request): void {
  const expected = requiredEnv('DRACMA_FINANCE_REFERENCE_SECRET')
  const supplied = req.headers.get('x-dracma-finance-secret')?.trim() ?? ''
  if (!supplied || supplied !== expected) throw new Error('FINANCE_REFERENCE_AUTH_REQUIRED')
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    requireMachineAuth(req)
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const organizationId = uuid(body.organization_id, 'FINANCE_ORGANIZATION_ID_INVALID')
    const externalLeadId = positiveLeadId(body.external_lead_id)

    const allowedOrganizationId = uuid(
      requiredEnv('DRACMA_FINANCE_ALLOWED_ORGANIZATION_ID'),
      'FINANCE_ALLOWED_ORGANIZATION_ID_INVALID',
    )
    if (organizationId !== allowedOrganizationId) throw new Error('FINANCE_REFERENCE_ORGANIZATION_FORBIDDEN')

    const tenantId = uuid(requiredEnv('DRACMA_FINANCE_TENANT_ID'), 'FINANCE_TENANT_ID_INVALID')
    const client = adminClient()

    const { count: activeTenantCount, error: tenantCountError } = await client
      .from('tenants')
      .select('id', { count: 'exact', head: true })
      .eq('status', 'ACTIVE')
    if (tenantCountError) throw new Error('FINANCE_TENANT_COUNT_FAILED')
    if (activeTenantCount !== 1) throw new Error('FINANCE_ADAPTER_UNSCOPED_MULTI_TENANT_BLOCKED')

    const { data: tenant, error: tenantError } = await client
      .from('tenants')
      .select('id,status')
      .eq('id', tenantId)
      .eq('status', 'ACTIVE')
      .maybeSingle()
    if (tenantError) throw new Error('FINANCE_TENANT_LOOKUP_FAILED')
    if (!tenant) throw new Error('FINANCE_TENANT_MAPPING_INVALID')

    const { data: links, error: linksError } = await client
      .from('kommo_appointment_links')
      .select('appointment_id')
      .eq('kommo_lead_id', externalLeadId)
    if (linksError) throw new Error('FINANCE_APPOINTMENT_LINK_LOOKUP_FAILED')

    const appointmentIds = [...new Set((links ?? []).map((row) => String(row.appointment_id ?? '')).filter(Boolean))]
    if (appointmentIds.length === 0) {
      return json({
        contract: FINANCE_PAID_SALE_CONTRACT,
        authority: 'finance',
        adapter: 'agenda',
        state: 'GAP',
        gap_reason: 'AGENDA_APPOINTMENT_LINK_NOT_FOUND',
        organization_id: organizationId,
        adapter_tenant_id: tenantId,
        external_lead_id: String(externalLeadId),
      })
    }

    const { data: appointments, error: appointmentsError } = await client
      .from('appointments')
      .select('id,is_test')
      .in('id', appointmentIds)
      .eq('is_test', false)
    if (appointmentsError) throw new Error('FINANCE_APPOINTMENT_LOOKUP_FAILED')

    const realAppointmentIds = (appointments ?? []).map((row) => String(row.id ?? '')).filter(Boolean)
    if (realAppointmentIds.length === 0) {
      return json({
        contract: FINANCE_PAID_SALE_CONTRACT,
        authority: 'finance',
        adapter: 'agenda',
        state: 'GAP',
        gap_reason: 'ONLY_TEST_APPOINTMENTS_LINKED',
        organization_id: organizationId,
        adapter_tenant_id: tenantId,
        external_lead_id: String(externalLeadId),
      })
    }

    const { data: charges, error: chargesError } = await client
      .from('payment_transactions')
      .select('id,appointment_id,transaction_type,payment_purpose,status,contract_amount_settled,requested_payment_kind,paid_at,provider,method,is_test')
      .in('appointment_id', realAppointmentIds)
      .eq('transaction_type', 'CHARGE')
      .eq('payment_purpose', 'CONTRACT')
      .in('status', ['APPROVED', 'PARTIALLY_REFUNDED', 'REFUNDED'])
      .eq('is_test', false)
      .not('paid_at', 'is', null)
      .gt('contract_amount_settled', 0)
      .order('paid_at', { ascending: true })
      .order('id', { ascending: true })
    if (chargesError) throw new Error('FINANCE_PAYMENT_LOOKUP_FAILED')

    const charge = firstQualifyingPaidSaleCharge((charges ?? []) as FinanceChargeRow[])
    if (!charge) {
      return json({
        contract: FINANCE_PAID_SALE_CONTRACT,
        authority: 'finance',
        adapter: 'agenda',
        state: 'GAP',
        gap_reason: 'QUALIFYING_PAYMENT_NOT_FOUND',
        organization_id: organizationId,
        adapter_tenant_id: tenantId,
        external_lead_id: String(externalLeadId),
      })
    }

    const { data: refunds, error: refundsError } = await client
      .from('payment_transactions')
      .select('contract_amount_settled,transaction_type,payment_purpose,status,is_test')
      .eq('parent_transaction_id', charge.id)
      .eq('transaction_type', 'REFUND')
      .eq('payment_purpose', 'CONTRACT')
      .in('status', ['APPROVED', 'REFUNDED'])
      .eq('is_test', false)
    if (refundsError) throw new Error('FINANCE_REFUND_LOOKUP_FAILED')

    const chargeAmount = Number(charge.contract_amount_settled)
    return json(normalizePaidSaleReference(
      organizationId,
      tenantId,
      externalLeadId,
      charge,
      summarizeRefunds(chargeAmount, (refunds ?? []) as FinanceRefundRow[]),
    ))
  } catch (error) {
    const code = error instanceof Error ? error.message : 'FINANCE_REFERENCE_FAILED'
    const status = code === 'FINANCE_REFERENCE_AUTH_REQUIRED' ? 401
      : code === 'FINANCE_REFERENCE_ORGANIZATION_FORBIDDEN' ? 403
      : code.startsWith('FINANCE_') && (code.endsWith('_INVALID') || code.endsWith('_REQUIRED')) ? 400
      : code === 'FINANCE_ADAPTER_UNSCOPED_MULTI_TENANT_BLOCKED' ? 409
      : 500
    return json({ error: { code } }, status)
  }
})
