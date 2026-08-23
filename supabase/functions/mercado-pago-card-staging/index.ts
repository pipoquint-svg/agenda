const htmlHeaders = {
  'content-type': 'text/html; charset=utf-8',
  'cache-control': 'no-store, max-age=0',
  'x-robots-tag': 'noindex, nofollow, noarchive',
}

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

function renderPage(publicKey: string): string {
  const publicKeyJson = JSON.stringify(publicKey)
  return `<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="robots" content="noindex,nofollow,noarchive" />
  <title>BlackSheep · Mercado Pago Sandbox</title>
  <script src="https://sdk.mercadopago.com/js/v2"></script>
  <style>
    body{font-family:Inter,system-ui,sans-serif;background:#f7f7f5;color:#171717;margin:0;padding:24px}
    main{max-width:760px;margin:0 auto;background:#fff;border:1px solid #ddd;border-radius:16px;padding:24px}
    h1{font-size:24px;margin:0 0 8px} p{line-height:1.45}.note{background:#f3f3ef;padding:14px;border-radius:10px;margin:16px 0}
    code{background:#eee;padding:2px 5px;border-radius:4px}.status{white-space:pre-wrap;background:#111;color:#eee;border-radius:10px;padding:14px;min-height:48px;margin-top:16px;overflow:auto}
    .ok{color:#176b2c}.warn{color:#8a4b00}.grid{display:grid;grid-template-columns:1fr 1fr;gap:8px}.grid div{background:#fafafa;border:1px solid #eee;padding:10px;border-radius:8px}
    @media(max-width:640px){body{padding:12px}main{padding:16px}.grid{grid-template-columns:1fr}}
  </style>
</head>
<body>
<main>
  <h1>Mercado Pago · cartão sandbox</h1>
  <p>Origem HTTPS real no Supabase sandbox. Valor fixo: <strong>R$ 50,00</strong>. Nenhum cartão real deve ser usado.</p>
  <div class="note">
    <strong>Cartão de teste Mastercard</strong>
    <div class="grid">
      <div>Número: <code>5480 8328 0103 3311</code></div>
      <div>CVV: <code>123</code></div>
      <div>Validade: <code>11/30</code></div>
      <div>CPF: <code>12345678909</code></div>
    </div>
    <p>Nome do titular: <code>APRO</code> para aprovado ou <code>OTHE</code> para recusado. E-mail: <code>test@testuser.com</code>.</p>
  </div>
  <p id="mount-status" class="warn">Carregando Card Payment Brick…</p>
  <div id="cardPaymentBrick_container"></div>
  <div id="result" class="status">MP_CARD_STAGING_READY</div>
</main>
<script>
(async () => {
  const result = document.getElementById('result');
  const mountStatus = document.getElementById('mount-status');
  const show = (value) => { result.textContent = typeof value === 'string' ? value : JSON.stringify(value, null, 2); };
  try {
    if (!window.MercadoPago) throw new Error('MercadoPago.js não carregou');
    const mp = new MercadoPago(${publicKeyJson}, { locale: 'pt-BR' });
    const bricksBuilder = mp.bricks();
    const settings = {
      initialization: { amount: 50 },
      customization: { paymentMethods: { maxInstallments: 1 } },
      callbacks: {
        onReady: () => {
          mountStatus.textContent = 'Brick pronto. Use somente os dados de teste acima.';
          mountStatus.className = 'ok';
          show('BRICK_READY');
        },
        onError: (error) => {
          mountStatus.textContent = 'Erro no Brick';
          show({ stage: 'brick', message: error?.message || String(error) });
        },
        onSubmit: (formData) => new Promise((resolve, reject) => {
          show('Enviando token para Orders API sandbox…');
          fetch(location.pathname + '?api=order', {
            method: 'POST',
            headers: { 'content-type': 'application/json', 'x-sandbox-confirmation': 'SANDBOX' },
            body: JSON.stringify(formData),
          })
          .then(async (response) => {
            const data = await response.json().catch(() => ({}));
            show({ http_status: response.status, ...data });
            if (!response.ok) throw new Error(data?.error?.message || data?.error?.code || 'ORDER_FAILED');
            resolve(data);
          })
          .catch((error) => { show({ stage: 'order', message: error.message }); reject(error); });
        }),
      },
    };
    window.cardPaymentBrickController = await bricksBuilder.create('cardPayment', 'cardPaymentBrick_container', settings);
  } catch (error) {
    mountStatus.textContent = 'Falha ao montar o Brick';
    show({ stage: 'mount', message: error?.message || String(error) });
  }
})();
</script>
</body>
</html>`
}

Deno.serve(async (req: Request) => {
  try {
    assertSandbox()

    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: jsonHeaders })

    const url = new URL(req.url)
    if (req.method === 'GET' && url.searchParams.get('api') !== 'order') {
      return new Response(renderPage(requiredEnv('MERCADO_PAGO_PUBLIC_KEY')), { status: 200, headers: htmlHeaders })
    }

    if (req.method !== 'POST' || url.searchParams.get('api') !== 'order') {
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
    const paymentMethodId = typeof input.payment_method_id === 'string' ? input.payment_method_id.trim() : ''
    const installments = Number(input.installments ?? 1)

    if (token.length < 10 || token.length > 500) throw new Error('CARD_TOKEN_INVALID')
    if (!/^[A-Za-z0-9_-]{2,80}$/.test(paymentMethodId)) throw new Error('CARD_PAYMENT_METHOD_INVALID')
    if (!Number.isInteger(installments) || installments !== 1) throw new Error('CARD_INSTALLMENTS_INVALID')

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
            id: paymentMethodId,
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
      return new Response(JSON.stringify({
        ok: false,
        error: { code: 'MERCADO_PAGO_ORDER_REJECTED', provider: safeProviderError(providerResponse.status, providerRaw) },
      }), { status: 422, headers: jsonHeaders })
    }

    return new Response(JSON.stringify({ ok: true, provider: sanitizeOrder(providerRaw) }), { status: 200, headers: jsonHeaders })
  } catch (error) {
    const message = error instanceof Error ? error.message : 'UNKNOWN_ERROR'
    const status = message.startsWith('MISSING_ENV') ? 503 : 400
    return new Response(JSON.stringify({ error: { code: message.split(':')[0] } }), { status, headers: jsonHeaders })
  }
})
