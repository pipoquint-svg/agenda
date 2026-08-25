import { mercadoPagoRuntime } from './mercado-pago-runtime.ts'

function expectError(code: string, run: () => unknown): void {
  let actual = ''
  try { run() } catch (error) { actual = error instanceof Error ? error.message : String(error) }
  if (actual !== code) throw new Error(`expected ${code}, got ${actual || 'no error'}`)
}

Deno.test('Mercado Pago sandbox charge requires sandbox-scoped credential, regardless of prefix', () => {
  const config = mercadoPagoRuntime({
    environment: 'sandbox',
    accessToken: 'legacy-generic-token',
    sandboxAccessToken: 'APP_USR-sandbox-token',
    creatingCharge: true,
  })
  if (config.environment !== 'sandbox') throw new Error('sandbox environment mismatch')
  if (config.accessToken !== 'APP_USR-sandbox-token') throw new Error('sandbox scoped token not selected')

  expectError('MISSING_ENV:MERCADO_PAGO_SANDBOX_ACCESS_TOKEN', () => mercadoPagoRuntime({
    environment: 'sandbox',
    accessToken: 'APP_USR-generic-token',
    sandboxAccessToken: '',
    creatingCharge: true,
  }))
})

Deno.test('Mercado Pago production charge requires production-scoped credential and explicit real-charge gate', () => {
  expectError('MISSING_ENV:MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN', () => mercadoPagoRuntime({
    environment: 'production',
    accessToken: 'APP_USR-generic-token',
    productionAccessToken: '',
    allowRealCharges: 'true',
    creatingCharge: true,
  }))

  expectError('REAL_CHARGES_DISABLED', () => mercadoPagoRuntime({
    environment: 'production',
    productionAccessToken: 'APP_USR-production-token',
    allowRealCharges: 'false',
    creatingCharge: true,
  }))

  const config = mercadoPagoRuntime({
    environment: 'production',
    productionAccessToken: 'APP_USR-production-token',
    allowRealCharges: 'true',
    creatingCharge: true,
  })
  if (config.accessToken !== 'APP_USR-production-token') throw new Error('production scoped token not selected')
})

Deno.test('read and reconciliation may use scoped secret first or generic compatibility token', () => {
  const sandboxScoped = mercadoPagoRuntime({
    environment: 'sandbox',
    accessToken: 'legacy-generic-token',
    sandboxAccessToken: 'APP_USR-sandbox-token',
    creatingCharge: false,
  })
  if (sandboxScoped.accessToken !== 'APP_USR-sandbox-token') throw new Error('sandbox read did not prefer scoped token')

  const sandboxLegacy = mercadoPagoRuntime({
    environment: 'sandbox',
    accessToken: 'APP_USR-generic-token',
    sandboxAccessToken: '',
    creatingCharge: false,
  })
  if (sandboxLegacy.accessToken !== 'APP_USR-generic-token') throw new Error('generic read fallback unavailable')
})

Deno.test('credential prefixes are not used as environment metadata', () => {
  const sandbox = mercadoPagoRuntime({
    environment: 'sandbox',
    sandboxAccessToken: 'APP_USR-sandbox-token',
    creatingCharge: true,
  })
  if (sandbox.accessToken !== 'APP_USR-sandbox-token') throw new Error('APP_USR sandbox credential rejected')

  const production = mercadoPagoRuntime({
    environment: 'production',
    productionAccessToken: 'TEST-production-shaped-example',
    allowRealCharges: 'true',
    creatingCharge: true,
  })
  if (production.accessToken !== 'TEST-production-shaped-example') throw new Error('prefix inference still active')
})

Deno.test('missing or invalid environment fails closed', () => {
  expectError('MERCADO_PAGO_ENV_INVALID', () => mercadoPagoRuntime({ accessToken: 'token' }))
  expectError('MERCADO_PAGO_ENV_INVALID', () => mercadoPagoRuntime({ environment: 'staging', accessToken: 'token' }))
  expectError('MISSING_ENV:MERCADO_PAGO_ACCESS_TOKEN', () => mercadoPagoRuntime({
    environment: 'sandbox',
    accessToken: '',
    sandboxAccessToken: '',
    creatingCharge: false,
  }))
})
