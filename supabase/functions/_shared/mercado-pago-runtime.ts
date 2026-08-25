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

export function mercadoPagoRuntime(input: {
  environment?: string | null
  accessToken?: string | null
  sandboxAccessToken?: string | null
  productionAccessToken?: string | null
  allowRealCharges?: string | null
  creatingCharge?: boolean
}): MercadoPagoRuntime {
  const environment = clean(input.environment).toLowerCase()
  if (environment !== 'sandbox' && environment !== 'production') {
    throw new Error('MERCADO_PAGO_ENV_INVALID')
  }

  // Orders API credentials cannot be classified safely by prefix: Mercado Pago
  // documents APP_USR credentials for both test and production in this solution.
  // Charge creation therefore requires an environment-scoped secret. The generic
  // token remains only as a compatibility fallback for read/reconciliation calls.
  const genericAccessToken = clean(input.accessToken)
  let scopedAccessToken = ''

  if (environment === 'sandbox') {
    scopedAccessToken = input.sandboxAccessToken !== undefined
      ? clean(input.sandboxAccessToken)
      : optionalEnv('MERCADO_PAGO_SANDBOX_ACCESS_TOKEN')
    if (input.creatingCharge && !scopedAccessToken) {
      throw new Error('MISSING_ENV:MERCADO_PAGO_SANDBOX_ACCESS_TOKEN')
    }
  } else {
    scopedAccessToken = input.productionAccessToken !== undefined
      ? clean(input.productionAccessToken)
      : optionalEnv('MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN')
    if (input.creatingCharge && !scopedAccessToken) {
      throw new Error('MISSING_ENV:MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN')
    }
  }

  const accessToken = scopedAccessToken || genericAccessToken
  if (!accessToken) throw new Error('MISSING_ENV:MERCADO_PAGO_ACCESS_TOKEN')

  // Creating a real charge requires a second explicit production gate. Read/reconcile
  // calls stay available so production can recover provider state during incidents.
  if (environment === 'production' && input.creatingCharge && !enabled(input.allowRealCharges)) {
    throw new Error('REAL_CHARGES_DISABLED')
  }

  return { environment, accessToken }
}
