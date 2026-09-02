import {
  assertLocalVerificationEnvironment,
  createLocalVerificationFetch,
  LOCAL_GOOGLE_TOKEN_ENCRYPTION_KEY,
  mockGoogleFetch,
  mockMercadoPagoFetch,
} from './local-verification.ts'
import { mercadoPagoRuntime } from './mercado-pago-runtime.ts'
import {
  buildMercadoPagoWebhookManifest,
  verifyMercadoPagoWebhookSignature,
} from './mercado-pago.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

async function assertRejects(fn: () => Promise<unknown> | unknown, includes: string): Promise<void> {
  try {
    await fn()
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    assert(message.includes(includes), `expected "${message}" to include "${includes}"`)
    return
  }
  throw new Error(`expected rejection containing ${includes}`)
}

Deno.test('local verification safety accepts only explicit local placeholders', () => {
  assertLocalVerificationEnvironment({
    APP_ENV: 'local_verification',
    MERCADO_PAGO_ENV: 'local_verification',
    MERCADO_PAGO_WEBHOOK_SECRET: 'LOCAL_ONLY_webhook_secret',
    GOOGLE_CLIENT_ID: 'LOCAL_ONLY_google_client',
    GOOGLE_CLIENT_SECRET: 'LOCAL_ONLY_google_secret',
    GOOGLE_TOKEN_ENCRYPTION_KEY: LOCAL_GOOGLE_TOKEN_ENCRYPTION_KEY,
    SUPABASE_URL: 'http://127.0.0.1:54321',
    ALLOW_REAL_CHARGES: 'false',
  })
})

Deno.test('local verification safety rejects production Supabase reference', () => {
  let failed = false
  try {
    assertLocalVerificationEnvironment({
      APP_ENV: 'local_verification',
      SUPABASE_URL: 'https://sbexdggbwqvyhbkatucs.supabase.co',
    })
  } catch (error) {
    failed = error instanceof Error && error.message.includes('PRODUCTION_REFERENCE_FORBIDDEN')
  }
  assert(failed, 'production Supabase reference must be rejected')
})

Deno.test('local verification safety rejects provider credentials', () => {
  for (const env of [
    {
      APP_ENV: 'local_verification',
      MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN: 'APP_USR-real-looking-token',
    },
    {
      APP_ENV: 'local_verification',
      GOOGLE_CLIENT_SECRET: 'GOCSPX-real-looking-secret',
    },
  ]) {
    let failed = false
    try {
      assertLocalVerificationEnvironment(env)
    } catch {
      failed = true
    }
    assert(failed, 'provider credential must be rejected')
  }
})

Deno.test('Mercado Pago runtime uses only local placeholder in local_verification', () => {
  const previousAppEnv = Deno.env.get('APP_ENV')
  try {
    Deno.env.set('APP_ENV', 'local_verification')
    const runtime = mercadoPagoRuntime({
      environment: 'local_verification',
      productionAccessToken: 'APP_USR_must_be_ignored_in_local_test',
      allowRealCharges: 'true',
      creatingCharge: true,
    })
    assert(runtime.environment === 'sandbox', 'local runtime must identify itself as non-production')
    assert(runtime.accessToken.startsWith('LOCAL_ONLY_'), 'local runtime must return a placeholder token')
    assert(!runtime.accessToken.includes('APP_USR'), 'local runtime must never reuse supplied production credential')
  } finally {
    if (previousAppEnv === undefined) Deno.env.delete('APP_ENV')
    else Deno.env.set('APP_ENV', previousAppEnv)
  }
})

Deno.test('Mercado Pago mock reproduces approved Order contract without base fetch', async () => {
  let baseFetchCalls = 0
  const localFetch = createLocalVerificationFetch(async () => {
    baseFetchCalls += 1
    throw new Error('BASE_FETCH_MUST_NOT_RUN')
  })
  const response = await localFetch('https://api.mercadopago.com/v1/orders', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      external_reference: '11111111-1111-4111-8111-111111111111',
      total_amount: '90.00',
      transactions: {
        payments: [{
          amount: '90.00',
          payment_method: { id: 'pix', type: 'bank_transfer' },
        }],
      },
    }),
  })
  const body = await response.json()
  assert(response.status === 201, 'mock order must be created')
  assert(body.status === 'processed', 'mock order must be approved/processed')
  assert(body.external_reference === '11111111-1111-4111-8111-111111111111', 'external reference must round-trip')
  assert(body.transactions?.payments?.[0]?.payment_method?.qr_code, 'Pix contract must include QR payload')
  assert(baseFetchCalls === 0, 'provider mock must never call base fetch')
})

Deno.test('Mercado Pago mock reproduces provider error responses', async () => {
  const rejected = await mockMercadoPagoFetch('https://api.mercadopago.com/v1/orders', { method: 'POST' }, 'reject')
  assert(rejected.status === 422, 'reject mode must return 422')
  const unavailable = await mockMercadoPagoFetch('https://api.mercadopago.com/v1/orders', { method: 'POST' }, 'server_error')
  assert(unavailable.status === 503, 'server error mode must return 503')
})

Deno.test('Google mock responds in-process and arbitrary external hosts are blocked', async () => {
  let baseFetchCalls = 0
  const localFetch = createLocalVerificationFetch(async () => {
    baseFetchCalls += 1
    return new Response('local')
  })
  const token = await localFetch('https://oauth2.googleapis.com/token', { method: 'POST' })
  const body = await token.json()
  assert(body.access_token === 'LOCAL_ONLY_google_access_token', 'Google token contract must be local')
  assert(baseFetchCalls === 0, 'Google mock must never call base fetch')

  await assertRejects(
    () => localFetch('https://example.com/should-never-leave-local'),
    'LOCAL_VERIFICATION_EXTERNAL_NETWORK_BLOCKED',
  )
})

Deno.test('Mercado Pago webhook signature contract works with local-only secret', async () => {
  const dataId = 'ORDLOCAL123'
  const requestId = 'local-request-1'
  const timestamp = '1770000000'
  const secret = 'LOCAL_ONLY_mp_webhook_secret'
  const manifest = buildMercadoPagoWebhookManifest(dataId.toLowerCase(), requestId, timestamp)
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  )
  const signatureBytes = new Uint8Array(await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(manifest)))
  const hex = Array.from(signatureBytes).map((value) => value.toString(16).padStart(2, '0')).join('')
  const signature = `ts=${timestamp},v1=${hex}`

  assert(await verifyMercadoPagoWebhookSignature({ signature, requestId, dataId, secret }), 'valid local signature must pass')
  assert(
    !(await verifyMercadoPagoWebhookSignature({ signature, requestId: 'tampered', dataId, secret })),
    'tampered signature manifest must fail',
  )
})
