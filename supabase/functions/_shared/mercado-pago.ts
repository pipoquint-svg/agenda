export type MercadoPagoNormalizedStatus = 'PENDING' | 'APPROVED' | 'REJECTED' | 'EXPIRED'

export type MercadoPagoPaymentSnapshot = {
  id: string
  status: string | null
  status_detail: string | null
  payment_method_id: string | null
  payment_type_id: string | null
  transaction_amount: number | null
  external_reference: string | null
  date_approved: string | null
  date_created: string | null
  point_of_interaction?: {
    transaction_data?: {
      qr_code?: string | null
      qr_code_base64?: string | null
      ticket_url?: string | null
    } | null
  } | null
  three_ds_info?: {
    external_resource_url?: string | null
    creq?: string | null
  } | null
}

export type MercadoPagoExpectedIntent = {
  transactionId: string
  cashAmount: number | string
  method: 'PIX' | 'CARD'
  providerPaymentMethodId?: string | null
}

function hexToArrayBuffer(hex: string): ArrayBuffer {
  if (!/^[0-9a-f]+$/i.test(hex) || hex.length % 2 !== 0) throw new Error('MERCADO_PAGO_SIGNATURE_INVALID')
  const buffer = new ArrayBuffer(hex.length / 2)
  const out = new Uint8Array(buffer)
  for (let i = 0; i < out.length; i += 1) out[i] = Number.parseInt(hex.slice(i * 2, i * 2 + 2), 16)
  return buffer
}

function moneyToCents(value: number | string | null | undefined): number {
  const amount = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(amount)) throw new Error('MERCADO_PAGO_PAYMENT_AMOUNT_INVALID')
  return Math.round(amount * 100)
}

export function parseMercadoPagoSignature(value: string): { ts: string; v1: string } {
  const parts = Object.fromEntries(
    value.split(',').map((part) => {
      const index = part.indexOf('=')
      return index < 1 ? ['', ''] : [part.slice(0, index).trim(), part.slice(index + 1).trim()]
    }).filter(([key, val]) => key && val),
  )
  if (!parts.ts || !parts.v1) throw new Error('MERCADO_PAGO_SIGNATURE_INVALID')
  return { ts: parts.ts, v1: parts.v1 }
}

export function buildMercadoPagoWebhookManifest(dataId: string, requestId: string, timestamp: string): string {
  if (!dataId || !requestId || !timestamp) throw new Error('MERCADO_PAGO_SIGNATURE_INVALID')
  return `id:${dataId};request-id:${requestId};ts:${timestamp};`
}

