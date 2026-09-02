const API_URL = requiredEnv('LOCAL_API_URL').replace(/\/+$/, '')
const ANON_KEY = requiredEnv('LOCAL_ANON_KEY')
const SERVICE_ROLE_KEY = requiredEnv('LOCAL_SERVICE_ROLE_KEY')
const LOCAL_GOOGLE_KEY_B64 = 'bG9jYWwtdmVyaWZpY2F0aW9uLWtleS0zMi1ieXRlcyE='

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim() ?? ''
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
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

async function encryptLocalRefreshToken(token: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    asArrayBuffer(base64ToBytes(LOCAL_GOOGLE_KEY_B64)),
    { name: 'AES-GCM' },
    false,
    ['encrypt'],
  )
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const cipher = await crypto.subtle.encrypt(
    { name: 'AES-GCM', iv: asArrayBuffer(iv) },
    key,
    asArrayBuffer(new TextEncoder().encode(token)),
  )
  return `v1.${bytesToBase64(iv)}.${bytesToBase64(new Uint8Array(cipher))}`
}

async function requestJson(
  url: string,
  init: RequestInit,
  expectedStatuses: number[] = [200],
): Promise<any> {
  const response = await fetch(url, init)
  const text = await response.text()
  let body: any = {}
  try {
    body = text ? JSON.parse(text) : {}
  } catch {
    throw new Error(`INVALID_JSON:${response.status}:${text.slice(0, 200)}`)
  }
  if (!expectedStatuses.includes(response.status)) {
    throw new Error(`HTTP_${response.status}:${url}:${JSON.stringify(body)}`)
  }
  return body
}

function serviceRoleHeaders(extra: Record<string, string> = {}): HeadersInit {
  return {
    apikey: SERVICE_ROLE_KEY,
    authorization: `Bearer ${SERVICE_ROLE_KEY}`,
    'content-type': 'application/json',
    ...extra,
  }
}

async function createAdminSession(): Promise<string> {
  const email = `acl-google-admin-${crypto.randomUUID()}@example.test`
  const password = `LocalOnly-${crypto.randomUUID()}-A1!`
  const created = await requestJson(`${API_URL}/auth/v1/admin/users`, {
    method: 'POST',
    headers: serviceRoleHeaders(),
    body: JSON.stringify({ email, password, email_confirm: true }),
  }, [200, 201])
  const authUserId = String(created.id ?? created.user?.id ?? '')
  assert(/^[0-9a-f-]{36}$/i.test(authUserId), 'local auth admin must be created')

  await requestJson(`${API_URL}/rest/v1/rpc/qa_register_local_verification_admin`, {
    method: 'POST',
    headers: serviceRoleHeaders(),
    body: JSON.stringify({ p_auth_user_id: authUserId }),
  })

  const session = await requestJson(`${API_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON_KEY, 'content-type': 'application/json' },
    body: JSON.stringify({ email, password }),
  })
  const token = String(session.access_token ?? '')
  assert(token.length > 40, 'local admin must receive access token')
  return token
}

Deno.test('Phase 2A ACL baseline: Google sync worker reads and writes through service_role using only local provider transport', async () => {
  const connectionId = '99200000-0000-0000-0000-000000000010'
  const calendarId = '99200000-0000-0000-0000-000000000020'
  const encryptedRefreshToken = await encryptLocalRefreshToken('LOCAL_ONLY_google_refresh_token')

  await requestJson(`${API_URL}/rest/v1/google_connections`, {
    method: 'POST',
    headers: serviceRoleHeaders({ prefer: 'return=minimal' }),
    body: JSON.stringify({
      id: connectionId,
      account_email: 'local-google@example.test',
      refresh_token_ciphertext: encryptedRefreshToken,
      token_encryption_version: 1,
      scopes: ['calendar.events', 'calendar.calendarlist.readonly'],
      status: 'ACTIVE',
      owner_type: 'GENERAL',
    }),
  }, [201])

  await requestJson(`${API_URL}/rest/v1/google_calendars`, {
    method: 'POST',
    headers: serviceRoleHeaders({ prefer: 'return=minimal' }),
    body: JSON.stringify({
      id: calendarId,
      google_connection_id: connectionId,
      google_calendar_id: 'local-calendar@example.test',
      name: 'Local ACL Google Calendar',
      timezone: 'America/Sao_Paulo',
      is_active: true,
    }),
  }, [201])

  const adminToken = await createAdminSession()
  const sync = await requestJson(`${API_URL}/functions/v1/google-sync`, {
    method: 'POST',
    headers: {
      apikey: ANON_KEY,
      authorization: `Bearer ${adminToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ google_calendar_id: calendarId, force_full: true }),
  })

  assert(sync.google_calendar_id === calendarId, `worker must return local calendar id: ${JSON.stringify(sync)}`)
  assert(sync.mode === 'FULL', `worker must execute full local sync: ${JSON.stringify(sync)}`)
  assert(sync.health_status === 'HEALTHY', `worker must finish healthy: ${JSON.stringify(sync)}`)
  assert(Number(sync.processed) === 0, `empty Google mock must process zero events: ${JSON.stringify(sync)}`)

  const states = await requestJson(
    `${API_URL}/rest/v1/google_sync_state?google_calendar_id=eq.${calendarId}&select=google_calendar_id,sync_token,health_status,last_success_at`,
    { method: 'GET', headers: serviceRoleHeaders() },
  )
  assert(Array.isArray(states) && states.length === 1, `sync state must be persisted: ${JSON.stringify(states)}`)
  assert(states[0].health_status === 'HEALTHY', `sync state must be healthy: ${JSON.stringify(states[0])}`)
  assert(states[0].sync_token === 'LOCAL_ONLY_sync_token', `mock sync token must be persisted: ${JSON.stringify(states[0])}`)
  assert(Boolean(states[0].last_success_at), `last_success_at must be persisted: ${JSON.stringify(states[0])}`)
})
