import { chromium } from '@playwright/test'

const baseUrl = (process.env.PRELIVE_LOCAL_BASE_URL ?? 'http://127.0.0.1:4173/agenda').replace(/\/$/, '')
const routes = ['/gestao', '/gestao/configuracoes', '/gestao/recuperar-senha']

const browser = await chromium.launch({ headless: true })
const page = await browser.newPage()
const pageErrors = []
page.on('pageerror', (error) => pageErrors.push(error.message))

try {
  for (const route of routes) {
    pageErrors.length = 0
    const response = await page.goto(`${baseUrl}${route}`, { waitUntil: 'domcontentloaded', timeout: 20_000 })
    if (!response || response.status() >= 400) {
      throw new Error(`${route}: HTTP ${response?.status() ?? 'NO_RESPONSE'}`)
    }

    try {
      await page.waitForFunction(() => document.body.innerText.trim().length >= 10, undefined, { timeout: 8_000 })
    } catch {
      if (pageErrors.length) throw new Error(`${route}: pageerror: ${pageErrors.join(' | ')}`)
      throw new Error(`${route}: empty PRE-LIVE surface after render timeout`)
    }

    if (pageErrors.length) throw new Error(`${route}: pageerror: ${pageErrors.join(' | ')}`)
    console.log(`ok ${route}`)
  }
} finally {
  await browser.close()
}
