import { adminClient, errorResponse, jsonResponse, requireAdmin } from '../_shared/supabase.ts'
import {
  encryptRefreshToken,
  exchangeAuthorizationCode,
  googleJson,
  googleOAuthUrl,
  GOOGLE_SCOPES,
  randomSecret,
  sha256Hex,
} from '../_shared/google.ts'

type CalendarListResponse = {
  items?: Array<{
    id: string
    summary?: string
    timeZone?: string
    accessRole?: string
    primary?: boolean
  }>
  nextPageToken?: string
}

type UserInfo = { email?: string; id?: string }

function successUrl(): string {
  return Deno.env.get('GOOGLE_OAUTH_SUCCESS_URL') ?? Deno.env.get('APP_BASE_URL') ?? 'http://localhost:5173/admin/google'
}

function redirectResult(base: string, status: 'success' | 'error', code?: string): Response {
  const url = new URL(base)
  url.searchParams.set('google', status)
  if (code) url.searchParams.set('code', code)
  return Response.redirect(url.toString(), 302)
}

async function start(req: Request): Promise<Response> {
  const { adminId } = await requireAdmin(req)
  const rawState = randomSecret(32)
  const stateHash = await sha256Hex(rawState)
  const client = adminClient()
  const { error } = await client.from('google_oauth_states').insert({
    state_hash: stateHash,
    requested_by_admin_user_id: adminId,
    success_url: successUrl(),
    expires_at: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
  })
  if (error) throw new Error('GOOGLE_OAUTH_STATE_CREATE_FAILED')
  return jsonResponse({ authorization_url: googleOAuthUrl(rawState) })
}

async function callback(url: URL): Promise<Response> {
  const rawState = url.searchParams.get('state')
  const code = url.searchParams.get('code')
  if (!rawState) return redirectResult(successUrl(), 'error', 'GOOGLE_OAUTH_STATE_MISSING')

  const client = adminClient()
  const stateHash = await sha256Hex(rawState)
  const { data: stateData, error: stateError } = await client.rpc('consume_google_oauth_state', {
    p_state_hash: stateHash,
  })
  if (stateError) return redirectResult(successUrl(), 'error', stateError.message)

  const destination = stateData?.success_url ?? successUrl()
  if (url.searchParams.get('error')) return redirectResult(destination, 'error', 'GOOGLE_OAUTH_DENIED')
  if (!code) return redirectResult(destination, 'error', 'GOOGLE_OAUTH_CODE_MISSING')

  try {
    const tokens = await exchangeAuthorizationCode(code)
    const userInfo = await googleJson<UserInfo>('https://www.googleapis.com/oauth2/v2/userinfo', tokens.access_token)
    if (!userInfo.email) throw new Error('GOOGLE_ACCOUNT_EMAIL_UNAVAILABLE')

    const { data: existing } = await client
      .from('google_connections')
      .select('id, refresh_token_ciphertext')
      .eq('account_email', userInfo.email)
      .maybeSingle()

    let refreshCiphertext = existing?.refresh_token_ciphertext ?? null
    if (tokens.refresh_token) refreshCiphertext = await encryptRefreshToken(tokens.refresh_token)
    if (!refreshCiphertext) throw new Error('GOOGLE_REFRESH_TOKEN_MISSING_RECONNECT')

    const { data: connection, error: connectionError } = await client
      .from('google_connections')
      .upsert({
        account_email: userInfo.email,
        google_user_id: userInfo.id ?? null,
        refresh_token_ciphertext: refreshCiphertext,
        token_encryption_version: 1,
        scopes: tokens.scope ? tokens.scope.split(' ') : GOOGLE_SCOPES,
        status: 'ACTIVE',
        last_error: null,
        updated_at: new Date().toISOString(),
      }, { onConflict: 'account_email' })
      .select('id')
      .single()

    if (connectionError || !connection) throw new Error('GOOGLE_CONNECTION_SAVE_FAILED')

    const calendars: CalendarListResponse['items'] = []
    let pageToken: string | undefined
    do {
      const endpoint = new URL('https://www.googleapis.com/calendar/v3/users/me/calendarList')
      endpoint.searchParams.set('maxResults', '250')
      endpoint.searchParams.set('showHidden', 'true')
      if (pageToken) endpoint.searchParams.set('pageToken', pageToken)
      const page = await googleJson<CalendarListResponse>(endpoint.toString(), tokens.access_token)
      calendars.push(...(page.items ?? []))
      pageToken = page.nextPageToken
    } while (pageToken)

    const returnedIds: string[] = []
    for (const calendar of calendars) {
      if (!calendar.id) continue
      returnedIds.push(calendar.id)
      const { data: saved, error: calendarError } = await client
        .from('google_calendars')
        .upsert({
          google_connection_id: connection.id,
          google_calendar_id: calendar.id,
          name: calendar.summary ?? calendar.id,
          timezone: calendar.timeZone ?? 'America/Sao_Paulo',
          access_role: calendar.accessRole ?? null,
          is_primary: calendar.primary ?? false,
          is_active: true,
          updated_at: new Date().toISOString(),
        }, { onConflict: 'google_connection_id,google_calendar_id' })
        .select('id')
        .single()
      if (calendarError || !saved) throw new Error('GOOGLE_CALENDAR_CATALOG_SAVE_FAILED')
      await client.from('google_sync_state').upsert(
        { google_calendar_id: saved.id },
        { onConflict: 'google_calendar_id', ignoreDuplicates: true },
      )
    }

    const { data: knownCalendars } = await client
      .from('google_calendars')
      .select('id, google_calendar_id')
      .eq('google_connection_id', connection.id)
      .eq('is_active', true)

    for (const known of knownCalendars ?? []) {
      if (!returnedIds.includes(known.google_calendar_id)) {
        await client.from('google_calendars').update({ is_active: false, updated_at: new Date().toISOString() }).eq('id', known.id)
      }
    }

    return redirectResult(destination, 'success')
  } catch (error) {
    const code = error instanceof Error ? error.message : 'GOOGLE_OAUTH_CALLBACK_FAILED'
    return redirectResult(destination, 'error', code)
  }
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url)
    if (req.method === 'OPTIONS') return new Response(null, { status: 204 })
    if (url.searchParams.get('action') === 'callback' || url.searchParams.has('code') || url.searchParams.has('error')) {
      return await callback(url)
    }
    if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
    return await start(req)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'GOOGLE_OAUTH_FAILED'
    const authFailure = message.startsWith('ADMIN_')
    return errorResponse(error, authFailure ? 401 : 400)
  }
})
