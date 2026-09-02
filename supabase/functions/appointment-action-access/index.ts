import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'
import { mercadoPagoRuntime } from '../_shared/mercado-pago-runtime.ts'
import {
  actionAccessRemainingDelay,
  isActionOperationAllowed,
  mapActionAccessError,
  PERSONAL_LINK_WARNING,
} from '../_shared/action-token-security.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'authorization, apikey, content-type, x-appointment-token, x-request-id, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
  'cache-control': 'no-store, max-age=0',
}

const actionScopes = new Set(['CANCEL', 'RESCHEDULE', 'EDIT_DETAILS', 'EDIT_EXTRAS'])
const operations = new Set([
  'RESOLVE', 'VERIFY_EMAIL',
  'CANCEL_PREVIEW', 'EXECUTE_CANCEL',
  'RESCHEDULE_SLOTS', 'RESCHEDULE_CREATE_HOLD', 'EXECUTE_RESCHEDULE',
])

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

type RefundAttempt = {
  completed: boolean
  processing: boolean
  remaining_refund_cash: number
  refunded_amount: number
  code: string | null
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function actionToken(req: Request): string {
  const value = req.headers.get('x-appointment-token')?.trim() ?? ''
  if (value.length < 32 || value.length > 500) throw new Error('LINK_INVALID_OR_EXPIRED')
  return value
}

function actionScope(value: unknown): string {
  const scope = typeof value === 'string' ? value.trim().toUpperCase() : ''
  if (!actionScopes.has(scope)) throw new Error('LINK_INVALID_OR_EXPIRED')
  return scope
}

function enforceOperationScope(operation: string, scope: string): void {
  if (!isActionOperationAllowed(operation, scope)) throw new Error('LINK_INVALID_OR_EXPIRED')
}

function requestId(req: Request): string {
  const supplied = req.headers.get('x-request-id')?.trim() ?? ''
  return supplied ? supplied.slice(0, 200) : crypto.randomUUID()
}

function clientIp(req: Request): string | null {
  const value = req.headers.get('cf-connecting-ip')?.trim()
    || req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()
    || req.headers.get('x-real-ip')?.trim()
    || ''
  if (!value || value.length > 64) return null
  return value
}

function userAgent(req: Request): string | null {
  const value = req.headers.get('user-agent')?.trim() ?? ''
  return value ? value.slice(0, 1000) : null
}

function text(value: unknown, limit: number): string | null {
  const next = typeof value === 'string' ? value.trim().slice(0, limit) : ''
  return next || null
}

function localDate(value: unknown): string {
  const next = text(value, 10) ?? ''
  if (!/^\d{4}-\d{2}-\d{2}$/.test(next)) throw new Error('RESCHEDULE_DATE_INVALID')
  return next
}

function isoDateTime(value: unknown): string {
  const next = text(value, 80) ?? ''
  const parsed = new Date(next)
  if (!next || Number.isNaN(parsed.getTime())) throw new Error('RESCHEDULE_TIME_INVALID')
  return parsed.toISOString()
}

function uuid(value: unknown): string {
  const next = text(value, 64) ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error('CLIENT_RESCHEDULE_ACTION_INVALID')
  }
  return next
}

function numeric(value: unknown): number {
  const next = Number(value ?? 0)
  return Number.isFinite(next) ? Math.round(next * 100) / 100 : 0
}

function financialRescheduleConsequence(value: Record<string, unknown>): boolean {
  return numeric(value.penalty_retained) > 0.005
    || Math.abs(numeric(value.new_contract_value) - numeric(value.contract_value)) > 0.005
    || numeric(value.difference_due) > 0.005
}

async function minimumDelay(startedAt: number): Promise<void> {
  const remaining = actionAccessRemainingDelay(startedAt)
  if (remaining > 0) await new Promise((resolve) => setTimeout(resolve, remaining))
}

async function stableIdempotencyKey(input: string): Promise<string> {
  const bytes = new TextEncoder().encode(input)
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes))
  return Array.from(digest).map((value) => value.toString(16).padStart(2, '0')).join('')
}

