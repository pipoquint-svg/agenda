export const GOOGLE_SCOPES = [
  'openid',
  'email',
  'https://www.googleapis.com/auth/calendar.events',
  'https://www.googleapis.com/auth/calendar.calendarlist.readonly',
]

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

function base64ToBytes(value: string): Uint8Array {
  const binary = atob(value)
  return Uint8Array.from(binary, (char) => char.charCodeAt(0))
}

function asArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength)
  copy.set(bytes)
  return copy.buffer
}

export async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', asArrayBuffer(new TextEncoder().encode(value)))
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

async function encryptionKey(): Promise<CryptoKey> {
  const raw = base64ToBytes(requiredEnv('GOOGLE_TOKEN_ENCRYPTION_KEY'))
  if (raw.byteLength !== 32) throw new Error('GOOGLE_TOKEN_ENCRYPTION_KEY_MUST_BE_32_BYTES_BASE64')
  return crypto.subtle.importKey('raw', asArrayBuffer(raw), { name: 'AES-GCM' }, false, ['encrypt', 'decrypt'])
}

export async function encryptRefreshToken(token: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const cipher = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: asArrayBuffer(iv) },
    await encryptionKey(),
    asArrayBuffer(new TextEncoder().encode(token)),
  )
  return `v1.${bytesToBase64(iv)}.${bytesToBase64(new Uint8Array(cipher))}`
}

export async function decryptRefreshToken(ciphertext: string): Promise<string> {
  const [version, iv64, cipher64] = ciphertext.split('.')
  if (version !== 'v1' || !iv64 || !cipher64) throw new Error('GOOGLE_REFRESH_TOKEN_CIPHERTEXT_INVALID')
  const plain = await crypto.subtle.decrypt(
    { name: 'AES-GCM', iv: asArrayBuffer(base64ToBytes(iv64)) },
    await encryptionKey(),
    asArrayBuffer(base64ToBytes(cipher64)),
  )
  return new TextDecoder().decode(plain)
}

export function googleOAuthUrl(state: string): string {
  const params = new URLSearchParams({
    client_id: requiredEnv('GOOGLE_CLIENT_ID'),
    redirect_uri: requiredEnv('GOOGLE_REDIRECT_URI'),
    response_type: 'code',
    access_type: 'offline',
    prompt: 'consent',
    include_granted_scopes: 'true',
    scope: GOOGLE_SCOPES.join(' '),
    state,
  })
  return `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`
}

export type GoogleTokenResponse = {
  access_token: string
  expires_in?: number
  refresh_token?: string
  scope?: string
  token_type?: string
  id_token?: string
}

async function postToken(params: URLSearchParams): Promise<GoogleTokenResponse> {
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: params,
  })
  const body = await response.json()
  if (!response.ok) {
    const code = body?.error === 'invalid_grant' ? 'GOOGLE_RECONNECT_REQUIRED' : 'GOOGLE_TOKEN_EXCHANGE_FAILED'
    throw new Error(code)
  }
  return body as GoogleTokenResponse
}

export function exchangeAuthorizationCode(code: string): Promise<GoogleTokenResponse> {
  return postToken(new URLSearchParams({
    code,
    client_id: requiredEnv('GOOGLE_CLIENT_ID'),
    client_secret: requiredEnv('GOOGLE_CLIENT_SECRET'),
    redirect_uri: requiredEnv('GOOGLE_REDIRECT_URI'),
    grant_type: 'authorization_code',
  }))
}

export function refreshAccessToken(refreshToken: string): Promise<GoogleTokenResponse> {
  return postToken(new URLSearchParams({
    refresh_token: refreshToken,
    client_id: requiredEnv('GOOGLE_CLIENT_ID'),
    client_secret: requiredEnv('GOOGLE_CLIENT_SECRET'),
    grant_type: 'refresh_token',
  }))
}

