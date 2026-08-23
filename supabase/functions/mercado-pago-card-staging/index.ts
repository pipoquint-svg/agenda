const jsonHeaders = {
  'content-type': 'application/json; charset=utf-8',
  'cache-control': 'no-store, max-age=0',
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, x-sandbox-confirmation',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function assertSandbox(): void {
  if (requiredEnv('APP_ENV') !== 'staging') throw new Error('STAGING_ONLY')
  if (requiredEnv('MERCADO_PAGO_ENV') !== 'sandbox') throw new Error('SANDBOX_ONLY')
  if (requiredEnv('ALLOW_REAL_CHARGES') !== 'false') throw new Error('REAL_CHARGES_MUST_BE_DISABLED')
  if (requiredEnv('ALLOW_REAL_CUSTOMER_DATA') !== 'false') throw new Error('REAL_CUSTOMER_DATA_MUST_BE_DISABLED')
}

function safeProviderError(status: number, raw: unknown) {
  const row = raw && typeof raw === 'object' ? raw as Record<string, unknown> : {}
  const errors = Array.isArray(row.errors) ? row.errors : Array.isArray(row.cause) ? row.cause : []
  return {
    http_status: status,
    error: typeof row.error === 'string' ? row.error : null,
    message: typeof row.message === 'string' ? row.message.slice(0, 500) : null,
    status: typeof row.status === 'string' ? row.status : null,
    status_detail: typeof row.status_detail === 'string' ? row.status_detail : null,
    errors: errors.slice(0, 5).map((item) => {
      const err = item && typeof item === 'object' ? item as Record<string, unknown> : {}
      return { code: err.code ?? null, message: err.message ?? err.description ?? null }
    }),
  }
}

function sanitizeOrder(raw: Record<string, unknown>) {
  const transactions = raw.transactions && typeof raw.transactions === 'object'
    ? raw.transactions as Record<string, unknown>
    : {}
  const payments = Array.isArray(transactions.payments) ? transactions.payments as Record<string, unknown>[] : []
  const payment = payments[0] ?? {}
  const paymentMethod = payment.payment_method && typeof payment.payment_method === 'object'
    ? payment.payment_method as Record<string, unknown>
    : {}

  return {
    id: raw.id ?? null,
    status: raw.status ?? payment.status ?? null,
    status_detail: raw.status_detail ?? payment.status_detail ?? null,
    external_reference: raw.external_reference ?? null,
    transaction_id: payment.id ?? null,
    payment_status: payment.status ?? null,
    payment_status_detail: payment.status_detail ?? null,
    payment_method_id: paymentMethod.id ?? null,
    payment_method_type: paymentMethod.type ?? null,
    amount: payment.amount ?? raw.total_amount ?? null,
  }
}

async function createOrderFromToken(token: string) {
  const externalReference = `blacksheep-card-staging-${crypto.randomUUID()}`
  const orderBody = {
    type: 'online',
    processing_mode: 'automatic',
    capture_mode: 'automatic',
    external_reference: externalReference,
    total_amount: '50.00',
    payer: {
      email: 'test@testuser.com',
      identification: { type: 'CPF', number: '12345678909' },
    },
    transactions: {
      payments: [{
        amount: '50.00',
        payment_method: {
          id: 'master',
          type: 'credit_card',
          token,
          installments: 1,
        },
      }],
    },
  }

  const providerResponse = await fetch('https://api.mercadopago.com/v1/orders', {
    method: 'POST',
    headers: {
      'authorization': `Bearer ${requiredEnv('MERCADO_PAGO_ACCESS_TOKEN')}`,
      'content-type': 'application/json',
      'accept': 'application/json',
      'x-idempotency-key': externalReference,
    },
    body: JSON.stringify(orderBody),
  })

  const providerRaw = await providerResponse.json().catch(() => ({})) as Record<string, unknown>
  if (!providerResponse.ok) {
    return {
      ok: false,
      http_status: 422,
      error: { code: 'MERCADO_PAGO_ORDER_REJECTED', provider: safeProviderError(providerResponse.status, providerRaw) },
    }
  }

  return { ok: true, http_status: 200, provider: sanitizeOrder(providerRaw) }
}

