const LOCAL_ENV = 'local_verification'
const PROD_SUPABASE_REF = 'sbexdggbwqvyhbkatucs'
const LOCAL_PREFIX = 'LOCAL_ONLY_'
export const LOCAL_GOOGLE_TOKEN_ENCRYPTION_KEY = 'bG9jYWwtdmVyaWZpY2F0aW9uLWtleS0zMi1ieXRlcyE='

type FetchLike = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>
type MercadoPagoMockMode = 'success' | 'reject' | 'server_error'

const mockOrders = new Map<string, Record<string, unknown>>()
let transportInstalled = false

function clean(value: string | undefined | null): string {
  return (value ?? '').trim()
}

function safeEnv(name: string): string {
  try {
    return clean(Deno.env.get(name))
  } catch {
    return ''
  }
}

export function isLocalVerification(): boolean {
  return safeEnv('APP_ENV').toLowerCase() === LOCAL_ENV
}

function credentialKey(name: string): boolean {
  return /^(?:VITE_)?MERCADO_PAGO_.*(?:TOKEN|SECRET|KEY)$/i.test(name)
    || /^GOOGLE_.*(?:CLIENT_ID|CLIENT_SECRET|TOKEN|SECRET|KEY)$/i.test(name)
}

function looksLikeProviderCredential(value: string): boolean {
  return /(?:APP_USR-|GOCSPX-|AIza[0-9A-Za-z_-]{20,}|ya29\.)/.test(value)
}

export function assertLocalVerificationEnvironment(env: Record<string, string | undefined>): void {
  if (clean(env.APP_ENV).toLowerCase() !== LOCAL_ENV) throw new Error('LOCAL_VERIFICATION_APP_ENV_REQUIRED')

  for (const [name, raw] of Object.entries(env)) {
    const value = clean(raw)
    if (!value) continue

    if (value.toLowerCase().includes(PROD_SUPABASE_REF)) {
      throw new Error(`LOCAL_VERIFICATION_PRODUCTION_REFERENCE_FORBIDDEN:${name}`)
    }

    if (/^https:\/\/[^/]*\.supabase\.co(?:\/|$)/i.test(value)) {
      throw new Error(`LOCAL_VERIFICATION_HOSTED_SUPABASE_FORBIDDEN:${name}`)
    }

    if (looksLikeProviderCredential(value)) {
      throw new Error(`LOCAL_VERIFICATION_REAL_PROVIDER_CREDENTIAL_FORBIDDEN:${name}`)
    }

    if (credentialKey(name)) {
      if (name === 'GOOGLE_TOKEN_ENCRYPTION_KEY' && value === LOCAL_GOOGLE_TOKEN_ENCRYPTION_KEY) continue
      if (!value.startsWith(LOCAL_PREFIX)) {
        throw new Error(`LOCAL_VERIFICATION_PROVIDER_CREDENTIAL_MUST_BE_PLACEHOLDER:${name}`)
      }
    }
  }

  const mpEnv = clean(env.MERCADO_PAGO_ENV).toLowerCase()
  if (mpEnv && mpEnv !== LOCAL_ENV) throw new Error('LOCAL_VERIFICATION_MERCADO_PAGO_ENV_INVALID')
  if (clean(env.ALLOW_REAL_CHARGES).toLowerCase() === 'true') throw new Error('LOCAL_VERIFICATION_REAL_CHARGES_FORBIDDEN')
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  })
}

function paymentMethodFromOrder(body: Record<string, unknown>): Record<string, unknown> {
  const transactions = body.transactions && typeof body.transactions === 'object'
    ? body.transactions as Record<string, unknown>
    : {}
  const payments = Array.isArray(transactions.payments) ? transactions.payments : []
  const first = payments[0] && typeof payments[0] === 'object' ? payments[0] as Record<string, unknown> : {}
  const method = first.payment_method && typeof first.payment_method === 'object'
    ? first.payment_method as Record<string, unknown>
    : {}
  const id = String(method.id ?? '')
  const type = String(method.type ?? '')
  return {
    ...method,
    ...(id === 'pix' && type === 'bank_transfer'
      ? {
          qr_code: '000201LOCAL_ONLY_PIX_QR',
          qr_code_base64: 'TE9DQUxfT05MWV9QSVg=',
          ticket_url: 'http://localhost/local-verification/pix',
        }
      : {}),
  }
}

