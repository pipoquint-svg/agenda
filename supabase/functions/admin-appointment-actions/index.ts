import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'
import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info, x-request-id',
  'access-control-allow-methods': 'POST, OPTIONS',
}

type RefundPlanPayment = {
  parent_transaction_id: string
  provider_payment_id: string
  method: string
  available_cash: number | string
  refund_cash: number | string
}

type RefundPlan = {
  policy_action_id: string
  appointment_id: string
  status: string
  target_cash_amount: number | string
  recorded_refund_cash: number | string
  remaining_refund_cash: number | string
  mercado_pago_available_cash: number | string
  manual_refund_cash: number | string
  payments: RefundPlanPayment[]
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown, code = 'APPOINTMENT_ID_INVALID'): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) throw new Error(code)
  return next
}

function authorshipEvidence(req: Request) {
  const ip = (req.headers.get('cf-connecting-ip') ?? req.headers.get('x-real-ip') ?? req.headers.get('x-forwarded-for')?.split(',')[0] ?? '').trim()
  const userAgent = (req.headers.get('user-agent') ?? '').trim()
  const requestId = (req.headers.get('x-request-id') ?? crypto.randomUUID()).trim()
  if (!ip || !userAgent || !requestId) throw new Error('AUTHORSHIP_ADMIN_EVIDENCE_REQUIRED')
  return { ip, userAgent, requestId }
}

function requestEvidence(req: Request, body: Record<string, unknown>) {
  const evidence = authorshipEvidence(req)
  const reference = typeof body.admin_request_reference === 'string' ? body.admin_request_reference.trim().slice(0, 500) : ''
  if (!reference) throw new Error('BALANCE_ADMIN_REQUEST_EVIDENCE_REQUIRED')
  return { ...evidence, reference }
}

async function stableIdempotencyKey(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input)
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  return Array.from(digest).map((value) => value.toString(16).padStart(2, '0')).join('')
}

function refundSnapshot(raw: Record<string, unknown>): Record<string, unknown> {
  const amount = Number(raw.amount)
  return {
    id: raw.id == null ? null : String(raw.id),
    payment_id: raw.payment_id == null ? null : String(raw.payment_id),
    amount: Number.isFinite(amount) ? amount : null,
    status: raw.status == null ? null : String(raw.status),
    date_created: raw.date_created == null ? null : String(raw.date_created),
  }
}

function providerFinancialMutationRuntime() {
  // Refunds mutate real provider money just like charge creation. Reuse the same
  // environment-scoped credential + explicit production gate so a generic token can
  // never authorize a real refund by accident.
  return mercadoPagoRuntime({
    environment: Deno.env.get('MERCADO_PAGO_ENV'),
    accessToken: Deno.env.get('MERCADO_PAGO_ACCESS_TOKEN'),
    sandboxAccessToken: Deno.env.get('MERCADO_PAGO_SANDBOX_ACCESS_TOKEN'),
    productionAccessToken: Deno.env.get('MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN'),
    allowRealCharges: Deno.env.get('ALLOW_REAL_CHARGES'),
    creatingCharge: true,
  })
}

