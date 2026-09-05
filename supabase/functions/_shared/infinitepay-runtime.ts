export type InfinitePayRuntime = {
  handle: string
  redirectUrl: string | null
  liveLinksEnabled: boolean
}

type RuntimeRpcClient = {
  rpc: (name: string, args?: Record<string, unknown>) => PromiseLike<{
    data: unknown
    error: { message?: string } | null
  }>
}

function clean(value: string | undefined | null): string {
  return (value ?? '').trim()
}

function enabled(value: string | undefined | null): boolean {
  return clean(value).toLowerCase() === 'true'
}

function optionalEnv(name: string): string {
  try {
    return clean(Deno.env.get(name))
  } catch {
    return ''
  }
}

function validHandle(value: string): string {
  const handle = clean(value).replace(/^\$/, '')
  if (!/^[A-Za-z0-9._-]{2,80}$/.test(handle)) throw new Error('INFINITEPAY_HANDLE_INVALID')
  return handle
}

function validRedirectUrl(value: string): string {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    throw new Error('INFINITEPAY_REDIRECT_URL_INVALID')
  }
  if (url.protocol !== 'https:') throw new Error('INFINITEPAY_REDIRECT_URL_INVALID')
  return url.toString()
}

/**
 * Pure fail-closed runtime boundary. Explicit inputs are used by the database-backed
 * loader below; environment fallback is retained only for isolated tests/backward
 * compatibility and is no longer used by the production InfinitePay Edge Functions.
 */
export function infinitePayRuntime(input: {
  handle?: string | null
  redirectUrl?: string | null
  liveLinksEnabled?: string | null
  creatingLink?: boolean
} = {}): InfinitePayRuntime {
  const handleRaw = input.handle !== undefined ? clean(input.handle) : optionalEnv('INFINITEPAY_HANDLE')
  if (!handleRaw) throw new Error('MISSING_ENV:INFINITEPAY_HANDLE')
  const handle = validHandle(handleRaw)

  const live = input.liveLinksEnabled !== undefined
    ? enabled(input.liveLinksEnabled)
    : enabled(optionalEnv('INFINITEPAY_LIVE_LINKS_ENABLED'))

  const redirectRaw = input.redirectUrl !== undefined
    ? clean(input.redirectUrl)
    : optionalEnv('INFINITEPAY_REDIRECT_URL')

  if (input.creatingLink === true) {
    if (!live) throw new Error('INFINITEPAY_LIVE_LINKS_DISABLED')
    if (!redirectRaw) throw new Error('MISSING_ENV:INFINITEPAY_REDIRECT_URL')
    return { handle, redirectUrl: validRedirectUrl(redirectRaw), liveLinksEnabled: true }
  }

  return {
    handle,
    redirectUrl: redirectRaw ? validRedirectUrl(redirectRaw) : null,
    liveLinksEnabled: live,
  }
}

export function infinitePayRuntimeFromRecord(
  value: unknown,
  options: { creatingLink?: boolean } = {},
): InfinitePayRuntime {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('INFINITEPAY_RUNTIME_CONFIG_INVALID')
  }
  const row = value as Record<string, unknown>
  if (typeof row.handle !== 'string') throw new Error('INFINITEPAY_RUNTIME_CONFIG_INVALID')
  if (typeof row.redirect_url !== 'string') throw new Error('INFINITEPAY_RUNTIME_CONFIG_INVALID')
  if (typeof row.live_links_enabled !== 'boolean') throw new Error('INFINITEPAY_RUNTIME_CONFIG_INVALID')

  return infinitePayRuntime({
    handle: row.handle,
    redirectUrl: row.redirect_url,
    liveLinksEnabled: row.live_links_enabled ? 'true' : 'false',
    creatingLink: options.creatingLink === true,
  })
}

export async function loadInfinitePayRuntime(
  client: RuntimeRpcClient,
  options: { creatingLink?: boolean } = {},
): Promise<InfinitePayRuntime> {
  const { data, error } = await client.rpc('service_get_infinitepay_runtime_config')
  if (error) {
    const message = String(error.message ?? '')
    if (message.includes('INFINITEPAY_RUNTIME_CONFIG_MISSING')) {
      throw new Error('INFINITEPAY_RUNTIME_CONFIG_MISSING')
    }
    throw new Error('INFINITEPAY_RUNTIME_CONFIG_LOAD_FAILED')
  }
  return infinitePayRuntimeFromRecord(data, options)
}
