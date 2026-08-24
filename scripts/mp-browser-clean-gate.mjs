import { chromium } from 'playwright';

const U = process.env.STAGING_URL;
const CARD = '5480832801033311';
const EXP = '11/30';
const CVV = '123';
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function cpfFrom9(s) {
  const d = s.replace(/\D/g, '').padStart(9, '0').slice(-9).split('').map(Number);
  let sum = d.reduce((a, n, i) => a + n * (10 - i), 0);
  let r = (sum * 10) % 11;
  if (r === 10) r = 0;
  d.push(r);
  sum = d.reduce((a, n, i) => a + n * (11 - i), 0);
  r = (sum * 10) % 11;
  if (r === 10) r = 0;
  d.push(r);
  return d.join('');
}

function identity(name) {
  const raw = String(Date.now()) + (name === 'APRO' ? '1' : '2');
  return { email: `mp-${name.toLowerCase()}-${raw}@example.com`, phone: `489${raw.slice(-8)}`, cpf: cpfFrom9(raw.slice(-9)) };
}

async function pageText(page) { return page.locator('body').innerText().catch(() => ''); }

async function clickVisible(page, name) {
  const buttons = page.getByRole('button', { name, exact: true });
  for (let i = 0; i < await buttons.count(); i++) {
    const b = buttons.nth(i);
    if (await b.isVisible().catch(() => false) && await b.isEnabled().catch(() => false)) { await b.click(); return true; }
  }
  return false;
}

async function chooseAndHold(page) {
  const days = page.locator('button[role="gridcell"]:not([disabled])');
  await days.first().waitFor({ state: 'visible', timeout: 30000 });
  const max = Math.min(await days.count(), 24);
  for (let d = 0; d < max; d++) {
    const day = days.nth(d);
    if (!await day.isVisible().catch(() => false)) continue;
    await day.click().catch(() => {});
    await sleep(800);
    const times = page.getByRole('button', { name: /^\d{2}:\d{2}$/ });
    for (let i = 0; i < await times.count(); i++) {
      const t = times.nth(i);
      if (!await t.isVisible().catch(() => false) || !await t.isEnabled().catch(() => false)) continue;
      await t.click();
      const reserve = page.getByRole('button', { name: 'Reservar este horário' });
      if (!await reserve.isEnabled().catch(() => false)) continue;
      await reserve.click();
      for (let n = 0; n < 30; n++) {
        const body = await pageText(page);
        if (/Horário reservado temporariamente para você por|Quantas pessoas estarão no estúdio|Seus dados/i.test(body)) return;
        if (/Revise os dados informados e tente novamente/i.test(body)) {
          const retry = page.getByRole('button', { name: /Tentar novamente/i });
          if (await retry.isVisible().catch(() => false)) await retry.click().catch(() => {});
          await sleep(500);
          break;
        }
        await sleep(250);
      }
    }
  }
  throw new Error('NO_HOLD_ACQUIRED');
}

async function advanceToCustomer(page) {
  for (let i = 0; i < 12; i++) {
    const body = await pageText(page);
    if (/Seus dados\s+Nome completo\s+E-mail\s+WhatsApp/i.test(body)) return;
    if (await clickVisible(page, 'Continuar')) { await sleep(650); continue; }
    await sleep(500);
  }
  throw new Error('CUSTOMER_STEP_NOT_REACHED');
}

async function waitForReview(page) {
  for (let i = 0; i < 60; i++) {
    const body = await pageText(page);
    const saving = /Salvando…|Salvando\.\.\./i.test(body);
    const customerButton = page.getByRole('button', { name: /Continuar para a revisão/i });
    let customerButtonVisible = false;
    for (let j = 0; j < await customerButton.count(); j++) {
      if (await customerButton.nth(j).isVisible().catch(() => false)) { customerButtonVisible = true; break; }
    }
    const visibleInputs = page.locator('input:visible');
    const inputCount = await visibleInputs.count();
    if (!saving && !customerButtonVisible && inputCount < 4 && /Revisão/i.test(body)) return;
    if (/Revise os dados informados e tente novamente/i.test(body)) throw new Error('CUSTOMER_SAVE_REJECTED');
    await sleep(250);
  }
  throw new Error('REVIEW_TRANSITION_TIMEOUT');
}

