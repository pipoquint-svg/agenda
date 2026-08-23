import { mercadoPagoRuntime } from './mercado-pago-runtime.ts'

function expectError(code: string, run: () => unknown): void {
  let actual = ''
  try { run() } catch (error) { actual = error instanceof Error ? error.message : String(error) }
  if (actual !== code) throw new Error(`expected ${code}, got ${actual || 'no error'}`)
}

Deno.test('Mercado Pago sandbox accepts only TEST credentials', () => {
  const config = mercadoPagoRuntime({ environment: 'sandbox', accessToken: 'TEST-abc' })
  if (config.environment !== 'sandbox') throw new Error('sandbox environment mismatch')
  expectError('MERCADO_PAGO_SANDBOX_TOKEN_REQUIRED', () => mercadoPagoRuntime({
    environment: 'sandbox', accessToken: 'APP_USR-live-token',
  }))
})

Deno.test('Mercado Pago production rejects TEST credentials', () => {
  const config = mercadoPagoRuntime({ environment: 'production', accessToken: 'APP_USR-live-token' })
  if (config.environment !== 'production') throw new Error('production environment mismatch')
  expectError('MERCADO_PAGO_PRODUCTION_TOKEN_REQUIRED', () => mercadoPagoRuntime({
    environment: 'production', accessToken: 'TEST-abc',
  }))
})

Deno.test('real charge creation needs an independent explicit gate', () => {
  expectError('REAL_CHARGES_DISABLED', () => mercadoPagoRuntime({
    environment: 'production', accessToken: 'APP_USR-live-token', allowRealCharges: 'false', creatingCharge: true,
  }))
  mercadoPagoRuntime({
    environment: 'production', accessToken: 'APP_USR-live-token', allowRealCharges: 'true', creatingCharge: true,
  })
  mercadoPagoRuntime({
    environment: 'production', accessToken: 'APP_USR-live-token', allowRealCharges: 'false', creatingCharge: false,
  })
})

Deno.test('missing or invalid environment fails closed', () => {
  expectError('MERCADO_PAGO_ENV_INVALID', () => mercadoPagoRuntime({ accessToken: 'TEST-abc' }))
  expectError('MERCADO_PAGO_ENV_INVALID', () => mercadoPagoRuntime({ environment: 'staging', accessToken: 'TEST-abc' }))
  expectError('MISSING_ENV:MERCADO_PAGO_ACCESS_TOKEN', () => mercadoPagoRuntime({ environment: 'sandbox' }))
})