export async function googleJson<T>(url: string, accessToken: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers)
  headers.set('authorization', `Bearer ${accessToken}`)
  if (init.body && !headers.has('content-type')) headers.set('content-type', 'application/json')
  const response = await fetch(url, { ...init, headers })
  if (!response.ok) {
    // Provider response bodies can include user/account/resource context and are not
    // needed for deterministic retry/reconnect decisions. Persist only our bounded
    // status code; never copy arbitrary Google text into logs or database last_error.
    await response.body?.cancel().catch(() => undefined)
    const error = new Error(`GOOGLE_HTTP_${response.status}`)
    ;(error as Error & { status?: number }).status = response.status
    throw error
  }
  if (response.status === 204) return undefined as T
  return await response.json() as T
}

export type NormalizedGoogleEvent = {
  p_google_event_id: string
  p_status: string
  p_summary: string | null
  p_is_all_day: boolean
  p_start_at: string | null
  p_end_at: string | null
  p_start_date: string | null
  p_end_date: string | null
  p_transparency: string | null
  p_self_response_status: string | null
  p_recurring_event_id: string | null
  p_original_start_at: string | null
  p_original_start_date: string | null
  p_etag: string | null
  p_google_updated_at: string | null
  p_managed_by_agenda: boolean
  p_agenda_appointment_id: string | null
  p_bs_source: string | null
  p_normalized_payload: Record<string, unknown>
}

export function normalizeGoogleEvent(event: Record<string, any>): NormalizedGoogleEvent {
  const privateProps = event.extendedProperties?.private ?? {}
  const bsSource = typeof privateProps.bs_source === 'string' ? privateProps.bs_source : null
  const appointmentId = typeof privateProps.bs_appointment_id === 'string' ? privateProps.bs_appointment_id : null
  const isAllDay = Boolean(event.start?.date)
  const selfAttendee = Array.isArray(event.attendees) ? event.attendees.find((a: any) => a?.self === true) : undefined

  const payload = {
    id: event.id ?? null,
    status: event.status ?? null,
    summary: event.summary ?? null,
    start: event.start ?? null,
    end: event.end ?? null,
    transparency: event.transparency ?? null,
    recurringEventId: event.recurringEventId ?? null,
    originalStartTime: event.originalStartTime ?? null,
    etag: event.etag ?? null,
    updated: event.updated ?? null,
    selfResponseStatus: selfAttendee?.responseStatus ?? null,
    privateExtendedProperties: {
      bs_source: bsSource,
      bs_appointment_id: appointmentId,
    },
  }

  return {
    p_google_event_id: String(event.id ?? ''),
    p_status: String(event.status ?? 'confirmed'),
    p_summary: typeof event.summary === 'string' ? event.summary : null,
    p_is_all_day: isAllDay,
    p_start_at: !isAllDay && typeof event.start?.dateTime === 'string' ? event.start.dateTime : null,
    p_end_at: !isAllDay && typeof event.end?.dateTime === 'string' ? event.end.dateTime : null,
    p_start_date: isAllDay && typeof event.start?.date === 'string' ? event.start.date : null,
    p_end_date: isAllDay && typeof event.end?.date === 'string' ? event.end.date : null,
    p_transparency: typeof event.transparency === 'string' ? event.transparency : null,
    p_self_response_status: typeof selfAttendee?.responseStatus === 'string' ? selfAttendee.responseStatus : null,
    p_recurring_event_id: typeof event.recurringEventId === 'string' ? event.recurringEventId : null,
    p_original_start_at: typeof event.originalStartTime?.dateTime === 'string' ? event.originalStartTime.dateTime : null,
    p_original_start_date: typeof event.originalStartTime?.date === 'string' ? event.originalStartTime.date : null,
    p_etag: typeof event.etag === 'string' ? event.etag : null,
    p_google_updated_at: typeof event.updated === 'string' ? event.updated : null,
    p_managed_by_agenda: bsSource === 'blacksheep_agenda',
    p_agenda_appointment_id: appointmentId,
    p_bs_source: bsSource,
    p_normalized_payload: payload,
  }
}

export function randomSecret(bytes = 32): string {
  return bytesToBase64(crypto.getRandomValues(new Uint8Array(bytes))).replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '')
}
