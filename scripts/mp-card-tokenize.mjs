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
<head><meta charset="utf-8"><title>MP card sandbox gate</title></head>
<body>
  <form id="form-checkout">
    <div id="form-checkout__cardNumber"></div>
    <div id="form-checkout__expirationDate"></div>
    <div id="form-checkout__securityCode"></div>
    <input id="form-checkout__cardholderName" />
    <select id="form-checkout__issuer"></select>
    <select id="form-checkout__installments"></select>
    <select id="form-checkout__identificationType"></select>
    <input id="form-checkout__identificationNumber" />
    <input id="form-checkout__cardholderEmail" />
    <button id="form-checkout__submit" type="submit">Pagar</button>
    <progress value="0" class="progress-bar"></progress>
  </form>
  <script src="https://sdk.mercadopago.com/js/v2"></script>
  <script>
    window.__mpReady = false;
    window.__tokenResult = null;
    window.__tokenError = null;
    const mp = new MercadoPago(${JSON.stringify(publicKey)});
    const cardForm = mp.cardForm({
      amount: '50.00',
      iframe: true,
      form: {
        id: 'form-checkout',
        cardNumber: { id: 'form-checkout__cardNumber', placeholder: 'Número do cartão' },
        expirationDate: { id: 'form-checkout__expirationDate', placeholder: 'MM/YY' },
        securityCode: { id: 'form-checkout__securityCode', placeholder: 'Código de segurança' },
        cardholderName: { id: 'form-checkout__cardholderName', placeholder: 'Titular do cartão' },
        issuer: { id: 'form-checkout__issuer', placeholder: 'Banco emissor' },
        installments: { id: 'form-checkout__installments', placeholder: 'Parcelas' },
        identificationType: { id: 'form-checkout__identificationType', placeholder: 'Tipo de documento' },
        identificationNumber: { id: 'form-checkout__identificationNumber', placeholder: 'Número do documento' },
        cardholderEmail: { id: 'form-checkout__cardholderEmail', placeholder: 'E-mail' },
      },
      callbacks: {
        onFormMounted: (error) => {
          if (error) { window.__tokenError = String(error); return; }
          window.__mpReady = true;
        },
        onSubmit: (event) => {
          event.preventDefault();
          try {
            const data = cardForm.getCardFormData();
            window.__tokenResult = {
              token: data.token,
              paymentMethodId: data.paymentMethodId,
              issuerId: data.issuerId,
              installments: Number(data.installments),
            };
          } catch (error) {
            window.__tokenError = String(error);
          }
        },
        onFetching: () => () => undefined,
      },
    });
  </script>
</body>
</html>`

const server = http.createServer((req, res) => {
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' })
  res.end(html)
})

await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))
const address = server.address()
if (!address || typeof address === 'string') throw new Error('LOCAL_SERVER_FAILED')

const browser = await chromium.launch({ headless: true })
try {
  const page = await browser.newPage()
  await page.goto(`http://127.0.0.1:${address.port}`, { waitUntil: 'networkidle' })
  await page.waitForFunction(() => window.__mpReady === true || window.__tokenError, null, { timeout: 30000 })
  const mountError = await page.evaluate(() => window.__tokenError)
  if (mountError) throw new Error(`MERCADO_PAGO_FORM_MOUNT_FAILED:${mountError}`)

  const secureValues = [
    { hints: ['Número do cartão', 'card number', 'cardNumber'], value: '5480832801033311' },
    { hints: ['MM/YY', 'expiration', 'expirationDate'], value: '11/30' },
    { hints: ['Código de segurança', 'security', 'securityCode', 'CVV'], value: '123' },
  ]

  for (const secure of secureValues) {
    let filled = false
    for (let attempt = 0; attempt < 40 && !filled; attempt += 1) {
      for (const frame of page.frames()) {
        const inputs = frame.locator('input')
        const count = await inputs.count().catch(() => 0)
        for (let index = 0; index < count; index += 1) {
          const input = inputs.nth(index)
          const placeholder = (await input.getAttribute('placeholder').catch(() => '')) || ''
          const name = (await input.getAttribute('name').catch(() => '')) || ''
          const id = (await input.getAttribute('id').catch(() => '')) || ''
          const haystack = `${placeholder} ${name} ${id}`.toLowerCase()
          if (secure.hints.some((hint) => haystack.includes(hint.toLowerCase()))) {
            await input.fill(secure.value)
            filled = true
            break
          }
        }
        if (filled) break
      }
      if (!filled) await page.waitForTimeout(250)
    }
    if (!filled) throw new Error(`SECURE_CARD_FIELD_NOT_FOUND:${secure.hints[0]}`)
  }

  await page.locator('#form-checkout__cardholderName').fill(cardholderName)
  await page.locator('#form-checkout__identificationNumber').fill('12345678909')
  await page.locator('#form-checkout__cardholderEmail').fill('test@testuser.com')

  await page.waitForFunction(() => {
    const issuer = document.querySelector('#form-checkout__issuer')
    const installments = document.querySelector('#form-checkout__installments')
    return issuer?.querySelectorAll('option').length > 0 && installments?.querySelectorAll('option').length > 0
  }, null, { timeout: 30000 })

  await page.locator('#form-checkout__submit').click()
  await page.waitForFunction(() => window.__tokenResult?.token || window.__tokenError, null, { timeout: 30000 })

  const result = await page.evaluate(() => ({ result: window.__tokenResult, error: window.__tokenError }))
  if (result.error) throw new Error(`MERCADO_PAGO_TOKENIZE_FAILED:${result.error}`)
  if (!result.result?.token || !result.result?.paymentMethodId || !result.result?.installments) {
    throw new Error('MERCADO_PAGO_TOKENIZE_INCOMPLETE')
  }

  fs.writeFileSync(outputPath, JSON.stringify(result.result), { mode: 0o600 })
  console.log(`Card tokenization PASS for scenario ${cardholderName}; token redacted.`)
} finally {
  await browser.close()
  await new Promise((resolve) => server.close(resolve))
}