export async function mockMercadoPagoFetch(
  input: RequestInfo | URL,
  init: RequestInit = {},
  mode: MercadoPagoMockMode = 'success',
): Promise<Response> {
  const request = new Request(input, init)
  const url = new URL(request.url)

  if (mode === 'server_error') return json({ error: 'local_mock_server_error' }, 503)
  if (mode === 'reject') {
    return json({ errors: [{ code: 'local_mock_rejected' }], status_detail: 'rejected_by_local_mock' }, 422)
  }

  if (request.method === 'POST' && url.pathname === '/v1/orders') {
    const body = await request.json().catch(() => ({})) as Record<string, unknown>
    const externalReference = String(body.external_reference ?? '')
    const transactions = body.transactions && typeof body.transactions === 'object'
      ? body.transactions as Record<string, unknown>
      : {}
    const payments = Array.isArray(transactions.payments) ? transactions.payments : []
    const first = payments[0] && typeof payments[0] === 'object' ? payments[0] as Record<string, unknown> : {}
    const amount = Number(first.amount ?? body.total_amount)
    const method = paymentMethodFromOrder(body)
    const orderId = `LOCAL_${crypto.randomUUID().replaceAll('-', '')}`
    const paymentId = `LOCALPAY_${crypto.randomUUID().replaceAll('-', '')}`
    const now = new Date().toISOString()
    const order = {
      id: orderId,
      status: 'processed',
      status_detail: 'accredited',
      external_reference: externalReference,
      total_amount: Number.isFinite(amount) ? amount : body.total_amount,
      created_date: now,
      last_updated_date: now,
      transactions: {
        payments: [{
          id: paymentId,
          amount: Number.isFinite(amount) ? amount : body.total_amount,
          status: 'processed',
          status_detail: 'accredited',
          created_date: now,
          last_updated_date: now,
          payment_method: method,
        }],
      },
    }
    mockOrders.set(orderId, order)
    return json(order, 201)
  }

  const orderMatch = url.pathname.match(/^\/v1\/orders\/([^/]+)$/)
  if (request.method === 'GET' && orderMatch) {
    const order = mockOrders.get(decodeURIComponent(orderMatch[1]))
    return order ? json(order) : json({ error: 'local_mock_order_not_found' }, 404)
  }

  const refundMatch = url.pathname.match(/^\/v1\/orders\/([^/]+)\/refund$/)
  if (request.method === 'POST' && refundMatch) {
    const orderId = decodeURIComponent(refundMatch[1])
    const body = await request.json().catch(() => ({})) as Record<string, unknown>
    const txs = Array.isArray(body.transactions) ? body.transactions : []
    const first = txs[0] && typeof txs[0] === 'object' ? txs[0] as Record<string, unknown> : {}
    return json({
      id: orderId,
      status: 'processed',
      status_detail: 'refunded',
      transactions: {
        refunds: [{
          id: `LOCALREF_${crypto.randomUUID().replaceAll('-', '')}`,
          transaction_id: String(first.id ?? 'LOCALPAY_UNKNOWN'),
          amount: Number(first.amount ?? 0),
          status: 'processed',
          date_created: new Date().toISOString(),
        }],
      },
    })
  }

  return json({ error: 'local_mock_route_not_found' }, 404)
}

export async function mockGoogleFetch(input: RequestInfo | URL, init: RequestInit = {}): Promise<Response> {
  const request = new Request(input, init)
  const url = new URL(request.url)

  if (url.hostname === 'oauth2.googleapis.com' && url.pathname === '/token') {
    return json({
      access_token: 'LOCAL_ONLY_google_access_token',
      expires_in: 3600,
      refresh_token: 'LOCAL_ONLY_google_refresh_token',
      token_type: 'Bearer',
    })
  }

  if (url.hostname === 'accounts.google.com') {
    return json({ error: 'LOCAL_VERIFICATION_INTERACTIVE_OAUTH_DISABLED' }, 409)
  }

  if (url.hostname === 'www.googleapis.com' && url.pathname.includes('/calendar/v3/')) {
    if (request.method === 'DELETE') return new Response(null, { status: 204 })

    if (url.pathname.endsWith('/events') && request.method === 'GET') {
      return json({ items: [], nextSyncToken: 'LOCAL_ONLY_sync_token' })
    }

    const body = request.method === 'POST' || request.method === 'PATCH'
      ? await request.json().catch(() => ({})) as Record<string, unknown>
      : {}
    const pathId = url.pathname.match(/\/events\/([^/]+)$/)?.[1]
    return json({
      id: decodeURIComponent(pathId ?? String(body.id ?? `local_${crypto.randomUUID().replaceAll('-', '')}`)),
      status: 'confirmed',
      summary: body.summary ?? 'Local verification event',
      start: body.start ?? { dateTime: '2035-11-10T10:00:00-03:00' },
      end: body.end ?? { dateTime: '2035-11-10T11:00:00-03:00' },
      extendedProperties: body.extendedProperties ?? {
        private: { bs_source: 'blacksheep_agenda' },
      },
      updated: new Date().toISOString(),
      etag: '"LOCAL_ONLY_etag"',
    })
  }

  return json({ error: 'local_google_mock_route_not_found' }, 404)
}

function providerMockMode(): MercadoPagoMockMode {
  const value = safeEnv('LOCAL_MP_MOCK_MODE').toLowerCase()
  return value === 'reject' ? 'reject' : value === 'server_error' ? 'server_error' : 'success'
}

function internalHost(hostname: string): boolean {
  if (hostname === 'localhost' || hostname === '127.0.0.1' || hostname === '::1' || hostname === 'host.docker.internal') return true
  return !hostname.includes('.')
}

export function createLocalVerificationFetch(baseFetch: FetchLike): FetchLike {
  return async (input, init) => {
    const request = new Request(input, init)
    const url = new URL(request.url)

    if (url.hostname === 'api.mercadopago.com') {
      return mockMercadoPagoFetch(request, undefined, providerMockMode())
    }

    if (url.hostname === 'oauth2.googleapis.com' || url.hostname === 'accounts.google.com' || url.hostname === 'www.googleapis.com') {
      return mockGoogleFetch(request)
    }

    if (url.hostname.toLowerCase().includes(PROD_SUPABASE_REF)) {
      throw new Error('LOCAL_VERIFICATION_PRODUCTION_NETWORK_BLOCKED')
    }

    if (url.protocol === 'http:' || url.protocol === 'https:') {
      if (!internalHost(url.hostname)) throw new Error(`LOCAL_VERIFICATION_EXTERNAL_NETWORK_BLOCKED:${url.hostname}`)
    }

    return baseFetch(request)
  }
}

export function installLocalVerificationTransport(): void {
  if (!isLocalVerification() || transportInstalled) return
  assertLocalVerificationEnvironment(Deno.env.toObject())
  const original = globalThis.fetch.bind(globalThis)
  globalThis.fetch = createLocalVerificationFetch(original) as typeof fetch
  transportInstalled = true
}
