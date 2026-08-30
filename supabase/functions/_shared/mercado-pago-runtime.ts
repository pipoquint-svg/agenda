export type MercadoPagoEnvironment = 'sandbox' | 'production'

export type MercadoPagoRuntime = {
  environment: MercadoPagoEnvironment
  accessToken: string
}

function enabled(value: string | undefined | null): boolean {
  return (value ?? '').trim().toLowerCase() === 'true'
}

function clean(value: string | undefined | null): string {
  return (value ?? '').trim()
}

function optionalEnv(name: string): string {
  try {
    return clean(Deno.env.get(name))
  } catch {
    // Keep the helper testable without --allow-env. Edge runtime callers still read
    // the configured secret normally; denied env access behaves exactly like missing config.
    return ''
  }
}

/**
 * Mercado Pago production runtime.
 *
 * BlackSheep no longer supports sandbox credentials in the operational backend.
 * Every provider read and financial mutation uses the official production-scoped
 * Access Token. Financial mutations additionally require ALLOW_REAL_CHARGES.
 *
 * `accessToken` is accepted only so older call sites remain type-compatible during
 * the deployment cutover. Its value is deliberately ignored and can never authorize
 * a provider request. The environment return type keeps the historical union solely
 * so defensive live/test-event branches continue to type-check; this function still
 * rejects every environment other than `production` at runtime.
 */
export function mercadoPagoRuntime(input: {
  environment?: string | null
  productionAccessToken?: string | null
  accessToken?: string | null
  allowRealCharges?: string | null
  creatingCharge?: boolean
}): MercadoPagoRuntime {
  const environment = clean(input.environment).toLowerCase()
  if (environment !== 'production') throw new Error('MERCADO_PAGO_ENV_INVALID')

  const accessToken = input.productionAccessToken !== undefined
    ? clean(input.productionAccessToken)
    : optionalEnv('MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN')
  if (!accessToken) throw new Error('MISSING_ENV:MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN')

  if (input.creatingCharge && !enabled(input.allowRealCharges)) {
    throw new Error('REAL_CHARGES_DISABLED')
  }

  return { environment: 'production', accessToken }
}
