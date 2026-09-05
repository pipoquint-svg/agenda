import fs from 'node:fs'

function read(relativePath) {
  return fs.readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8')
}

function requireText(source, needle, label) {
  if (!source.includes(needle)) throw new Error(`CUTOVER_CONTRACT_MISSING:${label}`)
}

const bundle = read('dist/embed/agenda-embed.js')
const embedSource = read('src/embed.tsx')
const checkoutSessionSource = read('src/BookingCheckoutSession.tsx')
const paymentPanelSource = read('src/PaymentPanel.tsx')
const paymentProviderSource = read('src/paymentProviderApi.ts')
const embedConfigSource = read('vite.embed.config.ts')

// The Natal page intentionally stays on the existing duration-booking journey.
// Its stable integration point is BookingCheckoutSession -> PaymentPanel, not
// textual mutation of SabrinaBookingJourney inside the minified bundle.
requireText(embedSource, "slug === 'sabrina'", 'sabrina-dedicated-route')
requireText(embedSource, '<BookingPageDuration slug={slug} />', 'non-sabrina-duration-route')
requireText(embedSource, '<BookingCheckoutSession />', 'non-sabrina-checkout-session')
requireText(checkoutSessionSource, "import { PaymentPanel } from './PaymentPanel'", 'checkout-payment-router-import')
requireText(checkoutSessionSource, '<PaymentPanel accessToken={manage.accessToken}', 'checkout-payment-router-use')

// Multi-provider routing remains explicit and fail-closed.
requireText(paymentPanelSource, "provider === 'INFINITEPAY'", 'infinitepay-router-branch')
requireText(paymentProviderSource, "return 'MERCADO_PAGO'", 'mercado-pago-router-branch')
requireText(paymentProviderSource, "throw new Error('PAYMENT_PROVIDER_LOOKUP_FAILED')", 'provider-lookup-fail-closed')

// The stable Natal loader depends only on the public IIFE global + mountAgenda.
requireText(embedConfigSource, "name: 'BlackSheepAgendaEmbed'", 'embed-global-name')
requireText(embedSource, 'export { mountAgenda }', 'embed-mount-api')

// InfinitePay hosted-checkout contract must be present in the real compiled bundle.
for (const host of ['checkout.infinitepay.com.br', 'checkout.infinitepay.io']) {
  requireText(bundle, host, `infinitepay-host-${host}`)
}
requireText(bundle, 'infinitepay-payment', 'infinitepay-payment-client')
requireText(bundle, 'BlackSheepAgendaEmbed', 'compiled-embed-global')

// Compile only; do not execute browser code in Node.
new Function(bundle)

console.log('CUTOVER_NATAL_STABLE_LOADER_COMPAT_OK')
