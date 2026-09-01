const realFetch = globalThis.fetch.bind(globalThis)
const RESEND_ENDPOINT = 'https://api.resend.com/emails'
const LEGACY_MANAGE_PREFIX = 'https://www.blacksheepestudiocriativo.com.br/reserva/gerenciar?token='
const CANONICAL_MANAGE_PREFIX = 'https://www.blacksheepestudiocriativo.com.br/gerenciar-reserva#token='

globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
  const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url
  if (url === RESEND_ENDPOINT && typeof init?.body === 'string' && init.body.includes(LEGACY_MANAGE_PREFIX)) {
    const body = init.body.split(LEGACY_MANAGE_PREFIX).join(CANONICAL_MANAGE_PREFIX)
    return realFetch(input, { ...init, body })
  }
  return realFetch(input, init)
}

await import('./platform.ts')
