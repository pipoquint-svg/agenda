import { chromium } from 'playwright';

const STAGING = process.env.STAGING_URL;
const CARD = '5480832801033311';
const EXP = '11/30';
const CVV = '123';
const CPF = '12345678909';
const EMAIL = 'test@testuser.com';
const PHONE = '48999999999';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fillReviewFields(page) {
  const checkboxes = page.locator('input[type="checkbox"]');
  for (let i = 0; i < await checkboxes.count(); i++) {
    const el = checkboxes.nth(i);
    if (await el.isVisible().catch(() => false) && await el.isEnabled().catch(() => false) && !(await el.isChecked().catch(() => false))) await el.check();
  }
  const textareas = page.locator('textarea');
  for (let i = 0; i < await textareas.count(); i++) {
    const el = textareas.nth(i);
    if (await el.isVisible().catch(() => false) && !(await el.inputValue()).trim()) await el.fill('Teste HTTPS Mercado Pago');
  }
  const selects = page.locator('select');
  for (let i = 0; i < await selects.count(); i++) {
    const el = selects.nth(i);
    if (!await el.isVisible().catch(() => false)) continue;
    const options = await el.locator('option').evaluateAll((nodes) => nodes.map((o) => ({ value: o.value, disabled: o.disabled })).filter((o) => o.value && !o.disabled));
    if (options[0]) await el.selectOption(options[0].value);
  }
}

function classify(meta, frameUrl) {
  const s = `${meta.name} ${meta.id} ${meta.placeholder} ${meta.autocomplete} ${meta.aria} ${frameUrl}`.toLowerCase();
  if (/card.?number|cc-number|número.*cart|numero.*cart|cardnumber/.test(s)) return 'number';
  if (/expiration|expiry|expir|cc-exp|validade/.test(s)) return 'expiration';
  if (/security|cvv|cvc|cc-csc|segurança|securitycode/.test(s)) return 'cvv';
  if (/cardholder|holder|titular|nome.*cart/.test(s)) return 'holder';
  if (/document|identification|cpf/.test(s)) return 'document';
  if (/e-?mail/.test(s)) return 'email';
  return null;
}

async function metadata(el) {
  return el.evaluate((e) => ({
    name: e.getAttribute('name') || '', id: e.id || '', placeholder: e.getAttribute('placeholder') || '',
    autocomplete: e.getAttribute('autocomplete') || '', aria: e.getAttribute('aria-label') || '', type: e.getAttribute('type') || ''
  }));
}

async function diagnostics(page) {
  const diag = [];
  for (const frame of page.frames()) {
    try {
      const host = (() => { try { return new globalThis.URL(frame.url() || STAGING).hostname; } catch { return 'invalid-url'; } })();
      const inputs = [];
      const count = await frame.locator('input').count();
      for (let i = 0; i < count; i++) inputs.push(await metadata(frame.locator('input').nth(i)));
      const buttons = await frame.locator('button').allTextContents().catch(() => []);
      diag.push({ host, inputs, buttons: buttons.map((x) => x.trim()).filter(Boolean).slice(0, 20) });
    } catch {}
  }
  console.log('BRICK_DIAGNOSTICS=' + JSON.stringify(diag));
}

async function fillBrick(page, scenario) {
  if (await page.getByText('Pagamento com cartão indisponível no momento', { exact: false }).isVisible().catch(() => false)) throw new Error('MERCADO_PAGO_PUBLIC_KEY_NOT_AVAILABLE_IN_STAGING');
  const deadline = Date.now() + 60000;
  let found = new Set();
  while (Date.now() < deadline) {
    found = new Set();
    for (const frame of page.frames()) {
      try {
        const inputs = frame.locator('input');
        for (let i = 0; i < await inputs.count(); i++) {
          const el = inputs.nth(i);
          if (!await el.isVisible().catch(() => false)) continue;
          const kind = classify(await metadata(el), frame.url());
          if (!kind || found.has(kind)) continue;
          if (kind === 'number') await el.fill(CARD);
          if (kind === 'expiration') await el.fill(EXP);
          if (kind === 'cvv') await el.fill(CVV);
          if (kind === 'holder') await el.fill(scenario);
          if (kind === 'document') await el.fill(CPF);
          if (kind === 'email') await el.fill(EMAIL);
          found.add(kind);
        }
        const selects = frame.locator('select');
        for (let i = 0; i < await selects.count(); i++) {
          const sel = selects.nth(i);
          if (!await sel.isVisible().catch(() => false)) continue;
          const options = await sel.locator('option').evaluateAll((nodes) => nodes.map((o) => ({ value: o.value, disabled: o.disabled })).filter((o) => o.value && !o.disabled));
          if (options[0]) await sel.selectOption(options[0].value).catch(() => {});
        }
      } catch {}
    }
    if (found.has('number') && found.has('expiration') && found.has('cvv') && found.has('holder')) {
      for (const frame of page.frames()) {
        try {
          const candidates = frame.getByRole('button', { name: /pagar|pay|continuar|processar|confirmar/i });
          for (let i = 0; i < await candidates.count(); i++) {
            const button = candidates.nth(i);
            if (await button.isVisible().catch(() => false) && await button.isEnabled().catch(() => false)) {
              await button.click();
              return;
            }
          }
        } catch {}
      }
    }
    await sleep(500);
  }
  await diagnostics(page);
  throw new Error(`BRICK_NOT_READY fields=${[...found].join(',')}`);
}

