import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0'
import { adminClient } from '../_shared/supabase.ts'
import {
  assertGitHubWorkerClaims,
  GITHUB_OIDC_ISSUER,
  GITHUB_WORKER_AUDIENCE,
} from '../_shared/github-oidc.ts'

const WORKER_TIMEOUT_MS = 90_000
const GITHUB_JWKS = createRemoteJWKSet(new URL('https://token.actions.githubusercontent.com/.well-known/jwks'))

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json; charset=utf-8' } })
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function bearerToken(req: Request): string {
  const header = req.headers.get('authorization') ?? ''
  const match = header.match(/^Bearer\s+(.+)$/i)
  if (!match) throw new Error('GITHUB_OIDC_REQUIRED')
  return match[1]
}

async function authorizeTrigger(req: Request): Promise<'GITHUB_OIDC' | 'SUPABASE_DB_CRON'> {
  const cronSecret = req.headers.get('x-db-cron-secret')?.trim() ?? ''
  if (cronSecret) {
    const { data, error } = await adminClient().rpc('service_verify_integration_worker_db_cron_secret', {
      p_secret: cronSecret,
    })
    if (!error && data === true) return 'SUPABASE_DB_CRON'
    throw new Error('DB_CRON_AUTH_INVALID')
  }

  const token = bearerToken(req)
  const { payload } = await jwtVerify(token, GITHUB_JWKS, {
    issuer: GITHUB_OIDC_ISSUER,
    audience: GITHUB_WORKER_AUDIENCE,
  })
  assertGitHubWorkerClaims(payload as Record<string, unknown>)
  return 'GITHUB_OIDC'
}

async function invokeWorker(base: string, internalSecret: string, name: string): Promise<{ status: number; result: unknown }> {
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), WORKER_TIMEOUT_MS)
  try {
    const response = await fetch(`${base}/functions/v1/${name}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-internal-secret': internalSecret },
      body: '{}',
      signal: controller.signal,
    })
    const text = await response.text()
    let result: unknown = null
    try { result = text ? JSON.parse(text) : null } catch { result = { parse_error: true } }
    if (!response.ok) throw new Error(`${name.toUpperCase().replaceAll('-','_')}_HTTP_${response.status}`)
    return { status: response.status, result }
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error(`${name.toUpperCase().replaceAll('-','_')}_TIMEOUT`)
    throw error
  } finally { clearTimeout(timeout) }
}

function settledResult(result: PromiseSettledResult<{ status: number; result: unknown }>) {
  if (result.status === 'fulfilled') return { ok: true, result: result.value.result }
  const message = result.reason instanceof Error ? result.reason.message : 'UNKNOWN_ERROR'
  return { ok: false, error: message.split(':')[0] }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
  try {
    const source = await authorizeTrigger(req)
    const base = requiredEnv('SUPABASE_URL').replace(/\/$/, '')
    const internalSecret = requiredEnv('INTEGRATION_INTERNAL_SECRET')
    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const target = typeof body.target === 'string' ? body.target.trim().toUpperCase() : ''

    if (target) {
      if (target !== 'BALANCE') throw new Error('TRIGGER_TARGET_INVALID')
      const balance = await Promise.allSettled([
        invokeWorker(base, internalSecret, 'balance-collection-worker'),
      ])
      const balanceWorker = settledResult(balance[0])
      return json({ ok: balanceWorker.ok, source, target, balance_worker: balanceWorker }, balanceWorker.ok ? 200 : 502)
    }

    const [integration, infinitePayWebhook, balance, mercadoPagoReconcile] = await Promise.allSettled([
      invokeWorker(base, internalSecret, 'integration-worker'),
      invokeWorker(base, internalSecret, 'infinitepay-webhook-worker'),
      invokeWorker(base, internalSecret, 'balance-collection-worker'),
      invokeWorker(base, internalSecret, 'mercado-pago-reconcile'),
    ])

    const results = {
      integration_worker: settledResult(integration),
      infinitepay_webhook_worker: settledResult(infinitePayWebhook),
      balance_worker: settledResult(balance),
      mercado_pago_reconcile: settledResult(mercadoPagoReconcile),
    }
    const ok = Object.values(results).every((item) => item.ok)
    return json({ ok, source, ...results }, ok ? 200 : 502)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'TRIGGER_AUTH_INVALID'
    console.error('Integration worker trigger rejected', { code: message.split(':')[0] })
    const status = message.startsWith('MISSING_ENV') ? 503
      : message.includes('_HTTP_') || message.includes('_TIMEOUT') ? 502
      : 401
    return json({ error: { code: message.split(':')[0] } }, status)
  }
})
