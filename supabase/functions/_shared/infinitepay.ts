export type InfinitePayCaptureMethod = 'pix' | 'credit_card'
export type InfinitePayAgendaMethod = 'PIX' | 'CARD'

export type InfinitePayItem = {
  quantity: number
  price: number
  description: string
}

export type InfinitePayCustomer = {
  name: string
  email: string
  phone_number?: string
}

export type InfinitePayCreateLinkInput = {
  handle: string
  orderNsu: string
  items: InfinitePayItem[]
  redirectUrl?: string | null
  webhookUrl?: string | null
  customer?: InfinitePayCustomer | null
}

export type InfinitePayCheckoutLink = {
  url: string
  raw: Record<string, unknown>
}

export type InfinitePayPaymentSignal = {
  orderNsu: string
  transactionNsu: string
  slug: string
  receiptUrl: string | null
  captureMethod: InfinitePayCaptureMethod | null
}

export type InfinitePayPaymentCheck = {
  success: boolean
  paid: boolean
  amount: number
  paidAmount: number
  installments: number | null
  captureMethod: InfinitePayCaptureMethod | null
  raw: Record<string, unknown>
}

export type InfinitePayVerifiedPayment = {
  orderNsu: string
  transactionNsu: string
  slug: string
  receiptUrl: string | null
  captureMethod: InfinitePayCaptureMethod
  agendaMethod: InfinitePayAgendaMethod
  installments: number
  amount: number
  paidAmount: number
  raw: Record<string, unknown>
}

export type InfinitePayTransport = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>

const API_BASE = 'https://api.checkout.infinitepay.io'
const CHECKOUT_HOSTS = new Set([
  'checkout.infinitepay.com.br',
  'checkout.infinitepay.io',
])

function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('INFINITEPAY_RESPONSE_INVALID')
  return value as Record<string, unknown>
}

function text(value: unknown): string {
  return typeof value === 'string' ? value.trim() : ''
}

function requiredIdentifier(value: unknown, code: string): string {
  const normalized = text(value)
  if (!/^[A-Za-z0-9._:-]{1,160}$/.test(normalized)) throw new Error(code)
  return normalized
}

function optionalReceiptUrl(value: unknown): string | null {
  const normalized = text(value)
  if (!normalized) return null
  const url = safeHttpsUrl(normalized, 'INFINITEPAY_RECEIPT_URL_INVALID')
  return url.toString()
}

function captureMethod(value: unknown, required: boolean): InfinitePayCaptureMethod | null {
  const normalized = text(value).toLowerCase()
  if (!normalized && !required) return null
  if (normalized !== 'pix' && normalized !== 'credit_card') throw new Error('INFINITEPAY_CAPTURE_METHOD_INVALID')
  return normalized
}

function integer(value: unknown, code: string, min = 0, max = Number.MAX_SAFE_INTEGER): number {
  const number = Number(value)
  if (!Number.isSafeInteger(number) || number < min || number > max) throw new Error(code)
  return number
}

function safeHttpsUrl(value: string, code: string): URL {
  let url: URL
  try {
    url = new URL(value)
  } catch {
    throw new Error(code)
  }
  if (url.protocol !== 'https:') throw new Error(code)
  return url
}

function validateHandle(value: string): string {
  const handle = value.trim()
  if (handle.startsWith('$') || !/^[A-Za-z0-9._-]{2,80}$/.test(handle)) throw new Error('INFINITEPAY_HANDLE_INVALID')
  return handle
}

function validateCustomer(value: InfinitePayCustomer | null | undefined): InfinitePayCustomer | undefined {
  if (!value) return undefined
  const name = value.name.trim()
  const email = value.email.trim().toLowerCase()
  const phone = value.phone_number?.trim() ?? ''
  if (name.length < 2 || name.length > 160) throw new Error('INFINITEPAY_CUSTOMER_NAME_INVALID')
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254) throw new Error('INFINITEPAY_CUSTOMER_EMAIL_INVALID')
  if (phone && !/^\+?[0-9]{8,20}$/.test(phone.replace(/[\s()-]/g, ''))) throw new Error('INFINITEPAY_CUSTOMER_PHONE_INVALID')
  return {
    name,
    email,
    ...(phone ? { phone_number: phone.replace(/[\s()-]/g, '') } : {}),
  }
}

