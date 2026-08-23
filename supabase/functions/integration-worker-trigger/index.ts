import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0'
import {
  assertGitHubWorkerClaims,
  GITHUB_OIDC_ISSUER,
  GITHUB_WORKER_AUDIENCE,
} from '../_shared/github-oidc.ts'

const WORKER_TIMEOUT_MS = 20_000
const GITHUB_JWKS = createRemoteJWKSet(
  new URL('https://token.actions.githubusercontent.com/.well-known/jwks'),
)

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  })
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

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const token = bearerToken(req)
    const { payload } = await jwtVerify(token, GITHUB_JWKS, {
      issuer: GITHUB_OIDC_ISSUER,
      audience: GITHUB_WORKER_AUDIENCE,
    })
    assertGitHubWorkerClaims(payload as Record<string, unknown>)

    const base = requiredEnv('SUPABASE_URL').replace(/\/$/, '')
    const internalSecret = requiredEnv('INTEGRATION_INTERNAL_SECRET')
    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), WORKER_TIMEOUT_MS)
    let response: Response
    try {
      response = await fetch(`${base}/functions/v1/integration-worker`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-internal-secret': internalSecret,
        },
        body: '{}',
        signal: controller.signal,
      })
    } catch (error) {
      if (error instanceof DOMException && error.name === 'AbortError') {
        console.error('Scheduled integration worker timed out')
        return json({ ok: false, error: { code: 'INTEGRATION_WORKER_TIMEOUT' } }, 504)
      }
      console.error('Scheduled integration worker network failure')
      return json({ ok: false, error: { code: 'INTEGRATION_WORKER_NETWORK_ERROR' } }, 502)
    } finally {
      clearTimeout(timeout)
    }

    const text = await response.text()
    let workerResult: unknown = null
    try {
      workerResult = text ? JSON.parse(text) : null
    } catch {
      workerResult = { parse_error: true }
    }

    if (!response.ok) {
      console.error('Scheduled integration worker failed', { status: response.status })
      return json({ ok: false, error: { code: 'INTEGRATION_WORKER_FAILED' }, worker_status: response.status }, 502)
    }

    return json({ ok: true, worker_status: response.status, worker: workerResult })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'GITHUB_OIDC_INVALID'
    console.error('Integration worker trigger rejected', { code: message.split(':')[0] })
    const status = message.startsWith('MISSING_ENV') ? 503 : 401
    return json({ error: { code: message.split(':')[0] } }, status)
  }
})
