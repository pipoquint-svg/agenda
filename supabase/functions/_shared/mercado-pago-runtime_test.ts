import { mercadoPagoRuntime } from './mercado-pago-runtime.ts'

function expectError(code: string, run: () => unknown): void {
  let actual = ''
  try { run() } catch (error) { actual = error instanceof Error ? error.message : String(error) }
  if (actual !== code) throw new Error(`expected ${code}, got ${actual || 'no error'}`)
}

Deno.test('Mercado Pago accepts only production runtime', () => {
  for (const environment of ['', 'sandbox', 'staging', 'test']) {
    expectError('MERCADO_PAGO_ENV_INVALID', () => mercadoPagoRuntime({
      environment,
      productionAccessToken: 'APP_USR-production-token',
      creatingCharge: false,
    }))
  }
})

Deno.test('Mercado Pago production reads require the production-scoped credential', () => {
  expectError('MISSING_ENV:MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN', () => mercadoPagoRuntime({
    environment: 'production',
    productionAccessToken: '',
    creatingCharge: false,
  }))

  const config = mercadoPagoRuntime({
    environment: 'production',
    productionAccessToken: 'APP_USR-production-token',
    creatingCharge: false,
  })
  if (config.environment !== 'production') throw new Error('production environment mismatch')
  if (config.accessToken !== 'APP_USR-production-token') throw new Error('production scoped token not selected')
})

Deno.test('real financial mutations require explicit production gate', () => {
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
  if (config.accessToken !== 'APP_USR-production-token') throw new Error('production charge token not selected')
})

Deno.test('credential prefix is not used as environment metadata', () => {
  const config = mercadoPagoRuntime({
    environment: 'production',
    productionAccessToken: 'credential-with-provider-defined-prefix',
    allowRealCharges: 'true',
    creatingCharge: true,
  })
  if (config.accessToken !== 'credential-with-provider-defined-prefix') throw new Error('provider credential prefix was interpreted')
})
