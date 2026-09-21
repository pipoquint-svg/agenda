import { functionsBaseUrl, publicApiKey } from './supabase'
export type InvoiceFields = {
  billing_mode?: 'CHECKOUT' | 'INVOICE'
  invoice_due_days?: number | null
  invoice_due_at?: string | null
  payment_required?: boolean
  requires_manual_confirmation?: boolean
}
export async function invoiceRequest<T>(path: string, body: Record<string, unknown>): Promise<T> {
  const response = await fetch(`${functionsBaseUrl}/${path}`, {
    method: 'POST', headers: {'content-type':'application/json', apikey:publicApiKey, authorization:`Bearer ${publicApiKey}`}, body:JSON.stringify(body),
  })
  const payload = await response.json().catch(() => ({}))
  if (!response.ok || !payload.data) throw new Error(payload.error?.code ?? 'INVOICE_REQUEST_FAILED')
  return payload.data as T
}