function orderRefundSnapshot(raw: Record<string, unknown>, transactionId: string): Record<string, unknown> {
  const transactions = raw.transactions && typeof raw.transactions === 'object'
    ? raw.transactions as Record<string, unknown>
    : {}
  const refunds = Array.isArray(transactions.refunds) ? transactions.refunds : []
  const matched = refunds.find((item) => item && typeof item === 'object' && String((item as Record<string, unknown>).transaction_id ?? '') === transactionId)
    ?? refunds[0]
  const refund = matched && typeof matched === 'object' ? matched as Record<string, unknown> : {}
  const amount = Number(refund.amount)
  return {
    id: refund.id == null ? null : String(refund.id),
    payment_id: refund.transaction_id == null ? null : String(refund.transaction_id),
    amount: Number.isFinite(amount) ? amount : null,
    status: refund.status == null ? null : String(refund.status),
    date_created: refund.date_created == null ? null : String(refund.date_created),
    order_id: raw.id == null ? null : String(raw.id),
    order_status: raw.status == null ? null : String(raw.status),
    order_status_detail: raw.status_detail == null ? null : String(raw.status_detail),
  }
}

function providerFinancialMutationRuntime() {
  return mercadoPagoRuntime({
    environment: Deno.env.get('MERCADO_PAGO_ENV'),
    productionAccessToken: Deno.env.get('MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN'),
    allowRealCharges: Deno.env.get('ALLOW_REAL_CHARGES'),
    creatingCharge: true,
  })
}

