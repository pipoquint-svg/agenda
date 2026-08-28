export type EmailOperationScope = 'BLACKSHEEP' | 'SABRINA'

export type EmailSender = {
  brandName: string
  from: string
  replyTo: string | null
}

export type EmailProviderPayload = {
  from: string
  to: string[]
  subject: string
  text?: string
  html?: string
  reply_to?: string
}

const RESEND_EMAIL_ENDPOINT = 'https://api.resend.com/emails'
const DEFAULT_PROVIDER_TIMEOUT_MS = 15_000

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? ''
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

export function emailProviderName(): 'RESEND' {
  return 'RESEND'
}

export function senderForScope(scope: string): EmailSender | null {
  const normalized = scope.trim().toUpperCase() as EmailOperationScope
  if (normalized === 'BLACKSHEEP') {
    const from = Deno.env.get('EMAIL_FROM_BLACKSHEEP')?.trim() ?? ''
    if (!from) return null
    return {
      brandName: 'BlackSheep Estúdio Criativo',
      from,
      replyTo: Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP')?.trim() || null,
    }
  }
  if (normalized === 'SABRINA') {
    const from = Deno.env.get('EMAIL_FROM_SABRINA')?.trim() ?? ''
    if (!from) return null
    return {
      brandName: 'Sabrina Pierri',
      from,
      replyTo: Deno.env.get('EMAIL_REPLY_TO_SABRINA')?.trim() || null,
    }
  }
  return null
}

export async function sendEmailWithProvider(
  payload: EmailProviderPayload,
  idempotencyKey: string,
  options: { fetchImpl?: typeof fetch; timeoutMs?: number; apiKey?: string } = {},
): Promise<string | null> {
  if (!payload.from.trim()) throw new Error('EMAIL_PROVIDER_FROM_REQUIRED')
  if (!Array.isArray(payload.to) || payload.to.length === 0) throw new Error('EMAIL_PROVIDER_TO_REQUIRED')
  if (!payload.subject.trim()) throw new Error('EMAIL_PROVIDER_SUBJECT_REQUIRED')
  if (!idempotencyKey.trim()) throw new Error('EMAIL_PROVIDER_IDEMPOTENCY_KEY_REQUIRED')

  const apiKey = options.apiKey?.trim() || requiredEnv('RESEND_API_KEY')
  const fetchImpl = options.fetchImpl ?? fetch
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs ?? DEFAULT_PROVIDER_TIMEOUT_MS)

  let response: Response
  try {
    response = await fetchImpl(RESEND_EMAIL_ENDPOINT, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${apiKey}`,
        'content-type': 'application/json',
        'idempotency-key': idempotencyKey,
      },
      body: JSON.stringify(payload),
      signal: controller.signal,
    })
  } catch (error) {
    if (error instanceof DOMException && error.name === 'AbortError') throw new Error('EMAIL_PROVIDER_TIMEOUT')
    throw new Error('EMAIL_PROVIDER_NETWORK_ERROR')
  } finally {
    clearTimeout(timeout)
  }

  const responseText = await response.text()
  if (!response.ok) throw new Error(`EMAIL_PROVIDER_HTTP_${response.status}`)
  if (!responseText) return null

  try {
    const parsed = JSON.parse(responseText)
    return typeof parsed?.id === 'string' ? parsed.id : null
  } catch {
    throw new Error('EMAIL_PROVIDER_INVALID_RESPONSE')
  }
}