async function runServerSideCardProbe(scenario: 'APRO' | 'OTHE') {
  const tokenBody = {
    card_number: '5480832801033311',
    expiration_month: 11,
    expiration_year: 2030,
    security_code: '123',
    cardholder: {
      name: scenario,
      identification: { type: 'CPF', number: '12345678909' },
    },
  }

  const tokenResponse = await fetch('https://api.mercadopago.com/v1/card_tokens', {
    method: 'POST',
    headers: {
      'authorization': `Bearer ${requiredEnv('MERCADO_PAGO_ACCESS_TOKEN')}`,
      'content-type': 'application/json',
      'accept': 'application/json',
    },
    body: JSON.stringify(tokenBody),
  })

  const tokenRaw = await tokenResponse.json().catch(() => ({})) as Record<string, unknown>
  if (!tokenResponse.ok) {
    return {
      ok: false,
      stage: 'card_token',
      error: safeProviderError(tokenResponse.status, tokenRaw),
    }
  }

  const tokenId = typeof tokenRaw.id === 'string' ? tokenRaw.id : ''
  if (!tokenId) return { ok: false, stage: 'card_token', error: { code: 'TOKEN_ID_MISSING' } }

  const orderResult = await createOrderFromToken(tokenId)
  return {
    ...orderResult,
    probe: {
      scenario,
      token_created: true,
      raw_card_logged: false,
      amount: '50.00',
      payment_method_id: 'master',
    },
  }
}

Deno.serve(async (req: Request) => {
  try {
    assertSandbox()

    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: jsonHeaders })

    const url = new URL(req.url)
    const api = url.searchParams.get('api')

    if (req.method === 'GET' && api === 'probe-card') {
      if (url.searchParams.get('confirmation') !== 'SANDBOX') {
        return new Response(JSON.stringify({ error: { code: 'SANDBOX_CONFIRMATION_REQUIRED' } }), { status: 400, headers: jsonHeaders })
      }
      const scenario = url.searchParams.get('scenario')
      if (scenario !== 'APRO' && scenario !== 'OTHE') {
        return new Response(JSON.stringify({ error: { code: 'TEST_SCENARIO_INVALID' } }), { status: 400, headers: jsonHeaders })
      }
      const result = await runServerSideCardProbe(scenario)
      return new Response(JSON.stringify(result), { status: result.ok ? 200 : 422, headers: jsonHeaders })
    }

    if (req.method === 'GET' && api === 'config') {
      return new Response(JSON.stringify({
        ok: true,
        marker: 'MP_CARD_STAGING_READY',
        public_key: requiredEnv('MERCADO_PAGO_PUBLIC_KEY'),
        amount: 50,
        currency: 'BRL',
        payment_method_id: 'master',
        installments: 1,
        identification_type: 'CPF',
        order_endpoint: `${url.origin}${url.pathname}?api=order`,
        environment: 'sandbox',
      }), { status: 200, headers: jsonHeaders })
    }

    if (req.method === 'GET') {
      return new Response(JSON.stringify({
        ok: true,
        marker: 'MP_CARD_STAGING_READY',
        message: 'Sandbox card API is healthy.',
        config: `${url.origin}${url.pathname}?api=config`,
      }), { status: 200, headers: jsonHeaders })
    }

    if (req.method !== 'POST' || api !== 'order') {
      return new Response(JSON.stringify({ error: { code: 'METHOD_NOT_ALLOWED' } }), { status: 405, headers: jsonHeaders })
    }

    if (req.headers.get('x-sandbox-confirmation') !== 'SANDBOX') {
      return new Response(JSON.stringify({ error: { code: 'SANDBOX_CONFIRMATION_REQUIRED' } }), { status: 400, headers: jsonHeaders })
    }

    const rawLength = Number(req.headers.get('content-length') ?? '0')
    if (Number.isFinite(rawLength) && rawLength > 16000) {
      return new Response(JSON.stringify({ error: { code: 'PAYLOAD_TOO_LARGE' } }), { status: 413, headers: jsonHeaders })
    }

    const input = await req.json().catch(() => ({})) as Record<string, unknown>
    const token = typeof input.token === 'string' ? input.token.trim() : ''
    const requestedPaymentMethod = typeof input.payment_method_id === 'string' ? input.payment_method_id.trim() : ''
    const paymentMethodId = requestedPaymentMethod || 'master'
    const installments = Number(input.installments ?? 1)

    if (token.length < 10 || token.length > 500) throw new Error('CARD_TOKEN_INVALID')
    if (paymentMethodId !== 'master') throw new Error('CARD_PAYMENT_METHOD_INVALID')
    if (!Number.isInteger(installments) || installments !== 1) throw new Error('CARD_INSTALLMENTS_INVALID')

    const result = await createOrderFromToken(token)
    return new Response(JSON.stringify(result.ok ? { ok: true, provider: result.provider } : result), {
      status: result.http_status,
      headers: jsonHeaders,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'UNKNOWN_ERROR'
    const status = message.startsWith('MISSING_ENV') ? 503 : 400
    return new Response(JSON.stringify({ error: { code: message.split(':')[0] } }), { status, headers: jsonHeaders })
  }
})