async function fillCustomer(page, name, id) {
  const inputs = page.locator('input');
  const visible = [];
  for (let i = 0; i < await inputs.count(); i++) {
    const e = inputs.nth(i);
    if (await e.isVisible().catch(() => false)) visible.push(e);
  }
  if (visible.length < 4) throw new Error(`CUSTOMER_FIELDS_MISSING_${visible.length}`);
  await visible[0].fill(`TESTE HTTPS ${name}`);
  await visible[1].fill(id.email);
  await visible[2].fill(id.phone);
  await visible[3].fill(id.cpf);
  const btn = page.getByRole('button', { name: /Continuar para a revisão/i });
  for (let i = 0; i < await btn.count(); i++) {
    const b = btn.nth(i);
    if (await b.isVisible().catch(() => false) && await b.isEnabled().catch(() => false)) {
      await b.click();
      await waitForReview(page);
      return;
    }
  }
  throw new Error('NO_REVIEW_CONTINUE');
}

async function fillReview(page) {
  for (const e of await page.locator('input[type=checkbox]').all()) if (await e.isVisible().catch(() => false) && await e.isEnabled().catch(() => false) && !await e.isChecked().catch(() => false)) await e.check();
  for (const e of await page.locator('textarea').all()) if (await e.isVisible().catch(() => false) && !(await e.inputValue()).trim()) await e.fill('Teste HTTPS Mercado Pago');
  for (const e of await page.locator('select').all()) {
    if (!await e.isVisible().catch(() => false)) continue;
    const opts = await e.locator('option').evaluateAll((ns) => ns.map((x) => ({ v: x.value, d: x.disabled })).filter((x) => x.v && !x.d));
    if (opts[0]) await e.selectOption(opts[0].v);
  }
}

async function submitReview(page) {
  const all = page.getByRole('button');
  const labels = [];
  for (let i = 0; i < await all.count(); i++) {
    const b = all.nth(i);
    if (!await b.isVisible().catch(() => false) || !await b.isEnabled().catch(() => false)) continue;
    const text = (await b.innerText().catch(() => '')).trim();
    labels.push(text);
    if (/pagar|pagamento|confirmar|reservar|finalizar|continuar/i.test(text) && !/voltar|tentar novamente|reserve agora/i.test(text)) { await b.click(); return; }
  }
  console.log('REVIEW_VISIBLE_BUTTONS=' + JSON.stringify(labels));
  throw new Error('NO_REVIEW_SUBMIT');
}

function classify(m, u) {
  const s = `${m.name} ${m.id} ${m.placeholder} ${m.autocomplete} ${m.aria} ${u}`.toLowerCase();
  if (/card.?number|cc-number|numero.*cart|número.*cart|cardnumber/.test(s)) return 'number';
  if (/expiration|expiry|expir|cc-exp|validade/.test(s)) return 'expiration';
  if (/security|cvv|cvc|cc-csc|segurança|securitycode/.test(s)) return 'cvv';
  if (/cardholder|holder|titular|nome.*cart/.test(s)) return 'holder';
  if (/document|identification|cpf/.test(s)) return 'document';
  if (/e-?mail/.test(s)) return 'email';
  return null;
}

async function meta(e) { return e.evaluate((x) => ({ name: x.getAttribute('name') || '', id: x.id || '', placeholder: x.getAttribute('placeholder') || '', autocomplete: x.getAttribute('autocomplete') || '', aria: x.getAttribute('aria-label') || '' })); }