async function reachPayment(page, scenario) {
  await page.goto(STAGING, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.getByText('Quanto tempo você precisa no estúdio?', { exact: false }).waitFor({ timeout: 30000 });
  await page.getByRole('button', { name: 'Continuar' }).click();
  await page.getByLabel('Quantidade de pessoas').waitFor();
  await page.getByRole('button', { name: 'Continuar' }).click();
  await page.getByText('Extras', { exact: true }).waitFor();
  await page.getByRole('button', { name: 'Continuar' }).click();
  const day = page.locator('button[role="gridcell"]:not([disabled])').first();
  await day.waitFor({ state: 'visible', timeout: 45000 });
  await day.click();
  const time = page.getByRole('button', { name: /^\d{2}:\d{2}$/ }).first();
  await time.waitFor({ state: 'visible', timeout: 20000 });
  await time.click();
  await page.getByRole('button', { name: 'Reservar este horário' }).click();
  await page.getByLabel('Nome completo').fill(`TESTE HTTPS ${scenario}`);
  await page.getByLabel('E-mail').fill(EMAIL);
  await page.getByLabel('WhatsApp').fill(PHONE);
  const tax = page.getByLabel('CPF/CNPJ');
  if (await tax.count()) await tax.fill(CPF);
  await page.getByRole('button', { name: 'Continuar para a revisão' }).click();
  await page.getByText('Revisão', { exact: true }).waitFor({ timeout: 20000 });
  await fillReviewFields(page);
  const create = page.getByRole('button', { name: 'Criar reserva' });
  await create.waitFor();
  if (!await create.isEnabled()) throw new Error('CREATE_RESERVATION_DISABLED');
  await create.click();
  await page.getByText('Pagamento', { exact: true }).waitFor({ timeout: 30000 });
  console.log(`${scenario}_RESERVATION_CREATED`);
  await page.getByRole('button', { name: 'Cartão' }).click();
  await page.waitForTimeout(4000);
}

async function scenario(name) {
  const browser = await chromium.launch({ headless: false });
  const context = await browser.newContext({ viewport: { width: 1280, height: 1000 } });
  const page = await context.newPage();
  page.on('console', (msg) => { if (msg.type() === 'error') console.log(`BROWSER_CONSOLE_ERROR[${name}]=${msg.text()}`); });
  try {
    await reachPayment(page, name);
    await fillBrick(page, name);
    if (name === 'APRO') {
      await page.getByText('Sua reserva está confirmada.', { exact: false }).waitFor({ timeout: 60000 });
      console.log('APRO_BROWSER_HTTPS=PASS');
    } else {
      await page.getByText(/Mercado Pago recusou esta tentativa|Pagamento recusado/i).first().waitFor({ timeout: 60000 });
      console.log('OTHE_BROWSER_HTTPS=PASS');
    }
    await page.screenshot({ path: `/tmp/mp-browser/${name.toLowerCase()}-final.png`, fullPage: true });
  } catch (error) {
    await diagnostics(page).catch(() => {});
    await page.screenshot({ path: `/tmp/mp-browser/${name.toLowerCase()}-failure.png`, fullPage: true }).catch(() => {});
    console.error(`${name}_ERROR=${error?.stack || error}`);
    throw error;
  } finally {
    await browser.close();
  }
}

await scenario('APRO');
await scenario('OTHE');
