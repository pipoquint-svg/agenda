import { adminClient, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
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
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error(code)
  }
  return next
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
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

async function mercadoPagoRefund(input: {
  paymentId: string
  amount: number
  fullAvailableAmount: number
  idempotencyKey: string
}): Promise<{ status: number; data: Record<string, unknown> }> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)
  try {
    const fullRefund = Math.abs(input.amount - input.fullAvailableAmount) <= 0.01
    const response = await fetch(`https://api.mercadopago.com/v1/payments/${encodeURIComponent(input.paymentId)}/refunds`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${requiredEnv('MERCADO_PAGO_ACCESS_TOKEN')}`,
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
    const body = await req.json()
    const action = typeof body?.action === 'string' ? body.action.trim().toUpperCase() : ''
    const admin = await requireAdmin(req, action === 'PROCESS_REFUND' ? 'FINANCE' : 'AGENDA')
    const client = adminClient()
    const canSeeFinance = admin.role === 'OWNER' || admin.permissions.FINANCE === true

    if (action === 'CANCEL') {
      const appointmentId = uuid(body?.appointment_id)
      const settlement = body?.settlement_choice === null || body?.settlement_choice === undefined || body?.settlement_choice === ''
        ? null
        : String(body.settlement_choice).trim().toUpperCase()
      if (settlement !== null && settlement !== 'REFUND' && settlement !== 'CREDIT') {
        throw new Error('INVALID_CANCELLATION_SETTLEMENT')
      }
      if (!canSeeFinance && settlement !== null) throw new Error('ADMIN_MODULE_ACCESS_DENIED')

      const reason = typeof body?.reason === 'string' ? body.reason.trim().slice(0, 500) : null
      const { data, error } = await client.rpc('service_admin_cancel_appointment', {
        p_appointment_id: appointmentId,
        p_settlement_choice: settlement,
        p_reason: reason || null,
        p_requested_at: new Date().toISOString(),
        p_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      if (!canSeeFinance && data && typeof data === 'object') {
        return json({
          appointment_id: (data as Record<string, unknown>).appointment_id,
          status: (data as Record<string, unknown>).status,
          cancellation_status: (data as Record<string, unknown>).cancellation_status,
          google_sync_enqueued: (data as Record<string, unknown>).google_sync_enqueued,
        })
      }
      return json(data)
    }

    if (action === 'PROCESS_REFUND') {
      const policyActionId = uuid(body?.policy_action_id, 'POLICY_ACTION_ID_INVALID')
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
          console.error('Mercado Pago refund unavailable', cause)
          return json({
            error: { code: 'MERCADO_PAGO_REFUND_TEMPORARY_FAILURE' },
            policy_action_id: policyActionId,
            completed: results,
          }, 503)
        }

        const snapshot = refundSnapshot(provider.data)
        if (provider.status < 200 || provider.status >= 300) {
          return json({
            error: {
              code: provider.status >= 500 ? 'MERCADO_PAGO_REFUND_TEMPORARY_FAILURE' : 'MERCADO_PAGO_REFUND_REJECTED',
              provider: { http_status: provider.status, ...snapshot },
            },
            policy_action_id: policyActionId,
            completed: results,
          }, provider.status >= 500 ? 503 : 422)
        }

        const providerRefundId = typeof snapshot.id === 'string' ? snapshot.id : ''
        const providerPaymentId = typeof snapshot.payment_id === 'string' ? snapshot.payment_id : ''
        const providerAmount = Number(snapshot.amount)
        if (!providerRefundId || providerPaymentId !== payment.provider_payment_id) {
          throw new Error('MERCADO_PAGO_REFUND_ID_MISMATCH')
        }
        if (!Number.isFinite(providerAmount) || Math.abs(providerAmount - refundCash) > 0.01) {
          throw new Error('MERCADO_PAGO_REFUND_AMOUNT_MISMATCH')
        }

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

      const { data: finalData, error: finalError } = await client.rpc('service_get_cancellation_refund_plan', {
        p_policy_action_id: policyActionId,
      })
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
      : code === 'ADMIN_MODULE_ACCESS_DENIED' ? 403
      : code.startsWith('MISSING_ENV') ? 503
      : 400
    return json({ error: { code } }, status)
  }
})