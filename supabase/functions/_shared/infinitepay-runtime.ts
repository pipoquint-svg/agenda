export type InfinitePayRuntime = {
  handle: string
  redirectUrl: string | null
  liveLinksEnabled: boolean
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
 * Fail-closed runtime boundary for InfinitePay.
 *
 * Reading/verifying an already-created checkout requires only the merchant handle.
 * Creating a new hosted checkout additionally requires an explicit live-links flag
 * and an HTTPS return URL. Gate 2 deliberately does not configure either in production.
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