async function fillBrick(page, name, id) {
  if (await page.getByText('Pagamento com cartão indisponível no momento', { exact: false }).isVisible().catch(() => false)) throw new Error('PUBLIC_KEY_UNAVAILABLE');
  const end = Date.now() + 60000;
  let found = new Set();
  while (Date.now() < end) {
    found = new Set();
    for (const frame of page.frames()) {
      try {
        const inputs = frame.locator('input');
        for (let i = 0; i < await inputs.count(); i++) {
          const e = inputs.nth(i);
          if (!await e.isVisible().catch(() => false)) continue;
          const kind = classify(await meta(e), frame.url());
          if (!kind || found.has(kind)) continue;
          if (kind === 'number') await e.fill(CARD);
          if (kind === 'expiration') await e.fill(EXP);
          if (kind === 'cvv') await e.fill(CVV);
          if (kind === 'holder') await e.fill(name);
          if (kind === 'document') await e.fill(id.cpf);
          if (kind === 'email') await e.fill(id.email);
          found.add(kind);
        }
      } catch {}
    }
    if (found.has('number') && found.has('expiration') && found.has('cvv') && found.has('holder')) {
      for (const frame of page.frames()) {
        try {
          const buttons = frame.getByRole('button', { name: /pagar|pay|continuar|processar|confirmar/i });
          for (let i = 0; i < await buttons.count(); i++) {
            const b = buttons.nth(i);
            if (await b.isVisible().catch(() => false) && await b.isEnabled().catch(() => false)) { await b.click(); return; }
          }
        } catch {}
      }
    }
    await sleep(500);
  }
  console.log('BRICK_FIELDS=' + [...found].join(','));
  throw new Error('BRICK_NOT_READY');
}

async function reach(page, name, id) {
  await page.goto(U, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await page.getByText('Quanto tempo você precisa no estúdio?', { exact: false }).waitFor({ timeout: 30000 });
  if (!await clickVisible(page, 'Continuar')) throw new Error('NO_CONTINUE_DURATION');
  await page.getByText('Data e horário', { exact: true }).waitFor({ timeout: 30000 });
  await chooseAndHold(page);
  await advanceToCustomer(page);
  await fillCustomer(page, name, id);
  await fillReview(page);
  await submitReview(page);
  for (let i = 0; i < 60; i++) {
    const body = await pageText(page);
    if (/Pagamento/i.test(body) && /Cartão|PIX/i.test(body)) break;
    await sleep(250);
  }
  const cards = page.getByRole('button', { name: 'Cartão' });
  let clicked = false;
  for (let i = 0; i < await cards.count(); i++) {
    const b = cards.nth(i);
    if (await b.isVisible().catch(() => false) && await b.isEnabled().catch(() => false)) { await b.click(); clicked = true; break; }
  }
  if (!clicked) throw new Error('CARD_OPTION_NOT_AVAILABLE');
  await page.waitForTimeout(4000);
}

async function scenario(name) {
  const id = identity(name);
  const browser = await chromium.launch({ headless: false });
  const page = await browser.newPage({ viewport: { width: 1280, height: 1000 } });
  page.on('response', async (r) => { if (r.status() >= 400 && /supabase|functions|mercado/i.test(r.url())) console.log(`HTTP_ERROR ${r.status()} ${r.url()} ${(await r.text().catch(() => '')).slice(0, 800)}`); });
  try {
    await reach(page, name, id);
    await fillBrick(page, name, id);
    if (name === 'APRO') {
      await page.getByText(/reserva está confirmada|Reserva confirmada/i).first().waitFor({ timeout: 60000 });
      console.log('APRO_BROWSER_HTTPS=PASS');
    } else {
      await page.getByText(/Mercado Pago recusou|Pagamento recusado/i).first().waitFor({ timeout: 60000 });
      console.log('OTHE_BROWSER_HTTPS=PASS');
    }
    await page.screenshot({ path: `/tmp/mp-browser/${name.toLowerCase()}-final.png`, fullPage: true });
  } catch (e) {
    console.log(`${name}_PAGE_TEXT=` + (await pageText(page)).slice(0, 7000));
    await page.screenshot({ path: `/tmp/mp-browser/${name.toLowerCase()}-failure.png`, fullPage: true }).catch(() => {});
    throw e;
  } finally { await browser.close(); }
}

await scenario('APRO');
await scenario('OTHE');
