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

Deno.test('Phase 2B RLS: Google sync reads connection and mutates calendar mirror through audited service-role paths', async () => {
  const connectionId = '99200000-0000-0000-0000-000000000010'
  const calendarId = '99200000-0000-0000-0000-000000000020'
  const externalEventId = 'LOCAL_ONLY_item02b_external_event'
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

  // Seed one external mirror row using the same service-role path used by internal
  // workers. A confirmed non-all-day event must have a valid interval by schema.
  // Full sync with an empty provider response must then actively cancel it,
  // proving an observable worker-side write to google_calendar_events behind RLS.
  await requestJson(`${API_URL}/rest/v1/google_calendar_events`, {
    method: 'POST',
    headers: serviceRoleHeaders({ prefer: 'return=minimal' }),
    body: JSON.stringify({
      google_calendar_id: calendarId,
      google_event_id: externalEventId,
      status: 'confirmed',
      summary: 'Local Item 2B external mirror',
      is_all_day: false,
      start_at: '2035-11-10T10:00:00-03:00',
      end_at: '2035-11-10T11:00:00-03:00',
      managed_by_agenda: false,
      normalized_payload: { source: 'local_item02b_rls_test' },
    }),
  }, [201])

  const beforeMirror = await requestJson(
    `${API_URL}/rest/v1/google_calendar_events?google_calendar_id=eq.${calendarId}&google_event_id=eq.${externalEventId}&select=google_event_id,status,qualification,managed_by_agenda`,
    { method: 'GET', headers: serviceRoleHeaders() },
  )
  assert(Array.isArray(beforeMirror) && beforeMirror.length === 1, `external mirror seed must exist: ${JSON.stringify(beforeMirror)}`)
  assert(beforeMirror[0].status === 'confirmed', `external mirror must start confirmed: ${JSON.stringify(beforeMirror[0])}`)

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
  assert(Number(sync.processed) === 0, `empty Google mock must process zero provider events: ${JSON.stringify(sync)}`)

  const afterMirror = await requestJson(
    `${API_URL}/rest/v1/google_calendar_events?google_calendar_id=eq.${calendarId}&google_event_id=eq.${externalEventId}&select=google_event_id,status,qualification,managed_by_agenda`,
    { method: 'GET', headers: serviceRoleHeaders() },
  )
  assert(Array.isArray(afterMirror) && afterMirror.length === 1, `external mirror must remain queryable: ${JSON.stringify(afterMirror)}`)
  assert(afterMirror[0].status === 'cancelled', `full-sync worker must cancel unseen external mirror: ${JSON.stringify(afterMirror[0])}`)
  assert(afterMirror[0].qualification === 'CANCELLED', `full-sync worker must persist cancelled qualification: ${JSON.stringify(afterMirror[0])}`)
  assert(afterMirror[0].managed_by_agenda === false, `external mirror must remain unmanaged: ${JSON.stringify(afterMirror[0])}`)

  const states = await requestJson(
    `${API_URL}/rest/v1/google_sync_state?google_calendar_id=eq.${calendarId}&select=google_calendar_id,sync_token,health_status,last_success_at`,
    { method: 'GET', headers: serviceRoleHeaders() },
  )
  assert(Array.isArray(states) && states.length === 1, `sync state must be persisted: ${JSON.stringify(states)}`)
  assert(states[0].health_status === 'HEALTHY', `sync state must be healthy: ${JSON.stringify(states[0])}`)
  assert(states[0].sync_token === 'LOCAL_ONLY_sync_token', `mock sync token must be persisted: ${JSON.stringify(states[0])}`)
  assert(Boolean(states[0].last_success_at), `last_success_at must be persisted: ${JSON.stringify(states[0])}`)

  const connections = await requestJson(
    `${API_URL}/rest/v1/google_connections?id=eq.${connectionId}&select=id,status`,
    { method: 'GET', headers: serviceRoleHeaders() },
  )
  assert(Array.isArray(connections) && connections.length === 1, `Google connection must remain available behind RLS: ${JSON.stringify(connections)}`)
  assert(connections[0].status === 'ACTIVE', `successful sync must keep Google connection active: ${JSON.stringify(connections[0])}`)
})
