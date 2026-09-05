import assert from 'node:assert/strict'
import { chromium } from '@playwright/test'

const baseUrl = process.env.PAYMENT_SMOKE_BASE_URL ?? 'http://127.0.0.1:4173'
const supabaseOrigin = 'https://example.supabase.co'

function json(route, status, body) {
  return route.fulfill({
    status,
    contentType: 'application/json',
    body: JSON.stringify(body),
  })
}

const balanceAccess = {
  data: {
    access_token: 'gate5-payment-token',
    expires_at: '2035-01-01T00:00:00Z',
    amount: 1000,
  },
}

const mercadoPagoContext = {
  appointment: {
    public_code: 'GATE5-MP',
    appointment_status: 'CONFIRMED',
    financial_status: 'PARTIALLY_PAID',
    service_name: 'Locação Gate 5',
    hold_expires_at: null,
  },
  payer: {
    name: 'Cliente Gate 5',
    email: 'gate5@example.com',
    tax_id: '52998224725',
  },
  financial: {
    commercial_value: 1000,
    contract_settled: 0,
    contract_balance: 1000,
    confirmation_percentage: 50,
    confirmation_target_amount: 500,
    minimum_due_contract_amount: 500,
    minimum_available: false,
    full_available: true,
    pix_discount_percent: 0,
  },
  payment_methods: {
    pix_available: true,
    card_backend_available: false,
  },
}

function infinitePayContext(hostedCheckoutAvailable) {
  return {
    appointment: {
      public_code: 'GATE5-IP',
      appointment_status: 'CONFIRMED',
      financial_status: 'PARTIALLY_PAID',
      service_name: 'Ensaio Gate 5',
      commercial_description: 'Ensaio Gate 5',
      hold_expires_at: null,
    },
    financial: {
      commercial_value: 1000,
      contract_settled: 0,
      contract_balance: 1000,
      minimum_due_contract_amount: 500,
      minimum_available: false,
      full_available: true,
      payment_mode: 'FULL_ONLY',
      policy_allows_minimum: false,
      policy_allows_full: true,
    },
    payment_provider: {
      provider: 'INFINITEPAY',
      hosted_checkout: true,
      method_selected_at_provider: true,
      hosted_checkout_available: hostedCheckoutAvailable,
    },
  }
}

async function openBalancePayment(page) {
  const response = await page.goto(`${baseUrl}/pagar-saldo?collection=gate5-controlled`, {
    waitUntil: 'domcontentloaded',
    timeout: 15_000,
  })
  assert.ok(response && response.status() < 400, `preview HTTP ${response?.status() ?? 'NO_RESPONSE'}`)
  await page.locator('input[type="email"]').fill('gate5@example.com')
  await page.getByRole('button', { name: 'Continuar para o pagamento' }).click()
}

async function runMercadoPagoScenario(browser) {
  const context = await browser.newContext()
  const page = await context.newPage()
  let infinitePayGets = 0
  let mercadoPagoGets = 0
  let infinitePayPosts = 0
  const unexpected = []

  await page.route(`${supabaseOrigin}/**`, async (route) => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    if (path.endsWith('/balance-collection-access') && request.method() === 'POST') {
      return json(route, 200, balanceAccess)
    }
    if (path.endsWith('/infinitepay-payment') && request.method() === 'GET') {
      infinitePayGets += 1
      return json(route, 409, { error: { code: 'PAYMENT_PROVIDER_MISMATCH' } })
    }
    if (path.endsWith('/infinitepay-payment') && request.method() === 'POST') {
      infinitePayPosts += 1
      return json(route, 500, { error: { code: 'UNEXPECTED_INFINITEPAY_POST' } })
    }
    if (path.endsWith('/mercado-pago-payment') && request.method() === 'GET') {
      mercadoPagoGets += 1
      return json(route, 200, mercadoPagoContext)
    }
    unexpected.push(`${request.method()} ${path}`)
    return route.abort()
  })

  try {
    await openBalancePayment(page)
    await page.getByRole('heading', { name: 'Pague o saldo da locação' }).waitFor()
    assert.equal(await page.getByRole('button', { name: 'Gerar PIX' }).count(), 1)
    assert.equal(await page.getByText('Checkout ainda não liberado.').count(), 0)
    assert.equal(infinitePayGets, 1, 'provider probe must inspect InfinitePay once')
    assert.equal(mercadoPagoGets, 1, 'Mercado Pago context must be loaded after explicit provider mismatch')
    assert.equal(infinitePayPosts, 0, 'Mercado Pago flow must never create an InfinitePay checkout')
    assert.deepEqual(unexpected, [])
    console.log('ok gate5 mercado-pago legacy routing')
  } finally {
    await context.close()
  }
}