function validateItems(items: InfinitePayItem[]): InfinitePayItem[] {
  if (!Array.isArray(items) || items.length < 1 || items.length > 20) throw new Error('INFINITEPAY_ITEMS_INVALID')
  return items.map((item) => {
    const quantity = integer(item.quantity, 'INFINITEPAY_ITEM_QUANTITY_INVALID', 1, 100)
    const price = integer(item.price, 'INFINITEPAY_ITEM_PRICE_INVALID', 1, 100_000_000)
    const description = item.description.trim()
    if (!description || description.length > 160) throw new Error('INFINITEPAY_ITEM_DESCRIPTION_INVALID')
    return { quantity, price, description }
  })
}

async function readJson(response: Response): Promise<Record<string, unknown>> {
  try {
    return object(await response.json())
  } catch (cause) {
    if (cause instanceof Error && cause.message === 'INFINITEPAY_RESPONSE_INVALID') throw cause
    throw new Error('INFINITEPAY_RESPONSE_INVALID')
  }
}

async function postJson(
  path: '/links' | '/payment_check',
  body: Record<string, unknown>,
  transport: InfinitePayTransport,
): Promise<{ status: number; data: Record<string, unknown> }> {
  let response: Response
  try {
    response = await transport(`${API_BASE}${path}`, {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'application/json' },
      body: JSON.stringify(body),
    })
  } catch {
    throw new Error('INFINITEPAY_NETWORK_ERROR')
  }
  const data = await readJson(response)
  if (response.status < 200 || response.status >= 300) {
    const error = new Error(`INFINITEPAY_PROVIDER_HTTP_${response.status}`)
    Object.assign(error, { providerStatus: response.status, providerData: data })
    throw error
  }
  return { status: response.status, data }
}

export function brlToCents(value: number | string): number {
  const amount = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(amount) || amount <= 0) throw new Error('INFINITEPAY_AMOUNT_INVALID')
  const cents = Math.round(amount * 100)
  if (!Number.isSafeInteger(cents) || cents <= 0) throw new Error('INFINITEPAY_AMOUNT_INVALID')
  if (Math.abs(amount * 100 - cents) > 0.000001) throw new Error('INFINITEPAY_AMOUNT_PRECISION_INVALID')
  return cents
}

export function infinitePayAgendaMethod(method: InfinitePayCaptureMethod): InfinitePayAgendaMethod {
  return method === 'pix' ? 'PIX' : 'CARD'
}

export async function createInfinitePayCheckoutLink(
  input: InfinitePayCreateLinkInput,
  transport: InfinitePayTransport = fetch,
): Promise<InfinitePayCheckoutLink> {
  const handle = validateHandle(input.handle)
  const orderNsu = requiredIdentifier(input.orderNsu, 'INFINITEPAY_ORDER_NSU_INVALID')
  const items = validateItems(input.items)
  const redirectUrl = input.redirectUrl ? safeHttpsUrl(input.redirectUrl, 'INFINITEPAY_REDIRECT_URL_INVALID').toString() : undefined
  const webhookUrl = input.webhookUrl ? safeHttpsUrl(input.webhookUrl, 'INFINITEPAY_WEBHOOK_URL_INVALID').toString() : undefined
  const customer = validateCustomer(input.customer)

  const payload: Record<string, unknown> = {
    handle,
    order_nsu: orderNsu,
    items,
    ...(redirectUrl ? { redirect_url: redirectUrl } : {}),
    ...(webhookUrl ? { webhook_url: webhookUrl } : {}),
    ...(customer ? { customer } : {}),
  }

  const { data } = await postJson('/links', payload, transport)
  const rawUrl = text(data.url)
  const checkoutUrl = safeHttpsUrl(rawUrl, 'INFINITEPAY_CHECKOUT_URL_INVALID')
  if (!CHECKOUT_HOSTS.has(checkoutUrl.hostname.toLowerCase())) throw new Error('INFINITEPAY_CHECKOUT_URL_INVALID')
  return { url: checkoutUrl.toString(), raw: data }
}

export async function checkInfinitePayPayment(
  input: { handle: string; orderNsu: string; transactionNsu: string; slug: string },
  transport: InfinitePayTransport = fetch,
): Promise<InfinitePayPaymentCheck> {
  const payload = {
    handle: validateHandle(input.handle),
    order_nsu: requiredIdentifier(input.orderNsu, 'INFINITEPAY_ORDER_NSU_INVALID'),
    transaction_nsu: requiredIdentifier(input.transactionNsu, 'INFINITEPAY_TRANSACTION_NSU_INVALID'),
    slug: requiredIdentifier(input.slug, 'INFINITEPAY_SLUG_INVALID'),
  }
  const { data } = await postJson('/payment_check', payload, transport)
  if (typeof data.success !== 'boolean' || typeof data.paid !== 'boolean') throw new Error('INFINITEPAY_PAYMENT_CHECK_INVALID')
  const amount = integer(data.amount, 'INFINITEPAY_PAYMENT_AMOUNT_INVALID', 0)
  const paidAmount = integer(data.paid_amount, 'INFINITEPAY_PAID_AMOUNT_INVALID', 0)
  const method = captureMethod(data.capture_method, data.paid === true)
  const installments = data.installments == null
    ? null
    : integer(data.installments, 'INFINITEPAY_INSTALLMENTS_INVALID', 1, 12)
  if (data.paid && installments == null) throw new Error('INFINITEPAY_INSTALLMENTS_INVALID')
  return {
    success: data.success,
    paid: data.paid,
    amount,
    paidAmount,
    installments,
    captureMethod: method,
    raw: data,
  }
}

