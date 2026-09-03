import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0'
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

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
  try {
    const token = bearerToken(req)
    const { payload } = await jwtVerify(token, GITHUB_JWKS, { issuer: GITHUB_OIDC_ISSUER, audience: GITHUB_WORKER_AUDIENCE })
    assertGitHubWorkerClaims(payload as Record<string, unknown>)

    const base = requiredEnv('SUPABASE_URL').replace(/\/$/, '')
    const internalSecret = requiredEnv('INTEGRATION_INTERNAL_SECRET')
    const integration = await invokeWorker(base, internalSecret, 'integration-worker')
    const balance = await invokeWorker(base, internalSecret, 'balance-collection-worker')
    const mercadoPagoReconcile = await invokeWorker(base, internalSecret, 'mercado-pago-reconcile')
    return json({
      ok: true,
      integration_worker: integration.result,
      balance_worker: balance.result,
      mercado_pago_reconcile: mercadoPagoReconcile.result,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'GITHUB_OIDC_INVALID'
    console.error('Integration worker trigger rejected', { code: message.split(':')[0] })
    const status = message.startsWith('MISSING_ENV') ? 503 : message.includes('_HTTP_') || message.includes('_TIMEOUT') ? 502 : 401
    return json({ error: { code: message.split(':')[0] } }, status)
  }
})
