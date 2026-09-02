import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'
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

      const { data: cancellation, error: cancellationError } = await client.rpc('service_client_cancel_appointment_evidenced', {
        p_token_id: tokenId,
        p_reason: text(body.reason, 500),
        p_requested_at: accessedAt,
        p_ip: ip,
        p_user_agent: agent,
        p_request_id: id,
        p_session_id: text(body.session_id, 200),
      })
      if (cancellationError) throw new Error(cancellationError.message)
      await minimumDelay(startedAt)
      return json({ data: cancellation })
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
