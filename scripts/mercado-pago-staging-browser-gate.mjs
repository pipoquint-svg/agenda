import { chromium } from 'playwright'

const STAGING = process.env.STAGING_URL
const CARD = '5480832801033311'
const EXP = '11/30'
const CVV = '123'
const CPF = '12345678909'
const EMAIL = 'test@testuser.com'
const PHONE = '48999999999'
const ARTIFACT_DIR = process.env.ARTIFACT_DIR || '/tmp/mp-browser'
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms))

if (!STAGING || !STAGING.startsWith('https://')) throw new Error('STAGING_HTTPS_URL_REQUIRED')

async function fillReviewFields(page) {
  for (const el of await page.locator('input[type="checkbox"]').all()) {
    if (await el.isVisible().catch(() => false) && await el.isEnabled().catch(() => false) && !await el.isChecked().catch(() => false)) await el.check()
  }
  for (const el of await page.locator('textarea').all()) {
    if (await el.isVisible().catch(() => false) && !(await el.inputValue()).trim()) await el.fill('Teste HTTPS Mercado Pago')
  }
  for (const el of await page.locator('select').all()) {
    if (!await el.isVisible().catch(() => false)) continue
    const options = await el.locator('option').evaluateAll((nodes) => nodes.map((o) => ({ value: o.value, disabled: o.disabled })).filter((o) => o.value && !o.disabled))
    if (options[0]) await el.selectOption(options[0].value)
  }
}

async function metadata(el) {
  return el.evaluate((e) => ({
    name: e.getAttribute('name') || '',
    id: e.id || '',
    placeholder: e.getAttribute('placeholder') || '',
    autocomplete: e.getAttribute('autocomplete') || '',
    aria: e.getAttribute('aria-label') || '',
    type: e.getAttribute('type') || '',
  }))
}

function classify(meta, frameUrl) {
  const source = `${meta.name} ${meta.id} ${meta.placeholder} ${meta.autocomplete} ${meta.aria} ${frameUrl}`.toLowerCase()
  if (/card.?number|cc-number|número.*cart|numero.*cart|cardnumber/.test(source)) return 'number'
  if (/expiration|expiry|expir|cc-exp|validade/.test(source)) return 'expiration'
  if (/security|cvv|cvc|cc-csc|segurança|securitycode/.test(source)) return 'cvv'
  if (/cardholder|holder|titular|nome.*cart/.test(source)) return 'holder'
  if (/document|identification|cpf/.test(source)) return 'document'
  if (/e-?mail/.test(source)) return 'email'
  return null
}

async function diagnostics(page, label) {
  const diag = []
  for (const frame of page.frames()) {
    try {
      const host = (() => { try { return new globalThis.URL(frame.url() || STAGING).hostname } catch { return 'invalid-url' } })()
      const inputs = []
      for (let i = 0; i < await frame.locator('input').count(); i++) inputs.push(await metadata(frame.locator('input').nth(i)))
      diag.push({
        host,
        url: (frame.url() || '').slice(0, 180),
        inputs,
        buttons: (await frame.locator('button').allTextContents().catch(() => [])).map((x) => x.trim()).filter(Boolean).slice(0, 20),
      })
    } catch {
      // Transient anti-fraud frames may detach while diagnostics are collected.
    }
  }
  console.log(`${label}_DIAGNOSTICS=${JSON.stringify(diag)}`)
}

async function clickContinue(page) {
  const button = page.getByRole('button', { name: 'Continuar' })
  await button.waitFor({ state: 'visible', timeout: 20000 })
  await button.click()
}

async function reachPayment(page, scenario) {
  await page.goto(STAGING, { waitUntil: 'domcontentloaded', timeout: 60000 })
  await page.getByText('Quanto tempo você precisa no estúdio?', { exact: false }).waitFor({ timeout: 30000 })
  await clickContinue(page)

  const day = page.locator('button[role="gridcell"]:not([disabled])').first()
  await day.waitFor({ state: 'visible', timeout: 45000 })
  await day.click()
  const time = page.getByRole('button', { name: /^\d{2}:\d{2}$/ }).first()
  await time.waitFor({ state: 'visible', timeout: 20000 })
  await time.click()
  const reserve = page.getByRole('button', { name: 'Reservar este horário' })
  if (await reserve.isVisible().catch(() => false)) await reserve.click()
  else await clickContinue(page)

  await page.getByLabel('Quantidade de pessoas').waitFor({ timeout: 30000 })
  await clickContinue(page)
  await page.getByText('Extras', { exact: true }).waitFor({ timeout: 20000 })
  await clickContinue(page)

  await page.getByLabel('Nome completo').waitFor({ timeout: 30000 })
  await page.getByLabel('Nome completo').fill(`TESTE HTTPS ${scenario}`)
  await page.getByLabel('E-mail').fill(EMAIL)
  await page.getByLabel('WhatsApp').fill(PHONE)
  const tax = page.getByLabel('CPF/CNPJ')
  if (await tax.count()) await tax.fill(CPF)
  await page.getByRole('button', { name: 'Continuar para a revisão' }).click()
  await page.getByText('Revisão', { exact: true }).waitFor({ timeout: 20000 })
  await fillReviewFields(page)
  const create = page.getByRole('button', { name: 'Criar reserva' })
  await create.waitFor({ timeout: 20000 })
  if (!await create.isEnabled()) throw new Error('CREATE_RESERVATION_DISABLED')
  await create.click()
  await page.getByText('Pagamento', { exact: true }).waitFor({ timeout: 30000 })
  console.log(`${scenario}_RESERVATION=${await page.locator('text=/Reserva .* criada/').first().textContent().catch(() => null) ?? 'created'}`)
  await page.getByRole('button', { name: 'Cartão' }).click()
  await page.waitForTimeout(4000)
}

