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

const browser = await chromium.launch({ headless: true })
const page = await browser.newPage()
const pageErrors = []
page.on('pageerror', (error) => pageErrors.push(error.message))

try {
  for (const route of routes) {
    pageErrors.length = 0
    const response = await page.goto(`${baseUrl}${route}`, { waitUntil: 'domcontentloaded', timeout: 15_000 })
    if (!response || response.status() >= 400) {
      throw new Error(`${route}: HTTP ${response?.status() ?? 'NO_RESPONSE'}`)
    }
    try {
      await page.waitForFunction(() => document.body.innerText.trim().length >= 10, undefined, { timeout: 5_000 })
    } catch {
      if (pageErrors.length) throw new Error(`${route}: pageerror: ${pageErrors.join(' | ')}`)
      throw new Error(`${route}: empty administrative surface after render timeout`)
    }
    if (pageErrors.length) throw new Error(`${route}: pageerror: ${pageErrors.join(' | ')}`)
    console.log(`ok ${route}`)
  }
} finally {
  await browser.close()
}