export async function verifyMercadoPagoWebhookSignature(input: {
  signature: string
  requestId: string
  dataId: string
  secret: string
}): Promise<boolean> {
  if (!input.secret) throw new Error('MERCADO_PAGO_WEBHOOK_SECRET_NOT_CONFIGURED')
  const parsed = parseMercadoPagoSignature(input.signature)
  const manifest = buildMercadoPagoWebhookManifest(input.dataId, input.requestId, parsed.ts)
  const encoder = new TextEncoder()
  const key = await crypto.subtle.importKey(
    'raw',
    encoder.encode(input.secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['verify'],
  )
  return crypto.subtle.verify('HMAC', key, hexToArrayBuffer(parsed.v1), encoder.encode(manifest))
}

export function normalizeMercadoPagoPaymentStatus(status: string | null | undefined): MercadoPagoNormalizedStatus {
  switch ((status ?? '').toLowerCase()) {
    case 'approved':
      return 'APPROVED'
    case 'rejected':
    case 'cancelled':
      return 'REJECTED'
    case 'expired':
      return 'EXPIRED'
    case 'pending':
    case 'in_process':
    case 'authorized':
    case 'in_mediation':
      return 'PENDING'
    default:
      return 'PENDING'
  }
}

export function sanitizeMercadoPagoPayment(raw: Record<string, unknown>): MercadoPagoPaymentSnapshot {
  const poi = raw.point_of_interaction && typeof raw.point_of_interaction === 'object'
    ? raw.point_of_interaction as Record<string, unknown>
    : null
  const transactionData = poi?.transaction_data && typeof poi.transaction_data === 'object'
    ? poi.transaction_data as Record<string, unknown>
    : null
  const threeDs = raw.three_ds_info && typeof raw.three_ds_info === 'object'
    ? raw.three_ds_info as Record<string, unknown>
    : null

  const text = (value: unknown): string | null => typeof value === 'string' && value ? value : value != null ? String(value) : null
  const amount = typeof raw.transaction_amount === 'number' ? raw.transaction_amount : Number(raw.transaction_amount)

  return {
    id: text(raw.id) ?? '',
    status: text(raw.status),
    status_detail: text(raw.status_detail),
    payment_method_id: text(raw.payment_method_id),
    payment_type_id: text(raw.payment_type_id),
    transaction_amount: Number.isFinite(amount) ? amount : null,
    external_reference: text(raw.external_reference),
    date_approved: text(raw.date_approved),
    date_created: text(raw.date_created),
    point_of_interaction: transactionData ? {
      transaction_data: {
        qr_code: text(transactionData.qr_code),
        qr_code_base64: text(transactionData.qr_code_base64),
        ticket_url: text(transactionData.ticket_url),
      },
    } : undefined,
    three_ds_info: threeDs ? {
      external_resource_url: text(threeDs.external_resource_url),
      creq: text(threeDs.creq),
    } : undefined,
  }
}

export function assertMercadoPagoPaymentMatchesIntent(
  snapshot: MercadoPagoPaymentSnapshot,
  expected: MercadoPagoExpectedIntent,
): void {
  if (!snapshot.id) throw new Error('MERCADO_PAGO_PAYMENT_ID_MISSING')
  if (!expected.transactionId || snapshot.external_reference !== expected.transactionId) {
    throw new Error('MERCADO_PAGO_EXTERNAL_REFERENCE_MISMATCH')
  }
  if (moneyToCents(snapshot.transaction_amount) !== moneyToCents(expected.cashAmount)) {
    throw new Error('MERCADO_PAGO_PAYMENT_AMOUNT_MISMATCH')
  }

  if (expected.method === 'PIX') {
    if ((snapshot.payment_method_id ?? '').toLowerCase() !== 'pix') {
      throw new Error('MERCADO_PAGO_PAYMENT_METHOD_MISMATCH')
    }
    return
  }

  if ((snapshot.payment_method_id ?? '').toLowerCase() === 'pix') {
    throw new Error('MERCADO_PAGO_PAYMENT_METHOD_MISMATCH')
  }
  if (snapshot.payment_type_id && snapshot.payment_type_id.toLowerCase() !== 'credit_card') {
    throw new Error('MERCADO_PAGO_PAYMENT_METHOD_MISMATCH')
  }
  if (expected.providerPaymentMethodId
    && snapshot.payment_method_id
    && snapshot.payment_method_id.toLowerCase() !== expected.providerPaymentMethodId.toLowerCase()) {
    throw new Error('MERCADO_PAGO_PAYMENT_METHOD_MISMATCH')
  }
}

export function validateCardSubmission(value: unknown): {
  token: string
  paymentMethodId: string
  installments: number
  issuerId: string | null
} {
  if (!value || typeof value !== 'object') throw new Error('CARD_DATA_INVALID')
  const row = value as Record<string, unknown>
  const token = typeof row.token === 'string' ? row.token.trim() : ''
  const paymentMethodId = typeof row.payment_method_id === 'string' ? row.payment_method_id.trim() : ''
  const installments = Number(row.installments)
  const issuerId = row.issuer_id == null ? null : String(row.issuer_id).trim() || null

  if (token.length < 10 || token.length > 500) throw new Error('CARD_TOKEN_INVALID')
  if (!/^[A-Za-z0-9_-]{2,80}$/.test(paymentMethodId)) throw new Error('CARD_PAYMENT_METHOD_INVALID')
  if (!Number.isInteger(installments) || installments < 1 || installments > 24) throw new Error('CARD_INSTALLMENTS_INVALID')

  return { token, paymentMethodId, installments, issuerId }
}

export function payerIdentification(taxId: string): { type: 'CPF' | 'CNPJ'; number: string } {
  const digits = taxId.replace(/\D/g, '')
  if (digits.length === 11) return { type: 'CPF', number: digits }
  if (digits.length === 14) return { type: 'CNPJ', number: digits }
  throw new Error('PAYER_TAX_ID_INVALID')
}