async function fillBrick(page, scenario) {
  const unavailable = page.getByText('Pagamento com cartão indisponível no momento', { exact: false })
  if (await unavailable.isVisible().catch(() => false)) throw new Error('MERCADO_PAGO_PUBLIC_KEY_NOT_AVAILABLE_IN_STAGING')

  const deadline = Date.now() + 60000
  let found = new Set()
  while (Date.now() < deadline) {
    found = new Set()
    for (const frame of page.frames()) {
      try {
        const inputs = frame.locator('input')
        for (let i = 0; i < await inputs.count(); i++) {
          const el = inputs.nth(i)
          if (!await el.isVisible().catch(() => false)) continue
          const kind = classify(await metadata(el), frame.url())
          if (!kind || found.has(kind)) continue
          if (kind === 'number') await el.fill(CARD)
          if (kind === 'expiration') await el.fill(EXP)
          if (kind === 'cvv') await el.fill(CVV)
          if (kind === 'holder') await el.fill(scenario)
          if (kind === 'document') await el.fill(CPF)
          if (kind === 'email') await el.fill(EMAIL)
          found.add(kind)
        }
      } catch {
        // Detached provider frames are retried until the deadline.
      }
    }

    if (found.has('number') && found.has('expiration') && found.has('cvv') && found.has('holder')) {
      for (const frame of page.frames()) {
        try {
          const exactPay = frame.getByRole('button', { name: /^pagar$/i })
          for (let i = 0; i < await exactPay.count(); i++) {
            const button = exactPay.nth(i)
            if (await button.isVisible().catch(() => false) && await button.isEnabled().catch(() => false)) {
              console.log(`${scenario}_PAYMENT_SUBMIT=${(await button.textContent().catch(() => 'Pagar'))?.trim() || 'Pagar'}`)
              await button.click()
              return
            }
          }
        } catch {
          // Try the next frame.
        }
      }
    }
    await sleep(500)
  }

  await diagnostics(page, 'BRICK')
  throw new Error(`BRICK_NOT_READY fields=${[...found].join(',')}`)
}

async function scenario(name) {
  const browser = await chromium.launch({ headless: false })
  const context = await browser.newContext({ viewport: { width: 1280, height: 1000 } })
  const page = await context.newPage()
  page.on('console', (msg) => { if (msg.type() === 'error') console.log(`BROWSER_CONSOLE_ERROR[${name}]=${msg.text()}`) })
  page.on('pageerror', (err) => console.log(`PAGE_ERROR[${name}]=${err.message}`))
  page.on('requestfailed', (req) => {
    const url = req.url()
    if (/mercado|sdk|brick/i.test(url)) console.log(`REQUEST_FAILED[${name}]=${url.slice(0, 200)} :: ${req.failure()?.errorText || ''}`)
  })

  try {
    await reachPayment(page, name)
    await fillBrick(page, name)
    if (name === 'APRO') {
      await page.getByText('Sua reserva está confirmada.', { exact: false }).waitFor({ timeout: 60000 })
      console.log('APRO_BROWSER_HTTPS=PASS')
    } else {
      await page.getByText(/Mercado Pago recusou esta tentativa|Pagamento recusado/i).first().waitFor({ timeout: 60000 })
      console.log('OTHE_BROWSER_HTTPS=PASS')
    }
    await page.screenshot({ path: `${ARTIFACT_DIR}/${name.toLowerCase()}-final.png`, fullPage: true })
  } catch (error) {
    await diagnostics(page, `${name}_FAILURE`).catch(() => {})
    await page.screenshot({ path: `${ARTIFACT_DIR}/${name.toLowerCase()}-failure.png`, fullPage: true }).catch(() => {})
    throw error
  } finally {
    await browser.close()
  }
}

await scenario('APRO')
await scenario('OTHE')
