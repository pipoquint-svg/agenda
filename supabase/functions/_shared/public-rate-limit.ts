import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'

export type PublicRateLimitPolicy = {
  scope: string
  limit: number
  windowSeconds: number
}

export function publicClientKey(req: Request): string {
  const forwarded = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? ''
  const ip = req.headers.get('cf-connecting-ip')?.trim()
    || forwarded
    || req.headers.get('x-real-ip')?.trim()
    || ''

  if (ip) return `ip:${ip}`

  const userAgent = (req.headers.get('user-agent') ?? '').trim().slice(0, 200)
  return userAgent ? `missing-ip:ua:${userAgent}` : 'missing-ip:unknown'
}

export async function enforceDistributedPublicRateLimit(
  client: SupabaseClient,
  req: Request,
  policy: PublicRateLimitPolicy,
): Promise<void> {
  const { error } = await client.rpc('service_consume_public_rate_limit', {
    p_scope: policy.scope,
    p_client_key: publicClientKey(req),
    p_limit: policy.limit,
    p_window_seconds: policy.windowSeconds,
  })

  if (!error) return
  if (error.message.includes('RATE_LIMITED')) throw new Error('RATE_LIMITED')
  throw new Error(`RATE_LIMIT_BACKEND_FAILED:${error.message}`)
}
