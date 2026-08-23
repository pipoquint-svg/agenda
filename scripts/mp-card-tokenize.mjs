import http from 'node:http'
import fs from 'node:fs'
import { chromium } from 'playwright'

const publicKey = process.env.MERCADO_PAGO_PUBLIC_KEY?.trim()
const cardholderName = process.env.CARDHOLDER_NAME?.trim()
const outputPath = process.env.OUTPUT_PATH?.trim() || '/tmp/mp-card-token.json'

if (!publicKey) throw new Error('MERCADO_PAGO_PUBLIC_KEY_REQUIRED')
if (!cardholderName) throw new Error('CARDHOLDER_NAME_REQUIRED')

const html = `<!doctype html>
<html lang="pt-BR">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>MP Card Payment Brick sandbox gate</title>
</head>
<body>
  <div id="cardPaymentBrick_container"></div>
  <script src="https://sdk.mercadopago.com/js/v2"></script>
  <script>
    window.__brickReady = false;
    window.__tokenResult = null;
    window.__brickError = null;

    (async () => {
      try {
        const mp = new MercadoPago(${JSON.stringify(publicKey)}, { locale: 'pt-BR' });
        const bricksBuilder = mp.bricks();
        const settings = {
          initialization: {
            amount: 50,
            payer: {
              email: 'test@testuser.com',
              identification: { type: 'CPF', number: '12345678909' },
            },
          },
          callbacks: {
            onReady: () => {
              window.__brickReady = true;
            },
            onSubmit: (formData) => {
              window.__tokenResult = {
                token: formData?.token ?? null,
                paymentMethodId: formData?.payment_method_id ?? formData?.paymentMethodId ?? null,
                issuerId: formData?.issuer_id ?? formData?.issuerId ?? null,
                installments: Number(formData?.installments ?? 1),
              };
              return Promise.resolve();
            },
            onError: (error) => {
              window.__brickError = String(error?.message ?? error?.type ?? error ?? 'CARD_BRICK_ERROR');
            },
          },
        };
        window.__brickController = await bricksBuilder.create(
          'cardPayment',
          'cardPaymentBrick_container',
          settings,
        );
      } catch (error) {
        window.__brickError = String(error?.message ?? error ?? 'CARD_BRICK_CREATE_FAILED');
      }
    })();
  </script>
</body>
</html>`

const server = http.createServer((_req, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
  res.end(html)
})

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const address = server.address()
if (!address || typeof address === 'string') throw new Error('LOCAL_SERVER_FAILED')

function fieldHaystack(meta) {
  return [meta.placeholder, meta.name, meta.id, meta.ariaLabel, meta.autocomplete]
    .filter(Boolean)
    .join(' ')
    .toLowerCase()
}

async function fillVisibleField(page, hints, value) {
  const lowered = hints.map((hint) => hint.toLowerCase())
  for (let attempt = 0; attempt < 50; attempt += 1) {
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
        const haystack = fieldHaystack(meta)
        if (!lowered.some((hint) => haystack.includes(hint))) continue
        await input.click()
        await input.fill('').catch(() => undefined)
        await input.pressSequentially(value, { delay: 15 })
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
        disabled: row.disabled,
      }))).catch(() => [])
      const usable = options.find((option) => option.value && !option.disabled)
      if (usable) await select.selectOption(usable.value).catch(() => undefined)
    }
  }
}

async function clickSubmit(page) {
  for (let attempt = 0; attempt < 50; attempt += 1) {
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

async function safeFieldInventory(page) {
  const inventory = []
  for (const frame of page.frames()) {
    const inputs = frame.locator('input:visible, select:visible, button:visible')
    const count = Math.min(await inputs.count().catch(() => 0), 20)
    for (let index = 0; index < count; index += 1) {
      const node = inputs.nth(index)
      inventory.push({
        frame: frame.url().slice(0, 120),
        tag: await node.evaluate((el) => el.tagName).catch(() => ''),
        type: await node.getAttribute('type').catch(() => ''),
        placeholder: await node.getAttribute('placeholder').catch(() => ''),
        name: await node.getAttribute('name').catch(() => ''),
        id: await node.getAttribute('id').catch(() => ''),
        ariaLabel: await node.getAttribute('aria-label').catch(() => ''),
      })
      if (inventory.length >= 40) return inventory
    }
  }
  return inventory
}

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } })
  await page.goto(`http://127.0.0.1:${address.port}`, { waitUntil: 'networkidle' })
  await page.waitForFunction(() => window.__brickReady === true || window.__brickError, null, { timeout: 45000 })
  const brickError = await page.evaluate(() => window.__brickError)
  if (brickError) throw new Error(`MERCADO_PAGO_BRICK_MOUNT_FAILED:${brickError}`)

  await fillVisibleField(page, ['card number', 'número do cartão', 'cardnumber'], '5480832801033311')
  await fillVisibleField(page, ['mm/yy', 'mm/aa', 'expiration', 'validade'], '1130')
  await fillVisibleField(page, ['security code', 'código de segurança', 'cvv'], '123')
  await fillVisibleField(page, ['cardholder', 'titular', 'nome no cartão', 'name'], cardholderName)

  await page.waitForTimeout(1500)
  await chooseVisibleSelects(page)
  await clickSubmit(page)

  try {
    await page.waitForFunction(() => window.__tokenResult?.token || window.__brickError, null, { timeout: 45000 })
  } catch (error) {
    const inventory = await safeFieldInventory(page)
    const state = await page.evaluate(() => ({ ready: window.__brickReady, error: window.__brickError }))
    throw new Error(`CARD_BRICK_SUBMIT_TIMEOUT:${JSON.stringify({ state, inventory })}`)
  }

  const result = await page.evaluate(() => ({ result: window.__tokenResult, error: window.__brickError }))
  if (result.error) throw new Error(`MERCADO_PAGO_BRICK_FAILED:${result.error}`)
  if (!result.result?.token || !result.result?.paymentMethodId) {
    throw new Error('MERCADO_PAGO_TOKENIZE_INCOMPLETE')
  }

  fs.writeFileSync(outputPath, JSON.stringify({
    token: result.result.token,
    paymentMethodId: result.result.paymentMethodId,
    issuerId: result.result.issuerId,
    installments: Number(result.result.installments || 1),
  }), { mode: 0o600 })
  console.log(`Card Payment Brick tokenization PASS for ${cardholderName}; token redacted.`)
} finally {
  await browser.close()
  await new Promise((resolve) => server.close(resolve))
}
