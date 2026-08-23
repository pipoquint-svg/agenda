export type MercadoPagoEnvironment = 'sandbox' | 'production'

export type MercadoPagoRuntime = {
  environment: MercadoPagoEnvironment
  accessToken: string
}

function enabled(value: string | undefined | null): boolean {
  return (value ?? '').trim().toLowerCase() === 'true'
}

export function mercadoPagoRuntime(input: {
  environment?: string | null
  accessToken?: string | null
  allowRealCharges?: string | null
  creatingCharge?: boolean
}): MercadoPagoRuntime {
  const environment = (input.environment ?? '').trim().toLowerCase()
  if (environment !== 'sandbox' && environment !== 'production') {
    throw new Error('MERCADO_PAGO_ENV_INVALID')
  }

  const accessToken = (input.accessToken ?? '').trim()
  if (!accessToken) throw new Error('MISSING_ENV:MERCADO_PAGO_ACCESS_TOKEN')

  // Test and production credentials must never cross environments. Mercado Pago test
  // access tokens are prefixed TEST-. A production environment refuses them; sandbox
  // refuses anything else so a live credential cannot accidentally create a real charge.
  const isTestToken = accessToken.startsWith('TEST-')
  if (environment === 'sandbox' && !isTestToken) throw new Error('MERCADO_PAGO_SANDBOX_TOKEN_REQUIRED')
  if (environment === 'production' && isTestToken) throw new Error('MERCADO_PAGO_PRODUCTION_TOKEN_REQUIRED')

  // Creating a real charge requires a second explicit production gate. Read/reconcile
  // calls stay available so production can recover provider state during incidents.
  if (environment === 'production' && input.creatingCharge && !enabled(input.allowRealCharges)) {
    throw new Error('REAL_CHARGES_DISABLED')
  }

  return { environment, accessToken }
}
