export type MercadoPagoNormalizedStatus = 'PENDING' | 'APPROVED' | 'REJECTED' | 'EXPIRED'

export type MercadoPagoPaymentSnapshot = {
  // Provider resource id. In the Orders API this is the Order id (ORD...).
  id: string
  provider_transaction_id: string | null
  provider_transaction_count: number
  // Stable client-facing status used by the Agenda UI.
  status: 'pending' | 'approved' | 'rejected' | 'expired' | null
  // Raw Mercado Pago detail for diagnostics and state-machine evidence.
  status_detail: string | null
  raw_status: string | null
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

function text(value: unknown): string | null {
  return typeof value === 'string' && value ? value : value != null ? String(value) : null
}

function object(value: unknown): Record<string, unknown> | null {
  return value && typeof value === 'object' && !Array.isArray(value) ? value as Record<string, unknown> : null
}

function firstOrderPayment(raw: Record<string, unknown>): {
  payment: Record<string, unknown> | null
  count: number
} {
  const transactions = object(raw.transactions)
  const payments = Array.isArray(transactions?.payments) ? transactions?.payments as unknown[] : []
  const payment = payments.length > 0 ? object(payments[0]) : null
  return { payment, count: payments.length }
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
  // Mercado Pago requires alphanumeric data.id query values (such as Orders ORD...) in lowercase
  // when building the HMAC manifest. Numeric IDs are preserved verbatim.
  const normalizedDataId = /[A-Za-z]/.test(dataId) ? dataId.toLowerCase() : dataId
  return `id:${normalizedDataId};request-id:${requestId};ts:${timestamp};`
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

function orderStatusForClient(status: string | null | undefined, statusDetail?: string | null): MercadoPagoPaymentSnapshot['status'] {
  const raw = (status ?? '').toLowerCase()
  const detail = (statusDetail ?? '').toLowerCase()
  if (raw === 'processed' || raw === 'approved') return 'approved'
  if (raw === 'expired' || (raw === 'canceled' && detail === 'expired') || (raw === 'cancelled' && detail === 'expired')) return 'expired'
  if (raw === 'failed' || raw === 'rejected' || raw === 'canceled' || raw === 'cancelled') return 'rejected'
  if (raw === 'action_required' || raw === 'processing' || raw === 'created' || raw === 'pending' || raw === 'in_process' || raw === 'authorized' || raw === 'in_mediation') return 'pending'
  return 'pending'
}

export function normalizeMercadoPagoPaymentStatus(status: string | null | undefined): MercadoPagoNormalizedStatus {
  switch ((status ?? '').toLowerCase()) {
    case 'approved':
    case 'processed':
      return 'APPROVED'
    case 'rejected':
    case 'failed':
    case 'cancelled':
    case 'canceled':
      return 'REJECTED'
    case 'expired':
      return 'EXPIRED'
    case 'pending':
    case 'action_required':
    case 'processing':
    case 'created':
    case 'in_process':
    case 'authorized':
    case 'in_mediation':
    default:
      return 'PENDING'
  }
}

/**
 * Normalizes a Checkout Transparente Orders API response into the compact shape
 * already consumed by the Agenda checkout. One Agenda charge maps to exactly one
 * Mercado Pago Order with exactly one payment transaction.
 */
export function sanitizeMercadoPagoPayment(raw: Record<string, unknown>): MercadoPagoPaymentSnapshot {
  const { payment, count } = firstOrderPayment(raw)
  const paymentMethod = object(payment?.payment_method)
  const transactionSecurity = object(paymentMethod?.transaction_security)

  const rawStatus = text(payment?.status) ?? text(raw.status)
  const statusDetail = text(payment?.status_detail) ?? text(raw.status_detail)
  const clientStatus = orderStatusForClient(rawStatus, statusDetail)
  const amountRaw = payment?.amount ?? raw.total_amount
  const amount = typeof amountRaw === 'number' ? amountRaw : Number(amountRaw)
  const lastUpdated = text(payment?.last_updated_date) ?? text(raw.last_updated_date)
  const dateCreated = text(payment?.created_date) ?? text(raw.created_date)

  const qrCode = text(paymentMethod?.qr_code)
  const qrBase64 = text(paymentMethod?.qr_code_base64)
  const ticketUrl = text(paymentMethod?.ticket_url)
  const challengeUrl = text(transactionSecurity?.url)

  return {
    id: text(raw.id) ?? '',
    provider_transaction_id: text(payment?.id),
    provider_transaction_count: count,
    status: clientStatus,
    status_detail: statusDetail,
    raw_status: rawStatus,
    payment_method_id: text(paymentMethod?.id),
    payment_type_id: text(paymentMethod?.type),
    transaction_amount: Number.isFinite(amount) ? amount : null,
    external_reference: text(raw.external_reference),
    date_approved: clientStatus === 'approved' ? lastUpdated : null,
    date_created: dateCreated,
    point_of_interaction: qrCode || qrBase64 || ticketUrl ? {
      transaction_data: {
        qr_code: qrCode,
        qr_code_base64: qrBase64,
        ticket_url: ticketUrl,
      },
    } : undefined,
    three_ds_info: challengeUrl ? {
      external_resource_url: challengeUrl,
    } : undefined,
  }
}

export function mercadoPagoPaymentStorageSnapshot(snapshot: MercadoPagoPaymentSnapshot): Record<string, unknown> {
  return {
    id: snapshot.id,
    provider_transaction_id: snapshot.provider_transaction_id,
    provider_transaction_count: snapshot.provider_transaction_count,
    status: snapshot.status,
    status_detail: snapshot.status_detail,
    raw_status: snapshot.raw_status,
    payment_method_id: snapshot.payment_method_id,
    payment_type_id: snapshot.payment_type_id,
    transaction_amount: snapshot.transaction_amount,
    external_reference: snapshot.external_reference,
    date_approved: snapshot.date_approved,
    date_created: snapshot.date_created,
  }
}

export function assertMercadoPagoPaymentMatchesIntent(
  snapshot: MercadoPagoPaymentSnapshot,
  expected: MercadoPagoExpectedIntent,
): void {
  // The provider id is the Order id in the current integration.
  if (!snapshot.id) throw new Error('MERCADO_PAGO_PAYMENT_ID_MISSING')
  if (snapshot.provider_transaction_count !== 1 || !snapshot.provider_transaction_id) {
    throw new Error('MERCADO_PAGO_PAYMENT_METHOD_MISMATCH')
  }
  if (!expected.transactionId || snapshot.external_reference !== expected.transactionId) {
    throw new Error('MERCADO_PAGO_EXTERNAL_REFERENCE_MISMATCH')
  }
  if (moneyToCents(snapshot.transaction_amount) !== moneyToCents(expected.cashAmount)) {
    throw new Error('MERCADO_PAGO_PAYMENT_AMOUNT_MISMATCH')
  }

  if (expected.method === 'PIX') {
    if ((snapshot.payment_method_id ?? '').toLowerCase() !== 'pix'
      || (snapshot.payment_type_id ?? '').toLowerCase() !== 'bank_transfer') {
      throw new Error('MERCADO_PAGO_PAYMENT_METHOD_MISMATCH')
    }
    return
  }

  if ((snapshot.payment_type_id ?? '').toLowerCase() !== 'credit_card') {
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