async function mercadoPagoRefund(input: {
  paymentId: string
  amount: number
  fullAvailableAmount: number
  idempotencyKey: string
}): Promise<{ status: number; data: Record<string, unknown> }> {
  const runtime = providerFinancialMutationRuntime()
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)
  try {
    const fullRefund = Math.abs(input.amount - input.fullAvailableAmount) <= 0.01
    const response = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(input.paymentId)}/refunds`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${runtime.accessToken}`,
        accept: 'application/json',
        'content-type': 'application/json',
        'x-idempotency-key': input.idempotencyKey,
      },
      body: fullRefund ? undefined : JSON.stringify({ amount: input.amount }),
      signal: controller.signal,
    })
    const data = await response.json().catch(() => ({})) as Record<string, unknown>
    return { status: response.status, data }
  } finally {
    clearTimeout(timer)
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const body = await req.json() as Record<string, unknown>
    const action = typeof body.action === 'string' ? body.action.trim().toUpperCase() : ''
    const client = adminClient()
    const requirePermission = async (permission: string) => {
      if (!(await hasAdminPermission(admin.adminId, permission))) throw new Error('ADMIN_PERMISSION_DENIED')
    }

    if (action === 'CANCEL') {
      await requirePermission('AGENDA_MANAGE')
      const appointmentId = uuid(body.appointment_id)
      const requestedChoice = body.settlement_choice === null || body.settlement_choice === undefined || body.settlement_choice === ''
        ? null
        : String(body.settlement_choice).trim().toUpperCase()
      if (requestedChoice !== null && requestedChoice !== 'REFUND' && requestedChoice !== 'CUSTOMER_BALANCE') {
        throw new Error(requestedChoice === 'CREDIT' ? 'LEGACY_CANCELLATION_CREDIT_REMOVED' : 'INVALID_CANCELLATION_SETTLEMENT')
      }
      if (requestedChoice === 'CUSTOMER_BALANCE') await requirePermission('FINANCE_MANAGE')

      const reason = typeof body.reason === 'string' ? body.reason.trim().slice(0, 500) : null
      const authorship = authorshipEvidence(req)
      const { data, error } = await client.rpc('service_admin_cancel_appointment_evidenced', {
        p_appointment_id: appointmentId,
        p_settlement_choice: null,
        p_reason: reason || null,
        p_requested_at: new Date().toISOString(),
        p_change_origin: 'OPERATION',
        p_admin_id: admin.adminId,
        p_ip: authorship.ip,
        p_user_agent: authorship.userAgent,
        p_request_id: authorship.requestId,
        p_session_id: null,
      })
      if (error) throw new Error(error.message)
      const cancellation = data as Record<string, unknown>

      // Refund remains the safe default. Only an explicit, evidenced ADMIN_UI
      // choice can convert the pending return into indefinite customer balance.
      if (requestedChoice === 'CUSTOMER_BALANCE' && Number(cancellation.refund_amount ?? 0) > 0) {
        const evidence = requestEvidence(req, body)
        const { data: balanceData, error: balanceError } = await client.rpc('service_credit_customer_balance_from_return', {
          p_appointment_id: appointmentId,
          p_policy_action_id: String(cancellation.policy_action_id),
          p_choice_origin: 'ADMIN_UI',
          p_admin_id: admin.adminId,
          p_ip: evidence.ip,
          p_user_agent: evidence.userAgent,
          p_request_id: evidence.requestId,
          p_admin_request_reference: evidence.reference,
        })
        if (balanceError) throw new Error(balanceError.message)
        return json({ ...cancellation, settlement_choice: 'CUSTOMER_BALANCE', customer_balance: balanceData })
      }

      return json(cancellation)
    }

    if (action === 'REQUEST_BALANCE_REFUND') {
      await requirePermission('FINANCE_MANAGE')
      const customerId = uuid(body.customer_id, 'CUSTOMER_ID_INVALID')
      const evidence = requestEvidence(req, body)
      const { data, error } = await client.rpc('service_request_customer_balance_refund', {
        p_customer_id: customerId,
        p_choice_origin: 'ADMIN_UI',
        p_admin_id: admin.adminId,
        p_ip: evidence.ip,
        p_user_agent: evidence.userAgent,
        p_request_id: evidence.requestId,
        p_admin_request_reference: evidence.reference,
      })
      if (error) throw new Error(error.message)
      return json(data)
    }

    if (action === 'PROCESS_REFUND') {
      await requirePermission('FINANCE_MANAGE')
      const policyActionId = uuid(body.policy_action_id, 'POLICY_ACTION_ID_INVALID')
      const { data: initialData, error: initialError } = await client.rpc('service_get_cancellation_refund_plan', {
        p_policy_action_id: policyActionId,
      })
      if (initialError) throw new Error(initialError.message)
      const initial = initialData as RefundPlan
      const results: Array<Record<string, unknown>> = []

      for (const payment of initial.payments ?? []) {
        const refundCash = Number(payment.refund_cash)
        const availableCash = Number(payment.available_cash)
        if (!Number.isFinite(refundCash) || refundCash <= 0) continue
        if (!Number.isFinite(availableCash) || availableCash < refundCash) throw new Error('REFUND_PLAN_INVALID')

        const idempotencyKey = await stableIdempotencyKey(
          `cancel-refund:${policyActionId}:${payment.parent_transaction_id}:${refundCash.toFixed(2)}`,
        )

        let provider: { status: number; data: Record<string, unknown> }
        try {
          provider = await mercadoPagoRefund({
            paymentId: payment.provider_payment_id,
            amount: refundCash,
            fullAvailableAmount: availableCash,
            idempotencyKey,
          })
        } catch (cause) {
          const causeCode = cause instanceof Error ? cause.message.split(':')[0] : 'MERCADO_PAGO_REFUND_PROVIDER_ERROR'
          console.error('[OPERATION_ALERT] MERCADO_PAGO_REFUND_UNAVAILABLE', { code: causeCode })
          return json({ error: { code: 'MERCADO_PAGO_REFUND_TEMPORARY_FAILURE' }, policy_action_id: policyActionId, completed: results }, 503)
        }

        const snapshot = refundSnapshot(provider.data)
        if (provider.status < 200 || provider.status >= 300) {
          return json({
            error: { code: provider.status >= 500 ? 'MERCADO_PAGO_REFUND_TEMPORARY_FAILURE' : 'MERCADO_PAGO_REFUND_REJECTED', provider: { http_status: provider.status, ...snapshot } },
            policy_action_id: policyActionId,
            completed: results,
          }, provider.status >= 500 ? 503 : 422)
        }

        const providerRefundId = typeof snapshot.id === 'string' ? snapshot.id : ''
        const providerPaymentId = typeof snapshot.payment_id === 'string' ? snapshot.payment_id : ''
        const providerAmount = Number(snapshot.amount)
        if (!providerRefundId || providerPaymentId !== payment.provider_payment_id) throw new Error('MERCADO_PAGO_REFUND_ID_MISMATCH')
        if (!Number.isFinite(providerAmount) || Math.abs(providerAmount - refundCash) > 0.01) throw new Error('MERCADO_PAGO_REFUND_AMOUNT_MISMATCH')

        const { data: recorded, error: recordError } = await client.rpc('service_record_cancellation_provider_refund', {
          p_policy_action_id: policyActionId,
          p_parent_transaction_id: payment.parent_transaction_id,
          p_provider_refund_id: providerRefundId,
          p_cash_amount: refundCash,
          p_provider_payload_json: snapshot,
        })
        if (recordError) throw new Error(recordError.message)
        results.push(recorded as Record<string, unknown>)
      }

      const { data: finalData, error: finalError } = await client.rpc('service_get_cancellation_refund_plan', { p_policy_action_id: policyActionId })
      if (finalError) throw new Error(finalError.message)
      const finalPlan = finalData as RefundPlan
      return json({
        policy_action_id: policyActionId,
        appointment_id: finalPlan.appointment_id,
        refund_status: finalPlan.status,
        refunded_now: results,
        remaining_refund_cash: finalPlan.remaining_refund_cash,
        manual_refund_cash: finalPlan.manual_refund_cash,
        completed: Number(finalPlan.remaining_refund_cash) <= 0.01,
      })
    }

    throw new Error('APPOINTMENT_ACTION_INVALID')
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_APPOINTMENT_ACTION_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED' ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code.startsWith('MISSING_ENV') || code === 'REAL_CHARGES_DISABLED' || code === 'MERCADO_PAGO_ENV_INVALID' ? 503
      : 400
    return json({ error: { code } }, status)
  }
})
