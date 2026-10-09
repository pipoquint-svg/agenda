import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0'
import { adminClient } from '../_shared/supabase.ts'
import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { renderNotificationMessage } from '../_shared/notification-email.ts'
import { assertGitHubWorkforceClaims, GITHUB_OIDC_ISSUER, GITHUB_WORKFORCE_AUDIENCE } from '../_shared/github-oidc.ts'
import { runWorkforceDeliveryCycle, type CycleResult, type OutgoingEmail } from '../_shared/workforce-delivery.ts'

// Public HTTP boundary of the Jornada por Exceção scheduler (spec §13).
// Only the pinned main-branch workflow of pipoquint-svg/agenda can invoke it
// (GitHub OIDC, dedicated audience); it then runs one idempotent SQL cycle and
// sends what was claimed through the central Resend provider.
const GITHUB_JWKS = createRemoteJWKSet(new URL('https://token.actions.githubusercontent.com/.well-known/jwks'))

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8' } })
}

function bearerToken(req: Request): string {
  const match = (req.headers.get('authorization') ?? '').match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('GITHUB_OIDC_REQUIRED')
  return match[1]
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const { payload } = await jwtVerify(bearerToken(req), GITHUB_JWKS, {
      issuer: GITHUB_OIDC_ISSUER,
      audience: GITHUB_WORKFORCE_AUDIENCE,
    })
    assertGitHubWorkforceClaims(payload as Record<string, unknown>)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'GITHUB_OIDC_INVALID'
    console.error('Workforce delivery trigger rejected', { code })
    return json({ error: { code: /^[A-Z0-9_]+$/.test(code) ? code : 'GITHUB_OIDC_INVALID' } }, 401)
  }

  try {
    const client = adminClient()
    const sender = notificationSenderForScope('BLACKSHEEP')
    if (!sender) throw new Error('WORKFORCE_SENDER_UNAVAILABLE')

    const summary = await runWorkforceDeliveryCycle({
      runCycle: async () => {
        const { data, error } = await client.rpc('service_workforce_system_run_cycle')
        if (error) throw new Error('WORKFORCE_CYCLE_FAILED')
        return data as CycleResult
      },
      recordResult: async (kind, id, success, providerMessageId, errorCode) => {
        const { error } = await client.rpc('service_workforce_system_record_send_result', {
          p_kind: kind,
          p_id: id,
          p_success: success,
          p_provider_message_id: providerMessageId,
          p_error_code: errorCode,
        })
        if (error) throw new Error('WORKFORCE_RECORD_RESULT_FAILED')
      },
      send: (email: OutgoingEmail, idempotencyKey: string) => {
        const message = renderNotificationMessage(
          { id: 'workforce', title_template: '{{subject}}', body_template: '{{body}}', variable_schema: { subject: {}, body: {} } },
          { subject: email.subject, body: email.text },
          sender.brandName,
        )
        const providerPayload: EmailProviderPayload = {
          from: sender.from,
          to: [email.to],
          subject: message.subject,
          text: message.text,
          html: message.html,
          ...(email.attachments ? { attachments: email.attachments } : {}),
        }
        if (sender.replyTo) providerPayload.reply_to = sender.replyTo
        return sendEmailWithProvider(providerPayload, idempotencyKey)
      },
    })
    return json({ ok: true, ...summary })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'WORKFORCE_DELIVERY_FAILED'
    console.error('Workforce delivery cycle failed', { code })
    return json({ error: { code: /^[A-Z0-9_]+$/.test(code) ? code : 'WORKFORCE_DELIVERY_FAILED' } }, 502)
  }
})
