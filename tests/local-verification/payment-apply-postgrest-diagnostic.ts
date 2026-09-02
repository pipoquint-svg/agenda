const apiUrlRaw = Deno.env.get('LOCAL_API_URL')?.trim() ?? ''
const serviceRoleKey = Deno.env.get('LOCAL_SERVICE_ROLE_KEY')?.trim() ?? ''

if (!apiUrlRaw || !serviceRoleKey) {
  throw new Error('LOCAL_POSTGREST_DIAGNOSTIC_ENV_MISSING')
}

const apiUrl = new URL(apiUrlRaw)
if (!['http:', 'https:'].includes(apiUrl.protocol)) {
  throw new Error('LOCAL_POSTGREST_DIAGNOSTIC_PROTOCOL_INVALID')
}
if (!['127.0.0.1', 'localhost'].includes(apiUrl.hostname)) {
  throw new Error(`LOCAL_POSTGREST_DIAGNOSTIC_NON_LOCAL_HOST_FORBIDDEN:${apiUrl.hostname}`)
}

const base = apiUrl.toString().replace(/\/$/, '')
const headers = {
  apikey: serviceRoleKey,
  authorization: `Bearer ${serviceRoleKey}`,
  'content-type': 'application/json',
}

const lookup = await fetch(
  `${base}/rest/v1/payment_transactions?select=id,appointment_id,cash_amount,method,status,provider_payment_id,created_at&provider=eq.MERCADO_PAGO&status=eq.PENDING&transaction_type=eq.CHARGE&order=created_at.desc&limit=1`,
  { headers },
)

const lookupBody = await lookup.text()
if (!lookup.ok) {
  console.error('LOCAL_POSTGREST_DIAGNOSTIC_LOOKUP_FAILED', {
    status: lookup.status,
    body: lookupBody,
  })
  Deno.exit(2)
}

const rows = JSON.parse(lookupBody) as Array<Record<string, unknown>>
const tx = rows[0]
if (!tx?.id || !tx?.appointment_id) {
  console.error('LOCAL_POSTGREST_DIAGNOSTIC_PENDING_TX_NOT_FOUND')
  Deno.exit(3)
}

const transactionId = String(tx.id)
const providerOrderId = `LOCAL_DIAG_${crypto.randomUUID().replaceAll('-', '')}`
const providerPaymentId = `LOCALPAY_DIAG_${crypto.randomUUID().replaceAll('-', '')}`
const now = new Date().toISOString()
const cashAmount = Number(tx.cash_amount)

if (!Number.isFinite(cashAmount)) {
  console.error('LOCAL_POSTGREST_DIAGNOSTIC_CASH_AMOUNT_INVALID', { transactionId })
  Deno.exit(4)
}

const payload = {
  p_transaction_id: transactionId,
  p_provider_payment_id: providerOrderId,
  p_normalized_status: 'APPROVED',
  p_event_key: `local-postgrest-diagnostic:${providerOrderId}:processed:accredited`,
  p_payload_json: {
    id: providerOrderId,
    provider_transaction_id: providerPaymentId,
    provider_transaction_count: 1,
    status: 'processed',
    status_detail: 'accredited',
    raw_status: 'processed',
    payment_method_id: 'pix',
    payment_type_id: 'bank_transfer',
    transaction_amount: cashAmount,
    installments: null,
    external_reference: transactionId,
    date_approved: now,
    date_created: now,
  },
  p_paid_at: now,
}

const response = await fetch(`${base}/rest/v1/rpc/apply_provider_payment_status`, {
  method: 'POST',
  headers,
  body: JSON.stringify(payload),
})
const body = await response.text()

console.error('LOCAL_POSTGREST_PAYMENT_APPLY_DIAGNOSTIC', {
  status: response.status,
  transactionId,
  appointmentId: String(tx.appointment_id),
  transactionStatusBefore: String(tx.status ?? ''),
  responseBody: body,
})

if (!response.ok) Deno.exit(5)
