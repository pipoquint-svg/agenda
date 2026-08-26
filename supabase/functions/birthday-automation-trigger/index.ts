import { createRemoteJWKSet, jwtVerify } from 'npm:jose@6.1.0'
import { adminClient } from '../_shared/supabase.ts'
import {
  assertGitHubBirthdayClaims,
  GITHUB_BIRTHDAY_AUDIENCE,
  GITHUB_OIDC_ISSUER,
} from '../_shared/github-oidc.ts'

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

export function saoPauloDate(now = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(now)
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${values.year}-${values.month}-${values.day}`
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const token = bearerToken(req)
    const { payload } = await jwtVerify(token, GITHUB_JWKS, {
      issuer: GITHUB_OIDC_ISSUER,
      audience: GITHUB_BIRTHDAY_AUDIENCE,
    })
    assertGitHubBirthdayClaims(payload as Record<string, unknown>)

    const runDate = saoPauloDate()
    const client = adminClient()
    const { data, error } = await client.rpc('run_birthday_automation', { p_run_date: runDate })
    if (error) throw new Error(`BIRTHDAY_AUTOMATION_RPC_FAILED:${error.code ?? 'UNKNOWN'}`)

    return json({ ok: true, run_date: runDate, result: data })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'GITHUB_OIDC_INVALID'
    console.error('Birthday automation trigger rejected', { code: message.split(':')[0] })
    const status = message.startsWith('BIRTHDAY_AUTOMATION_RPC_FAILED') ? 502 : 401
    return json({ error: { code: message.split(':')[0] } }, status)
  }
})
