import { chromium } from '@playwright/test'

const rawBaseUrl = process.env.STAGING_BASE_URL
if (!rawBaseUrl) throw new Error('STAGING_BASE_URL_REQUIRED')

const baseUrl = rawBaseUrl.replace(/\/$/, '')
const expectedSha = process.env.EXPECTED_RELEASE_SHA
if (!expectedSha) throw new Error('EXPECTED_RELEASE_SHA_REQUIRED')

const publicRoutes = ['/', '/agenda-e-valores', '/gerenciar-reserva']
const adminRoutes = [
  '/admin',
  '/admin/dashboard',
  '/admin/agenda',
  '/admin/catalogo',
  '/admin/configuracoes',
  '/admin/configuracoes-avancadas',
  '/admin/funcionarios',
  '/admin/clientes',
  '/admin/cupons',
  '/admin/notificacoes',
  '/admin/aniversarios',
  '/admin/pagamentos',
  '/admin/saude',
  '/admin/demand',
  '/gestao',
  '/gestao/dashboard',
  '/gestao/agenda',
  '/gestao/catalogo',
  '/gestao/configuracoes',
  '/gestao/configuracoes/operacao',
  '/gestao/configuracoes-avancadas',
  '/gestao/profissionais',
  '/gestao/recursos',
  '/gestao/clientes',
  '/gestao/cupons',
  '/gestao/notificacoes',
  '/gestao/aniversarios',
  '/gestao/pagamentos',
  '/gestao/saude',
  '/gestao/demand',
  '/gestao/recuperar-senha',
]

const shaResponse = await fetch(`${baseUrl}/release-sha.txt`, { redirect: 'follow' })
if (!shaResponse.ok) throw new Error(`release-sha.txt: HTTP ${shaResponse.status}`)
const publishedSha = (await shaResponse.text()).trim()
if (publishedSha !== expectedSha) {
  throw new Error(`release SHA mismatch: expected ${expectedSha}, got ${publishedSha}`)
}

const indexResponse = await fetch(`${baseUrl}/`, { redirect: 'follow' })
if (!indexResponse.ok) throw new Error(`staging root: HTTP ${indexResponse.status}`)
const indexHtml = await indexResponse.text()
if (!indexHtml.includes('noindex,nofollow,noarchive')) {
  throw new Error('staging root is missing noindex,nofollow,noarchive')
}

const browser = await chromium.launch({ headless: true })
const page = await browser.newPage()
const pageErrors = []
page.on('pageerror', (error) => pageErrors.push(error.message))

async function renderRoute(route) {
  pageErrors.length = 0
  const response = await page.goto(`${baseUrl}/`, { waitUntil: 'domcontentloaded', timeout: 20_000 })
  if (!response || response.status() >= 400) {
    throw new Error(`${route}: staging entry HTTP ${response?.status() ?? 'NO_RESPONSE'}`)
  }
  await page.evaluate((nextPath) => {
    history.pushState({}, '', nextPath)
    window.dispatchEvent(new PopStateEvent('popstate'))
  }, `/agenda${route === '/' ? '/' : route}`)
  try {
    await page.waitForFunction(() => document.body.innerText.trim().length >= 10, undefined, { timeout: 8_000 })
  } catch {
    if (pageErrors.length) throw new Error(`${route}: pageerror: ${pageErrors.join(' | ')}`)
    throw new Error(`${route}: empty surface after render timeout`)
  }
  if (pageErrors.length) throw new Error(`${route}: pageerror: ${pageErrors.join(' | ')}`)
  console.log(`ok ${route}`)
}

try {
  for (const route of publicRoutes) await renderRoute(route)
  for (const route of adminRoutes) await renderRoute(route)
} finally {
  await browser.close()
}

console.log(`published SHA verified: ${publishedSha}`)
