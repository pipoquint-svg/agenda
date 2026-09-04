import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0'
import { notificationSenderForScope, sendEmailWithProvider } from '../_shared/email-provider.ts'
import {
  assertGitHubOpsAlertClaims,
  GITHUB_OIDC_ISSUER,
  GITHUB_OPS_ALERT_AUDIENCE,
} from '../_shared/github-oidc.ts'
import { runOpsAlertCycle } from '../_shared/ops-alerts.ts'
import { adminClient } from '../_shared/supabase.ts'

const GITHUB_JWKS = createRemoteJWKSet(new URL('https://token.actions.githubusercontent.com/.well-known/jwks'))

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  })
}

function bearerToken(req: Request): string {
  const header = req.headers.get('authorization') ?? ''
  const match = header.match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('GITHUB_OIDC_REQUIRED')
  return match[1]
}

function alertRecipient(): string {
  const value = Deno.env.get('OPS_ALERT_RECIPIENT_EMAIL')?.trim()
    || Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP')?.trim()
    || ''
  if (!value || !value.includes('@')) throw new Error('OPS_ALERT_RECIPIENT_MISSING')
  return value
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value))
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, '0')).join('')
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const { payload } = await jwtVerify(bearerToken(req), GITHUB_JWKS, {
      issuer: GITHUB_OIDC_ISSUER,
      audience: GITHUB_OPS_ALERT_AUDIENCE,
    })
    assertGitHubOpsAlertClaims(payload as Record<string, unknown>)

    const sender = notificationSenderForScope('BLACKSHEEP')
    if (!sender) throw new Error('OPS_ALERT_SENDER_MISSING')
    const recipient = alertRecipient()
    const now = new Date()
    const result = await runOpsAlertCycle(adminClient(), {
      now,
      send: async (email, incidents) => {
        const fingerprintHash = await sha256(incidents.map((item) => item.fingerprint).sort().join('|'))
        const dedupBucket = Math.floor(now.getTime() / (60 * 60 * 1000))
        return await sendEmailWithProvider({
          from: sender.from,
          to: [recipient],
          subject: email.subject,
          text: email.text,
          html: email.html,
          ...(sender.replyTo ? { reply_to: sender.replyTo } : {}),
        }, `ops-alert:${dedupBucket}:${fingerprintHash}`)
      },
    })

    return json({ ok: true, ...result })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'OPS_ALERT_MONITOR_FAILED'
    console.error('Ops alert monitor failed', { code })
    const status = code.startsWith('GITHUB_OIDC_') ? 401 : 502
    return json({ error: { code } }, status)
  }
})