export function parseInfinitePayWebhookSignal(value: unknown): InfinitePayPaymentSignal {
  const row = object(value)
  return {
    orderNsu: requiredIdentifier(row.order_nsu, 'INFINITEPAY_ORDER_NSU_INVALID'),
    transactionNsu: requiredIdentifier(row.transaction_nsu, 'INFINITEPAY_TRANSACTION_NSU_INVALID'),
    slug: requiredIdentifier(row.invoice_slug, 'INFINITEPAY_SLUG_INVALID'),
    receiptUrl: optionalReceiptUrl(row.receipt_url),
    captureMethod: captureMethod(row.capture_method, false),
  }
}

export function parseInfinitePayRedirectSignal(url: URL): InfinitePayPaymentSignal {
  return {
    orderNsu: requiredIdentifier(url.searchParams.get('order_nsu'), 'INFINITEPAY_ORDER_NSU_INVALID'),
    transactionNsu: requiredIdentifier(url.searchParams.get('transaction_nsu'), 'INFINITEPAY_TRANSACTION_NSU_INVALID'),
    slug: requiredIdentifier(url.searchParams.get('slug'), 'INFINITEPAY_SLUG_INVALID'),
    receiptUrl: optionalReceiptUrl(url.searchParams.get('receipt_url')),
    captureMethod: captureMethod(url.searchParams.get('capture_method'), false),
  }
}

export function verifyInfinitePayPayment(input: {
  signal: InfinitePayPaymentSignal
  check: InfinitePayPaymentCheck
  expectedOrderNsu: string
  expectedAmountCents: number
}): InfinitePayVerifiedPayment {
  const expectedOrderNsu = requiredIdentifier(input.expectedOrderNsu, 'INFINITEPAY_ORDER_NSU_INVALID')
  const expectedAmount = integer(input.expectedAmountCents, 'INFINITEPAY_EXPECTED_AMOUNT_INVALID', 1)
  if (input.signal.orderNsu !== expectedOrderNsu) throw new Error('INFINITEPAY_ORDER_NSU_MISMATCH')
  if (!input.check.success) throw new Error('INFINITEPAY_PAYMENT_CHECK_UNSUCCESSFUL')
  if (!input.check.paid) throw new Error('INFINITEPAY_PAYMENT_NOT_PAID')
  if (input.check.amount !== expectedAmount) throw new Error('INFINITEPAY_PAYMENT_AMOUNT_MISMATCH')
  if (!input.check.captureMethod) throw new Error('INFINITEPAY_CAPTURE_METHOD_INVALID')
  if (!input.check.installments) throw new Error('INFINITEPAY_INSTALLMENTS_INVALID')
  if (input.signal.captureMethod && input.signal.captureMethod !== input.check.captureMethod) {
    throw new Error('INFINITEPAY_CAPTURE_METHOD_MISMATCH')
  }

  return {
    orderNsu: input.signal.orderNsu,
    transactionNsu: input.signal.transactionNsu,
    slug: input.signal.slug,
    receiptUrl: input.signal.receiptUrl,
    captureMethod: input.check.captureMethod,
    agendaMethod: infinitePayAgendaMethod(input.check.captureMethod),
    installments: input.check.installments,
    amount: input.check.amount,
    paidAmount: input.check.paidAmount,
    raw: input.check.raw,
  }
}

export function infinitePayPaymentStorageSnapshot(payment: InfinitePayVerifiedPayment): Record<string, unknown> {
  return {
    order_nsu: payment.orderNsu,
    transaction_nsu: payment.transactionNsu,
    slug: payment.slug,
    receipt_url: payment.receiptUrl,
    capture_method: payment.captureMethod,
    amount: payment.amount,
    paid_amount: payment.paidAmount,
    installments: payment.installments,
    payment_check: payment.raw,
  }
}
