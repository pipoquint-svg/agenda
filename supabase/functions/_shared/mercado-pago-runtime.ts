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
  // This helper is intentionally pure: callers own environment access so unit tests
  // never need Deno --allow-env and runtime configuration stays explicit.
  const genericAccessToken = clean(input.accessToken)
  const scopedAccessToken = environment === 'sandbox'
    ? clean(input.sandboxAccessToken)
    : clean(input.productionAccessToken)

  if (input.creatingCharge && !scopedAccessToken) {
    throw new Error(environment === 'sandbox'
      ? 'MISSING_ENV:MERCADO_PAGO_SANDBOX_ACCESS_TOKEN'
      : 'MISSING_ENV:MERCADO_PAGO_PRODUCTION_ACCESS_TOKEN')
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
