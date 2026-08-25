import {
  decryptRefreshToken,
  encryptRefreshToken,
  googleJson,
  googleOAuthUrl,
  normalizeGoogleEvent,
  sha256Hex,
} from './google.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

Deno.test('refresh token encryption round-trips without storing plaintext', async () => {
  Deno.env.set('GOOGLE_TOKEN_ENCRYPTION_KEY', 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=')
  const plaintext = 'refresh-token-secret'
  const ciphertext = await encryptRefreshToken(plaintext)
  assert(ciphertext.startsWith('v1.'), 'ciphertext must be versioned')
  assert(!ciphertext.includes(plaintext), 'ciphertext must not contain plaintext')
  assert(await decryptRefreshToken(ciphertext) === plaintext, 'decrypted token must match input')
})

Deno.test('OAuth URL requests offline access, state and minimal calendar scopes', () => {
  Deno.env.set('GOOGLE_CLIENT_ID', 'client-id')
  Deno.env.set('GOOGLE_REDIRECT_URI', 'https://example.com/google-oauth')
  const url = new URL(googleOAuthUrl('state-value'))
  assert(url.origin === 'https://accounts.google.com', 'must use Google authorization origin')
  assert(url.searchParams.get('access_type') === 'offline', 'must request offline access')
  assert(url.searchParams.get('prompt') === 'consent', 'must request consent for refresh token')
  assert(url.searchParams.get('state') === 'state-value', 'must preserve CSRF state')
  const scope = url.searchParams.get('scope') ?? ''
  assert(scope.includes('calendar.events'), 'must request event scope')
  assert(scope.includes('calendar.calendarlist.readonly'), 'must request calendar list scope')
  assert(scope.includes('openid') && scope.includes('email'), 'must identify connected Google account')
})

Deno.test('Google HTTP failures never persist arbitrary provider response bodies', async () => {
  const originalFetch = globalThis.fetch
  globalThis.fetch = (() => Promise.resolve(new Response(
    JSON.stringify({ error: { message: 'sensitive-account-and-calendar-context' } }),
    { status: 403, headers: { 'content-type': 'application/json' } },
  ))) as typeof fetch
  try {
    let message = ''
    let status: number | undefined
    try {
      await googleJson('https://www.googleapis.com/calendar/v3/calendars/test/events', 'test-access-token')
    } catch (error) {
      message = error instanceof Error ? error.message : String(error)
      status = (error as Error & { status?: number }).status
    }
    assert(message === 'GOOGLE_HTTP_403', 'provider error must be reduced to deterministic status code')
    assert(status === 403, 'structured HTTP status must remain available for sync recovery logic')
    assert(!message.includes('sensitive-account'), 'provider response body must not reach logs or persistence')
  } finally {
    globalThis.fetch = originalFetch
  }
})

Deno.test('event normalization stores only needed self attendee and Agenda metadata', () => {
  const result = normalizeGoogleEvent({
    id: 'event-1',
    status: 'confirmed',
    summary: 'Session',
    start: { dateTime: '2035-01-15T09:00:00-03:00' },
    end: { dateTime: '2035-01-15T10:00:00-03:00' },
    attendees: [
      { email: 'someone@example.com', responseStatus: 'accepted' },
      { email: 'self@example.com', self: true, responseStatus: 'declined' },
    ],
    extendedProperties: { private: { bs_source: 'blacksheep_agenda', bs_appointment_id: '11111111-1111-1111-1111-111111111111' } },
  })
  assert(result.p_google_event_id === 'event-1', 'event id must be preserved')
  assert(result.p_self_response_status === 'declined', 'self response must be extracted')
  assert(result.p_managed_by_agenda === true, 'Agenda metadata must classify managed events')
  assert(result.p_start_at === '2035-01-15T09:00:00-03:00', 'timed start must be preserved')
  const payload = JSON.stringify(result.p_normalized_payload)
  assert(!payload.includes('someone@example.com'), 'other attendee PII must not be mirrored')
})

Deno.test('all-day and cancelled event shapes normalize safely', () => {
  const allDay = normalizeGoogleEvent({
    id: 'all-day', status: 'confirmed', start: { date: '2035-01-15' }, end: { date: '2035-01-16' },
  })
  assert(allDay.p_is_all_day === true, 'all-day flag must be set')
  assert(allDay.p_start_date === '2035-01-15' && allDay.p_end_date === '2035-01-16', 'all-day dates must be preserved')

  const cancelled = normalizeGoogleEvent({ id: 'cancelled-instance', status: 'cancelled', recurringEventId: 'series' })
  assert(cancelled.p_status === 'cancelled', 'cancelled status must be preserved')
  assert(cancelled.p_start_at === null && cancelled.p_start_date === null, 'cancelled instance may omit current start/end')
})

Deno.test('sha256 output is deterministic hexadecimal', async () => {
  const first = await sha256Hex('channel-token')
  const second = await sha256Hex('channel-token')
  assert(first === second, 'hash must be deterministic')
  assert(/^[0-9a-f]{64}$/.test(first), 'hash must be SHA-256 hex')
})