async function mercadoPagoRefund(input: {
  orderId: string
  transactionId: string
  amount: number
  fullAvailableAmount: number
  idempotencyKey: string
}): Promise<{ status: number; data: Record<string, unknown> }> {
  const runtime = providerFinancialMutationRuntime()
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), 15000)
  try {
    const fullRefund = Math.abs(input.amount - input.fullAvailableAmount) <= 0.01
    const response = await fetch(`https://api.mercadopago.com/v1/orders/${encodeURIComponent(input.orderId)}/refund`, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${runtime.accessToken}`,
        accept: 'application/json',
        'content-type': 'application/json',
        'x-idempotency-key': input.idempotencyKey,
      },
      body: fullRefund ? undefined : JSON.stringify({
        transactions: [{ id: input.transactionId, amount: input.amount.toFixed(2) }],
      }),
      signal: controller.signal,
    })
    const data = await response.json().catch(() => ({})) as Record<string, unknown>
    return { status: response.status, data }
  } finally {
    clearTimeout(timer)
  }
}

async function notifyRefundCompleted(input: {
  appointmentId: string
  policyActionId: string
  refundAmount: number
}): Promise<void> {
  const baseUrl = (Deno.env.get('SUPABASE_URL') ?? '').replace(/\/+$/, '')
  const internalSecret = Deno.env.get('INTEGRATION_INTERNAL_SECRET') ?? ''
  if (!baseUrl || !internalSecret || input.refundAmount <= 0) return
  try {
    const response = await fetch(`${baseUrl}/functions/v1/email-send`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-internal-secret': internalSecret,
      },
      body: JSON.stringify({
        reason: 'REFUND_COMPLETED',
        appointment_id: input.appointmentId,
        policy_action_id: input.policyActionId,
        refund_amount: input.refundAmount,
      }),
    })
    if (!response.ok) console.error('[OPERATION_ALERT] CLIENT_REFUND_COMPLETED_NOTIFICATION_FAILED', { status: response.status })
  } catch {
    console.error('[OPERATION_ALERT] CLIENT_REFUND_COMPLETED_NOTIFICATION_FAILED')
  }
}

async function processClientRefund(client: ReturnType<typeof adminClient>, policyActionId: string): Promise<RefundAttempt> {
  const { data: initialData, error: initialError } = await client.rpc('service_get_cancellation_refund_plan', {
    p_policy_action_id: policyActionId,
  })
  if (initialError) {
    console.error('[OPERATION_ALERT] CLIENT_REFUND_PLAN_FAILED', { policy_action_id: policyActionId })
    return { completed: false, processing: false, remaining_refund_cash: 0, refunded_amount: 0, code: 'REFUND_PLAN_FAILED' }
  }

  const initial = initialData as RefundPlan
  const results: Array<Record<string, unknown>> = []
  let providerCode: string | null = null
  let processing = false

  for (const payment of initial.payments ?? []) {
    const refundCash = numeric(payment.refund_cash)
    const availableCash = numeric(payment.available_cash)
    if (refundCash <= 0) continue
    if (availableCash + 0.01 < refundCash) {
      providerCode = 'REFUND_PLAN_INVALID'
      break
    }

    const { data: parent, error: parentError } = await client
      .from('payment_transactions')
      .select('provider_payment_id, provider_payload_json')
      .eq('id', payment.parent_transaction_id)
      .single()
    if (parentError) {
      providerCode = 'REFUND_PAYMENT_LOOKUP_FAILED'
      break
    }

    const payload = parent?.provider_payload_json && typeof parent.provider_payload_json === 'object'
      ? parent.provider_payload_json as Record<string, unknown>
      : {}
    const orderId = String(parent?.provider_payment_id ?? payload.id ?? '').trim()
    const transactionId = String(payment.provider_payment_id ?? '').trim()
    if (!orderId || !transactionId) {
      providerCode = 'MERCADO_PAGO_REFUND_IDENTIFIERS_MISSING'
      break
    }

    const idempotencyKey = await stableIdempotencyKey(`client-cancel-order-refund:${policyActionId}:${payment.parent_transaction_id}:${refundCash.toFixed(2)}`)
    let provider: { status: number; data: Record<string, unknown> }
    try {
      provider = await mercadoPagoRefund({ orderId, transactionId, amount: refundCash, fullAvailableAmount: availableCash, idempotencyKey })
    } catch {
      providerCode = 'MERCADO_PAGO_REFUND_TEMPORARY_FAILURE'
      break
    }

    if (provider.status < 200 || provider.status >= 300) {
      providerCode = provider.status >= 500 || provider.status === 423 || provider.status === 425 || provider.status === 429
        ? 'MERCADO_PAGO_REFUND_TEMPORARY_FAILURE'
        : 'MERCADO_PAGO_REFUND_REJECTED'
      break
    }

    const snapshot = orderRefundSnapshot(provider.data, transactionId)
    const providerRefundId = typeof snapshot.id === 'string' ? snapshot.id : ''
    const providerPaymentId = typeof snapshot.payment_id === 'string' ? snapshot.payment_id : ''
    const providerAmount = Number(snapshot.amount)
    const providerRefundStatus = String(snapshot.status ?? '').toLowerCase()

    if (!providerRefundId || providerPaymentId !== transactionId) {
      providerCode = 'MERCADO_PAGO_REFUND_ID_MISMATCH'
      break
    }
    if (!Number.isFinite(providerAmount) || Math.abs(providerAmount - refundCash) > 0.01) {
      providerCode = 'MERCADO_PAGO_REFUND_AMOUNT_MISMATCH'
      break
    }
    if (providerRefundStatus && !['processed', 'approved', 'refunded'].includes(providerRefundStatus)) {
      providerCode = 'MERCADO_PAGO_REFUND_PROCESSING'
      processing = true
      break
    }

    const { data: recorded, error: recordError } = await client.rpc('service_record_cancellation_provider_refund', {
      p_policy_action_id: policyActionId,
      p_parent_transaction_id: payment.parent_transaction_id,
      p_provider_refund_id: providerRefundId,
      p_cash_amount: refundCash,
      p_provider_payload_json: snapshot,
    })
    if (recordError) {
      providerCode = 'REFUND_RECORD_FAILED'
      break
    }
    results.push(recorded as Record<string, unknown>)
  }

  const { data: finalData, error: finalError } = await client.rpc('service_get_cancellation_refund_plan', {
    p_policy_action_id: policyActionId,
  })
  if (finalError) {
    return { completed: false, processing, remaining_refund_cash: numeric(initial.remaining_refund_cash), refunded_amount: numeric(initial.recorded_refund_cash), code: providerCode ?? 'REFUND_PLAN_REFRESH_FAILED' }
  }

  const finalPlan = finalData as RefundPlan
  const completed = numeric(finalPlan.remaining_refund_cash) <= 0.01
  const refundedAmount = numeric(finalPlan.recorded_refund_cash)
  if (completed && refundedAmount > 0) {
    await notifyRefundCompleted({
      appointmentId: finalPlan.appointment_id,
      policyActionId,
      refundAmount: refundedAmount,
    })
  }

  return {
    completed,
    processing,
    remaining_refund_cash: numeric(finalPlan.remaining_refund_cash),
    refunded_amount: refundedAmount,
    code: completed ? null : providerCode,
  }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  const startedAt = Date.now()
  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'ACTION_TOKEN_ACCESS',
      limit: 60,
      windowSeconds: 600,
    })

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const operation = typeof body.operation === 'string' ? body.operation.trim().toUpperCase() : 'RESOLVE'
    if (!operations.has(operation)) throw new Error('ACTION_OPERATION_INVALID')

    const scope = actionScope(body.scope)
    enforceOperationScope(operation, scope)
    const token = actionToken(req)
    const id = requestId(req)
    const ip = clientIp(req)
    const agent = userAgent(req)
    const accessedAt = new Date().toISOString()

    const { data: resolved, error: resolveError } = await client.rpc('service_resolve_appointment_action_token', {
      p_access_token: token,
      p_required_scope: scope,
      p_ip_address: ip,
      p_user_agent: agent,
      p_request_id: id,
    })
    if (resolveError) throw new Error(resolveError.message)

    const row = resolved && typeof resolved === 'object' ? resolved as Record<string, unknown> : {}
    const tokenId = typeof row.token_id === 'string' ? row.token_id : ''
    const appointmentId = typeof row.appointment_id === 'string' ? row.appointment_id : ''
    const expiresAt = typeof row.expires_at === 'string' ? row.expires_at : null
    if (!tokenId || !appointmentId) throw new Error('LINK_INVALID_OR_EXPIRED')

    if (operation === 'RESOLVE') {
      let summary: Record<string, unknown> | null = null
      if (scope === 'CANCEL' || scope === 'RESCHEDULE') {
        const { data: safeSummary, error: summaryError } = await client.rpc('service_appointment_action_public_summary', {
          p_token_id: tokenId,
        })
        if (summaryError) throw new Error(summaryError.message)
        summary = safeSummary && typeof safeSummary === 'object'
          ? safeSummary as Record<string, unknown>
          : null
      }

      await minimumDelay(startedAt)
      return json({
        data: {
          valid: true,
          scope,
          expires_at: expiresAt,
          accessed_at: accessedAt,
          warning: PERSONAL_LINK_WARNING,
          summary,
        },
      })
    }

    if (operation === 'CANCEL_PREVIEW') {
      const { data: preview, error: previewError } = await client.rpc('calculate_reservation_change', {
        p_appointment_id: appointmentId,
        p_action_type: 'CANCEL',
        p_requested_at: accessedAt,
        p_change_origin: 'CLIENT',
        p_new_contract_value: null,
      })
      if (previewError) throw new Error(previewError.message)
      const financial = preview && typeof preview === 'object' ? preview as Record<string, unknown> : {}
      const refundAmount = numeric(financial.refund_due)
      await minimumDelay(startedAt)
      return json({
        data: {
          valid: true,
          scope: 'CANCEL',
          expires_at: expiresAt,
          accessed_at: accessedAt,
          warning: PERSONAL_LINK_WARNING,
          requires_explicit_confirmation: true,
          requires_email_verification: true,
          financial: {
            contract_value: numeric(financial.contract_value),
            paid_amount: numeric(financial.customer_funds_before),
            penalty_amount: numeric(financial.penalty_retained),
            refund_amount: refundAmount,
            settlement_default: refundAmount > 0 ? 'REFUND' : null,
          },
        },
      })
    }

    if (operation === 'RESCHEDULE_SLOTS') {
      const date = localDate(body.local_date)
      const { data: slots, error: slotsError } = await client.rpc('service_admin_list_reschedule_slots', {
        p_appointment_id: appointmentId,
        p_local_date: date,
      })
      if (slotsError) throw new Error(slotsError.message)
      await minimumDelay(startedAt)
      return json({
        data: {
          valid: true,
          scope: 'RESCHEDULE',
          local_date: date,
          slots: Array.isArray(slots) ? slots : [],
          expires_at: expiresAt,
          accessed_at: accessedAt,
          warning: PERSONAL_LINK_WARNING,
        },
      })
    }

    if (operation === 'RESCHEDULE_CREATE_HOLD') {
      const requestedStartAt = isoDateTime(body.requested_start_at)
      const { data: created, error: createError } = await client.rpc('service_admin_create_reschedule_hold', {
        p_appointment_id: appointmentId,
        p_requested_start_at: requestedStartAt,
        p_requested_at: accessedAt,
        p_change_origin: 'CLIENT',
        p_admin_id: null,
      })
      if (createError) throw new Error(createError.message)
      const proposal = created && typeof created === 'object' ? created as Record<string, unknown> : {}
      const differenceDue = numeric(proposal.difference_due)
      await minimumDelay(startedAt)
      return json({
        data: {
          policy_action_id: proposal.policy_action_id,
          new_slot: proposal.new_slot,
          requires_explicit_confirmation: true,
          requires_email_verification: financialRescheduleConsequence(proposal),
          requires_payment: differenceDue > 0.005,
          financial: {
            contract_value: numeric(proposal.contract_value),
            new_contract_value: numeric(proposal.new_contract_value),
            penalty_amount: numeric(proposal.penalty_retained),
            difference_due: differenceDue,
            excess_amount: numeric(proposal.excess_amount),
          },
        },
      })
    }

    const email = text(body.email, 320)

    if (operation === 'VERIFY_EMAIL') {
      if (!email) {
        await minimumDelay(startedAt)
        return json({ error: { code: 'ACTION_VERIFICATION_FAILED' }, data: { verified: false } }, 400)
      }
      const { data: verified, error: verifyError } = await client.rpc('service_verify_appointment_action_email', {
        p_token_id: tokenId,
        p_email: email,
        p_ip_address: ip,
        p_user_agent: agent,
        p_request_id: id,
      })
      if (verifyError) throw new Error(verifyError.message)
      await minimumDelay(startedAt)
      return verified === true
        ? json({ data: { verified: true } })
        : json({ error: { code: 'ACTION_VERIFICATION_FAILED' }, data: { verified: false } }, 400)
    }

    if (operation === 'EXECUTE_CANCEL') {
      if (!email) {
        await minimumDelay(startedAt)
        return json({ error: { code: 'ACTION_VERIFICATION_FAILED' }, data: { verified: false } }, 400)
      }
      if (body.confirmed !== true) throw new Error('CANCEL_CONFIRMATION_REQUIRED')

      const settlementChoice = String(body.settlement_choice ?? '').trim().toUpperCase()
      if (!['REFUND', 'CUSTOMER_BALANCE'].includes(settlementChoice)) {
        await minimumDelay(startedAt)
        return json({ error: { code: 'ACTION_REQUEST_INVALID' } }, 400)
      }

      const { data: verified, error: verifyError } = await client.rpc('service_verify_appointment_action_email', {
        p_token_id: tokenId,
        p_email: email,
        p_ip_address: ip,
        p_user_agent: agent,
        p_request_id: id,
      })
      if (verifyError) throw new Error(verifyError.message)
      if (verified !== true) {
        await minimumDelay(startedAt)
        return json({ error: { code: 'ACTION_VERIFICATION_FAILED' }, data: { verified: false } }, 400)
      }

      const { data: cancellation, error: cancellationError } = await client.rpc('service_client_cancel_appointment_evidenced_v2', {
        p_token_id: tokenId,
        p_settlement_choice: settlementChoice,
        p_reason: text(body.reason, 500),
        p_requested_at: accessedAt,
        p_ip: ip,
        p_user_agent: agent,
        p_request_id: id,
        p_session_id: text(body.session_id, 200),
      })
      if (cancellationError) throw new Error(cancellationError.message)

      const result = cancellation && typeof cancellation === 'object'
        ? cancellation as Record<string, unknown>
        : {}
      const policyActionId = String(result.policy_action_id ?? '').trim()
      const returnableAmount = numeric(result.returnable_amount)

      if (settlementChoice === 'CUSTOMER_BALANCE' && returnableAmount > 0.005) {
        result.message = 'Sua reserva foi cancelada. O valor devolvível foi mantido como crédito BlackSheep.'
        await minimumDelay(startedAt)
        return json({ data: result })
      }

      if (settlementChoice === 'REFUND' && returnableAmount > 0.005 && policyActionId) {
        const refund = await processClientRefund(client, policyActionId)
        result.refund = refund
        result.message = refund.completed
          ? 'Sua reserva foi cancelada e o estorno foi processado.'
          : refund.processing
            ? 'Sua reserva foi cancelada. O estorno foi solicitado e está em processamento pelo meio de pagamento.'
            : 'Sua reserva foi cancelada. O estorno ficou pendente de confirmação do meio de pagamento.'
      } else {
        result.message = 'Sua reserva foi cancelada.'
      }

      await minimumDelay(startedAt)
      return json({ data: result })
    }

    if (body.confirmed !== true) throw new Error('RESCHEDULE_CONFIRMATION_REQUIRED')
    const policyActionId = uuid(body.policy_action_id)
    const { data: requirements, error: requirementsError } = await client.rpc('service_client_reschedule_requirements', {
      p_token_id: tokenId,
      p_policy_action_id: policyActionId,
    })
    if (requirementsError) throw new Error(requirementsError.message)
    const requirement = requirements && typeof requirements === 'object' ? requirements as Record<string, unknown> : {}

    if (requirement.requires_payment === true) {
      await minimumDelay(startedAt)
      return json({
        error: { code: 'ACTION_PAYMENT_REQUIRED' },
        data: {
          outstanding_difference: numeric(requirement.outstanding_difference),
          hold_expires_at: requirement.hold_expires_at ?? null,
        },
      }, 409)
    }

    if (requirement.requires_email_verification === true) {
      if (!email) {
        await minimumDelay(startedAt)
        return json({ error: { code: 'ACTION_VERIFICATION_FAILED' }, data: { verified: false } }, 400)
      }
      const { data: verified, error: verifyError } = await client.rpc('service_verify_appointment_action_email', {
        p_token_id: tokenId,
        p_email: email,
        p_ip_address: ip,
        p_user_agent: agent,
        p_request_id: id,
      })
      if (verifyError) throw new Error(verifyError.message)
      if (verified !== true) {
        await minimumDelay(startedAt)
        return json({ error: { code: 'ACTION_VERIFICATION_FAILED' }, data: { verified: false } }, 400)
      }
    }

    const { data: rescheduled, error: rescheduleError } = await client.rpc('service_client_apply_reschedule_evidenced', {
      p_token_id: tokenId,
      p_policy_action_id: policyActionId,
      p_ip: ip,
      p_user_agent: agent,
      p_request_id: id,
      p_session_id: text(body.session_id, 200),
    })
    if (rescheduleError) throw new Error(rescheduleError.message)

    await minimumDelay(startedAt)
    return json({ data: rescheduled })
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'ACTION_ACCESS_FAILED'
    const mapped = mapActionAccessError(raw)
    await minimumDelay(startedAt)
    return json({ error: { code: mapped.code } }, mapped.status)
  }
})
