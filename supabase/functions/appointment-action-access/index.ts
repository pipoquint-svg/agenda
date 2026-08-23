import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, x-appointment-token, x-request-id, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
  'cache-control': 'no-store, max-age=0',
}

const actionScopes = new Set(['CANCEL', 'RESCHEDULE', 'EDIT_DETAILS', 'EDIT_EXTRAS'])
const operations = new Set(['RESOLVE', 'VERIFY_EMAIL', 'CANCEL_PREVIEW', 'EXECUTE_CANCEL'])
const minimumResponseMs = 120
const personalLinkWarning = 'link pessoal, válido por tempo limitado, não encaminhe'

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

function numeric(value: unknown): number {
  const next = Number(value ?? 0)
  return Number.isFinite(next) ? Math.round(next * 100) / 100 : 0
}

async function minimumDelay(startedAt: number): Promise<void> {
  const remaining = minimumResponseMs - (Date.now() - startedAt)
  if (remaining > 0) await new Promise((resolve) => setTimeout(resolve, remaining))
}

function genericTokenError(raw: string): { code: string; status: number } {
  if (raw === 'RATE_LIMITED') return { code: 'ACTION_ACCESS_RATE_LIMITED', status: 429 }
  if (raw.startsWith('RATE_LIMIT_BACKEND_FAILED')) return { code: 'ACTION_ACCESS_TEMPORARY_FAILURE', status: 503 }
  if (raw.includes('CANCEL_CONFIRMATION_REQUIRED')) return { code: 'ACTION_CONFIRMATION_REQUIRED', status: 400 }
  if (raw.includes('CANCEL_EMAIL_VERIFICATION_REQUIRED')) return { code: 'ACTION_VERIFICATION_REQUIRED', status: 400 }
  if (
    raw.includes('APPOINTMENT_TOKEN_INVALID')
    || raw.includes('APPOINTMENT_TOKEN_EXPIRED')
    || raw.includes('APPOINTMENT_TOKEN_REVOKED')
    || raw.includes('TOKEN_SCOPE_DENIED')
    || raw.includes('ACTION_TOKEN_SCOPE_INVALID')
    || raw.includes('APPOINTMENT_NOT_CANCELLABLE')
    || raw.includes('LINK_INVALID_OR_EXPIRED')
  ) return { code: 'LINK_INVALID_OR_EXPIRED', status: 400 }
  return { code: 'ACTION_ACCESS_TEMPORARY_FAILURE', status: 503 }
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
      await minimumDelay(startedAt)
      return json({
        data: {
          valid: true,
          scope,
          expires_at: expiresAt,
          accessed_at: accessedAt,
          warning: personalLinkWarning,
        },
      })
    }

    if (scope !== 'CANCEL') throw new Error('LINK_INVALID_OR_EXPIRED')

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
          warning: personalLinkWarning,
          requires_explicit_confirmation: true,
          requires_email_verification: true,
          financial: {
            contract_value: numeric(financial.contract_value),
            penalty_amount: numeric(financial.penalty_retained),
            refund_amount: refundAmount,
            settlement_default: refundAmount > 0 ? 'REFUND' : null,
          },
        },
      })
    }

    const email = text(body.email, 320)
    if (!email) {
      await minimumDelay(startedAt)
      return json({ data: { verified: false } }, 400)
    }

    if (operation === 'VERIFY_EMAIL') {
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
        : json({ data: { verified: false } }, 400)
    }

    if (body.confirmed !== true) throw new Error('CANCEL_CONFIRMATION_REQUIRED')

    // The financial verification and execution deliberately share the same
    // request id. The database wrapper refuses an older VERIFIED event.
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
      return json({ data: { verified: false } }, 400)
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
  } catch (error) {
    const raw = error instanceof Error ? error.message : 'ACTION_ACCESS_FAILED'
    const mapped = raw === 'ACTION_OPERATION_INVALID'
      ? { code: 'ACTION_REQUEST_INVALID', status: 400 }
      : genericTokenError(raw)
    await minimumDelay(startedAt)
    return json({ error: { code: mapped.code } }, mapped.status)
  }
})
