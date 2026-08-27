import { chromium } from '@playwright/test'

const baseUrl = process.env.ADMIN_SMOKE_BASE_URL ?? 'http://127.0.0.1:4173'
const routes = [
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
]

const browser = await chromium.launch({ headless: true })
const page = await browser.newPage()
const pageErrors = []
page.on('pageerror', (error) => pageErrors.push(error.message))

try {
  for (const route of routes) {
    const response = await page.goto(`${baseUrl}${route}`, { waitUntil: 'domcontentloaded', timeout: 15_000 })
    if (!response || response.status() >= 400) {
      throw new Error(`${route}: HTTP ${response?.status() ?? 'NO_RESPONSE'}`)
    }
    await page.waitForTimeout(150)
    const bodyText = (await page.locator('body').innerText()).trim()
    if (bodyText.length < 10) throw new Error(`${route}: empty administrative surface`)
    if (pageErrors.length) throw new Error(`${route}: pageerror: ${pageErrors.splice(0).join(' | ')}`)
    console.log(`ok ${route}`)
  }
} finally {
  await browser.close()
}
