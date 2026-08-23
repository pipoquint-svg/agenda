import { chromium } from 'playwright'

const targetUrl = process.env.TARGET_URL?.trim()
const cardholderName = process.env.CARDHOLDER_NAME?.trim()
const expectedStatus = process.env.EXPECTED_STATUS?.trim()
const expectedDetail = process.env.EXPECTED_DETAIL?.trim()

if (!targetUrl?.startsWith('https://')) throw new Error('HTTPS_TARGET_URL_REQUIRED')
if (!['APRO', 'OTHE'].includes(cardholderName)) throw new Error('TEST_CARDHOLDER_REQUIRED')
if (!expectedStatus) throw new Error('EXPECTED_STATUS_REQUIRED')

function fieldHaystack(meta) {
  return [meta.placeholder, meta.name, meta.id, meta.ariaLabel, meta.autocomplete]
    .filter(Boolean).join(' ').toLowerCase()
}

function safeUrl(value) {
  try {
    const parsed = new URL(value)
    return `${parsed.origin}${parsed.pathname}`.slice(0, 300)
  } catch {
    return String(value ?? '').slice(0, 300)
  }
}

async function fillVisibleField(page, hints, value) {
  const lowered = hints.map((hint) => hint.toLowerCase())
  for (let attempt = 0; attempt < 60; attempt += 1) {
    for (const frame of page.frames()) {
      const inputs = frame.locator('input:visible')
      const count = await inputs.count().catch(() => 0)
      for (let index = 0; index < count; index += 1) {
        const input = inputs.nth(index)
        const meta = {
          placeholder: await input.getAttribute('placeholder').catch(() => ''),
          name: await input.getAttribute('name').catch(() => ''),
          id: await input.getAttribute('id').catch(() => ''),
          ariaLabel: await input.getAttribute('aria-label').catch(() => ''),
          autocomplete: await input.getAttribute('autocomplete').catch(() => ''),
        }
        if (!lowered.some((hint) => fieldHaystack(meta).includes(hint))) continue
        await input.click()
        await input.fill('').catch(() => undefined)
        await input.pressSequentially(value, { delay: 12 })
        await input.press('Tab').catch(() => undefined)
        return
      }
    }
    await page.waitForTimeout(200)
  }
  throw new Error(`VISIBLE_FIELD_NOT_FOUND:${hints[0]}`)
}

async function chooseVisibleSelects(page) {
  for (const frame of page.frames()) {
    const selects = frame.locator('select:visible')
    const count = await selects.count().catch(() => 0)
    for (let index = 0; index < count; index += 1) {
      const select = selects.nth(index)
      const options = await select.locator('option').evaluateAll((rows) => rows.map((row) => ({
        value: row.value,
        text: row.textContent || '',
        disabled: row.disabled,
      }))).catch(() => [])
      const cpf = options.find((option) => option.value && !option.disabled && /cpf/i.test(`${option.value} ${option.text}`))
      const usable = cpf || options.find((option) => option.value && !option.disabled)
      if (usable) await select.selectOption(usable.value).catch(() => undefined)
    }
  }
}

async function clickSubmit(page) {
  for (let attempt = 0; attempt < 60; attempt += 1) {
    for (const frame of page.frames()) {
      const buttons = frame.locator('button:visible, input[type="submit"]:visible')
      const count = await buttons.count().catch(() => 0)
      for (let index = 0; index < count; index += 1) {
        const button = buttons.nth(index)
        const text = [
          await button.textContent().catch(() => ''),
          await button.getAttribute('value').catch(() => ''),
          await button.getAttribute('aria-label').catch(() => ''),
        ].filter(Boolean).join(' ').toLowerCase()
        if (!/(pagar|pay|continuar|continue)/i.test(text)) continue
        await button.click()
        return
      }
    }
    await page.waitForTimeout(200)
  }
  throw new Error('CARD_BRICK_SUBMIT_NOT_FOUND')
}

async function fieldInventory(page) {
  const inventory = []
  for (const frame of page.frames()) {
    const nodes = frame.locator('input:visible, select:visible, button:visible')
    const count = Math.min(await nodes.count().catch(() => 0), 20)
    for (let index = 0; index < count; index += 1) {
      const node = nodes.nth(index)
      inventory.push({
        frame: safeUrl(frame.url()),
        tag: await node.evaluate((el) => el.tagName).catch(() => ''),
        type: await node.getAttribute('type').catch(() => ''),
        placeholder: await node.getAttribute('placeholder').catch(() => ''),
        name: await node.getAttribute('name').catch(() => ''),
        ariaLabel: await node.getAttribute('aria-label').catch(() => ''),
      })
      if (inventory.length >= 40) return inventory
    }
  }
  return inventory
}

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } })
  const diagnostics = []
  const remember = (kind, value) => {
    if (diagnostics.length < 20) diagnostics.push({ kind, value: String(value ?? '').slice(0, 500) })
  }
  page.on('console', (message) => {
    if (['error', 'warning'].includes(message.type())) remember(`console:${message.type()}`, message.text())
  })
  page.on('pageerror', (error) => remember('pageerror', error?.message || error))
  page.on('requestfailed', (request) => remember('requestfailed', `${safeUrl(request.url())} ${request.failure()?.errorText || ''}`))

  await page.goto(targetUrl, { waitUntil: 'domcontentloaded', timeout: 45000 })
  try {
    await page.waitForFunction(() => document.querySelector('#result')?.textContent?.includes('BRICK_READY'), null, { timeout: 45000 })
  } catch {
    throw new Error(`CARD_BRICK_HTTPS_MOUNT_FAILED:${JSON.stringify({ diagnostics, inventory: await fieldInventory(page), result: await page.locator('#result').textContent().catch(() => null) })}`)
  }

  await fillVisibleField(page, ['card number', 'número do cartão', 'cardnumber'], '5480832801033311')
  await fillVisibleField(page, ['mm/yy', 'mm/aa', 'expiration', 'validade'], '1130')
  await fillVisibleField(page, ['security code', 'código de segurança', 'cvv'], '123')
  await fillVisibleField(page, ['cardholder', 'titular', 'nome no cartão', 'cardholdername'], cardholderName)
  await fillVisibleField(page, ['email', 'e-mail'], 'test@testuser.com')
  await page.waitForTimeout(800)
  await chooseVisibleSelects(page)
  await fillVisibleField(page, ['identification number', 'número do documento', 'document number', 'cpf', 'identificationnumber'], '12345678909')
  await clickSubmit(page)

  await page.waitForFunction(() => {
    const text = document.querySelector('#result')?.textContent?.trim() || ''
    return text.startsWith('{') && text.includes('http_status')
  }, null, { timeout: 60000 })

  const resultText = await page.locator('#result').textContent()
  const result = JSON.parse(resultText)
  if (result.http_status !== 200 || result.ok !== true) {
    throw new Error(`STAGING_ORDER_FAILED:${JSON.stringify(result)}`)
  }
  if (result.provider?.status !== expectedStatus) {
    throw new Error(`UNEXPECTED_ORDER_STATUS:${JSON.stringify({ expectedStatus, actual: result.provider?.status, detail: result.provider?.status_detail })}`)
  }
  if (expectedDetail && result.provider?.status_detail !== expectedDetail) {
    throw new Error(`UNEXPECTED_ORDER_DETAIL:${JSON.stringify({ expectedDetail, actual: result.provider?.status_detail })}`)
  }

  console.log(`HTTPS card staging PASS for ${cardholderName}: ${result.provider.status}/${result.provider.status_detail || 'none'} order=${result.provider.id}`)
} finally {
  await browser.close()
}