async function runInfinitePayOffScenario(browser) {
  const context = await browser.newContext()
  const page = await context.newPage()
  let infinitePayGets = 0
  let infinitePayPosts = 0
  let mercadoPagoCalls = 0
  const unexpected = []

  await page.route(`${supabaseOrigin}/**`, async (route) => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    if (path.endsWith('/balance-collection-access') && request.method() === 'POST') {
      return json(route, 200, balanceAccess)
    }
    if (path.endsWith('/infinitepay-payment') && request.method() === 'GET') {
      infinitePayGets += 1
      return json(route, 200, infinitePayContext(false))
    }
    if (path.endsWith('/infinitepay-payment') && request.method() === 'POST') {
      infinitePayPosts += 1
      return json(route, 500, { error: { code: 'UNEXPECTED_LIVE_LINK_ATTEMPT' } })
    }
    if (path.endsWith('/mercado-pago-payment')) {
      mercadoPagoCalls += 1
      return json(route, 500, { error: { code: 'UNEXPECTED_MERCADO_PAGO_CALL' } })
    }
    unexpected.push(`${request.method()} ${path}`)
    return route.abort()
  })

  try {
    await openBalancePayment(page)
    await page.getByText('Checkout ainda não liberado.').waitFor()
    const button = page.getByRole('button', { name: 'Continuar para a InfinitePay' })
    assert.equal(await button.isDisabled(), true, 'live OFF must disable checkout creation in the UI')
    assert.equal(await page.locator('.payment-method-tabs').count(), 0, 'Agenda must not render Pix/card tabs for InfinitePay')
    assert.equal(infinitePayGets, 2, 'provider probe and InfinitePay panel must both resolve the same provider context')
    assert.equal(infinitePayPosts, 0, 'live OFF must not POST checkout creation')
    assert.equal(mercadoPagoCalls, 0, 'InfinitePay appointment must not fall through to Mercado Pago')
    assert.deepEqual(unexpected, [])
    console.log('ok gate5 infinitepay live-off routing')
  } finally {
    await context.close()
  }
}

async function runInfinitePayMockCreateScenario(browser) {
  const context = await browser.newContext()
  const page = await context.newPage()
  let createPayload = null
  let mercadoPagoCalls = 0
  const unexpected = []

  await page.route('https://checkout.infinitepay.com.br/**', (route) => route.fulfill({
    status: 200,
    contentType: 'text/html',
    body: '<!doctype html><title>InfinitePay mock checkout</title><h1>mock checkout</h1>',
  }))

  await page.route(`${supabaseOrigin}/**`, async (route) => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    if (path.endsWith('/balance-collection-access') && request.method() === 'POST') {
      return json(route, 200, balanceAccess)
    }
    if (path.endsWith('/infinitepay-payment') && request.method() === 'GET') {
      return json(route, 200, infinitePayContext(true))
    }
    if (path.endsWith('/infinitepay-payment') && request.method() === 'POST') {
      createPayload = request.postDataJSON()
      return json(route, 200, {
        transaction: {
          id: '94600000-0000-0000-0000-000000000099',
          cash_amount: 1000,
          payment_kind: 'FULL',
        },
        checkout: {
          url: 'https://checkout.infinitepay.com.br/gate5-mock',
          reused: false,
        },
      })
    }
    if (path.endsWith('/mercado-pago-payment')) {
      mercadoPagoCalls += 1
      return json(route, 500, { error: { code: 'UNEXPECTED_MERCADO_PAGO_CALL' } })
    }
    unexpected.push(`${request.method()} ${path}`)
    return route.abort()
  })

  try {
    await openBalancePayment(page)
    await page.getByText('Valor-base enviado à InfinitePay').waitFor()
    assert.match(await page.locator('.payment-amount strong').innerText(), /1\.000,00/, 'UI must display the unmodified base amount')
    const button = page.getByRole('button', { name: 'Continuar para a InfinitePay' })
    assert.equal(await button.isEnabled(), true)
    await button.click()
    await page.waitForURL('https://checkout.infinitepay.com.br/gate5-mock', { timeout: 5_000 })

    assert.ok(createPayload && typeof createPayload === 'object', 'mock CREATE payload must be captured')
    assert.deepEqual(Object.keys(createPayload).sort(), ['action', 'payment_kind', 'request_key'])
    assert.equal(createPayload.action, 'CREATE')
    assert.equal(createPayload.payment_kind, 'FULL')
    assert.match(String(createPayload.request_key), /^[0-9a-f-]{36}$/i)
    assert.equal(mercadoPagoCalls, 0)
    assert.deepEqual(unexpected, [])
    console.log('ok gate5 infinitepay mocked hosted-checkout payload')
  } finally {
    await context.close()
  }
}

async function runProviderFailureScenario(browser) {
  const context = await browser.newContext()
  const page = await context.newPage()
  let mercadoPagoCalls = 0

  await page.route(`${supabaseOrigin}/**`, async (route) => {
    const request = route.request()
    const path = new URL(request.url()).pathname
    if (path.endsWith('/balance-collection-access') && request.method() === 'POST') {
      return json(route, 200, balanceAccess)
    }
    if (path.endsWith('/infinitepay-payment') && request.method() === 'GET') {
      return json(route, 503, { error: { code: 'INFINITEPAY_TEMPORARY_FAILURE' } })
    }
    if (path.endsWith('/mercado-pago-payment')) {
      mercadoPagoCalls += 1
      return json(route, 500, { error: { code: 'UNEXPECTED_MERCADO_PAGO_FALLBACK' } })
    }
    return route.abort()
  })

  try {
    await openBalancePayment(page)
    await page.getByText('Não foi possível identificar com segurança o provedor deste pagamento.').waitFor()
    assert.equal(mercadoPagoCalls, 0, 'provider lookup failure must fail closed instead of falling back to Mercado Pago')
    console.log('ok gate5 provider lookup fail-closed')
  } finally {
    await context.close()
  }
}

const browser = await chromium.launch({ headless: true })
try {
  await runMercadoPagoScenario(browser)
  await runInfinitePayOffScenario(browser)
  await runInfinitePayMockCreateScenario(browser)
  await runProviderFailureScenario(browser)
} finally {
  await browser.close()
}
