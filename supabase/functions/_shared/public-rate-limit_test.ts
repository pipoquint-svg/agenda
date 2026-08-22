import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { enforceDistributedPublicRateLimit, publicClientKey } from './public-rate-limit.ts'

Deno.test('publicClientKey prefers trusted proxy-style IP headers', () => {
  const req = new Request('https://example.test', {
    headers: {
      'cf-connecting-ip': '203.0.113.10',
      'x-forwarded-for': '198.51.100.1, 198.51.100.2',
      'user-agent': 'test-agent',
    },
  })
  if (publicClientKey(req) !== 'ip:203.0.113.10') throw new Error('unexpected client key')
})

Deno.test('publicClientKey falls back without storing raw request object', () => {
  const req = new Request('https://example.test', { headers: { 'user-agent': 'test-agent' } })
  if (publicClientKey(req) !== 'missing-ip:ua:test-agent') throw new Error('unexpected fallback key')
})

Deno.test('enforceDistributedPublicRateLimit calls shared database counter', async () => {
  let called = false
  const client = {
    rpc: async (name: string, args: Record<string, unknown>) => {
      called = true
      if (name !== 'service_consume_public_rate_limit') throw new Error('wrong rpc')
      if (args.p_scope !== 'TEST_SCOPE') throw new Error('wrong scope')
      if (args.p_client_key !== 'ip:203.0.113.20') throw new Error('wrong client key')
      if (args.p_limit !== 3 || args.p_window_seconds !== 600) throw new Error('wrong policy')
      return { data: { allowed: true }, error: null }
    },
  } as unknown as SupabaseClient

  await enforceDistributedPublicRateLimit(
    client,
    new Request('https://example.test', { headers: { 'x-forwarded-for': '203.0.113.20' } }),
    { scope: 'TEST_SCOPE', limit: 3, windowSeconds: 600 },
  )
  if (!called) throw new Error('rpc not called')
})

Deno.test('enforceDistributedPublicRateLimit preserves RATE_LIMITED', async () => {
  const client = {
    rpc: async () => ({ data: null, error: { message: 'RATE_LIMITED' } }),
  } as unknown as SupabaseClient

  let code = ''
  try {
    await enforceDistributedPublicRateLimit(
      client,
      new Request('https://example.test'),
      { scope: 'TEST_SCOPE', limit: 3, windowSeconds: 600 },
    )
  } catch (error) {
    code = error instanceof Error ? error.message : String(error)
  }
  if (code !== 'RATE_LIMITED') throw new Error(`unexpected code: ${code}`)
})
