import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'
import {
  encryptRefreshToken,
  exchangeAuthorizationCode,
  googleJson,
  googleOAuthUrl,
  GOOGLE_SCOPES,
  randomSecret,
  sha256Hex,
} from '../_shared/google.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, GET, OPTIONS',
}

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function errorResponse(error: unknown, status = 400): Response {
  const message = error instanceof Error ? error.message : 'UNKNOWN_ERROR'
  return jsonResponse({ error: { code: message } }, status)
}

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
type OwnerType = 'GENERAL' | 'EMPLOYEE'

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function uuidOrNull(value: unknown): string | null {
  const text = typeof value === 'string' ? value.trim() : ''
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(text) ? text : null
}

function successUrl(): string {
  const value = requiredEnv('GOOGLE_OAUTH_SUCCESS_URL')
  const url = new URL(value)
  if (url.protocol !== 'https:' && url.hostname !== 'localhost') throw new Error('GOOGLE_OAUTH_SUCCESS_URL_INVALID')
  return url.toString()
}

function redirectResult(base: string, status: 'success' | 'error', code?: string): Response {
  const url = new URL(base)
  url.searchParams.set('google', status)
  if (code) url.searchParams.set('code', code)
  return Response.redirect(url.toString(), 302)
}

async function start(req: Request): Promise<Response> {
  const { adminId } = await requireAdminPermission(req, 'INTEGRATIONS_MANAGE')
  const body = await req.json().catch(() => ({})) as Record<string, unknown>
  const ownerType: OwnerType = body.owner_type === 'EMPLOYEE' ? 'EMPLOYEE' : 'GENERAL'
  const employeeId = ownerType === 'EMPLOYEE' ? uuidOrNull(body.employee_id) : null
  if (ownerType === 'EMPLOYEE' && !employeeId) throw new Error('GOOGLE_EMPLOYEE_ID_REQUIRED')

  const destination = successUrl()
  const rawState = randomSecret(32)
  const stateHash = await sha256Hex(rawState)
  const client = adminClient()

  if (employeeId) {
    const { data: employee, error: employeeError } = await client
      .from('employees')
      .select('id,is_active')
      .eq('id', employeeId)
      .maybeSingle()
    if (employeeError || !employee || !employee.is_active) throw new Error('GOOGLE_EMPLOYEE_NOT_ACTIVE')
  }

  const { error } = await client.from('google_oauth_states').insert({
    state_hash: stateHash,
    requested_by_admin_user_id: adminId,
    success_url: destination,
    owner_type: ownerType,
    employee_id: employeeId,
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
    const ownerType: OwnerType = stateData?.owner_type === 'EMPLOYEE' ? 'EMPLOYEE' : 'GENERAL'
    const employeeId = ownerType === 'EMPLOYEE' ? uuidOrNull(stateData?.employee_id) : null
    if (ownerType === 'EMPLOYEE' && !employeeId) throw new Error('GOOGLE_OAUTH_OWNER_INVALID')

    const tokens = await exchangeAuthorizationCode(code)
    const userInfo = await googleJson<UserInfo>('https://www.googleapis.com/oauth2/v2/userinfo', tokens.access_token)
    if (!userInfo.email) throw new Error('GOOGLE_ACCOUNT_EMAIL_UNAVAILABLE')
    const accountEmail = userInfo.email.trim().toLowerCase()

    const { data: existing, error: existingError } = await client
      .from('google_connections')
      .select('id,refresh_token_ciphertext,status,owner_type,employee_id')
      .eq('account_email', accountEmail)
      .maybeSingle()
    if (existingError) throw new Error('GOOGLE_CONNECTION_LOOKUP_FAILED')

    if (existing?.status === 'ACTIVE') {
      const sameOwner = existing.owner_type === ownerType
        && (ownerType === 'GENERAL' || existing.employee_id === employeeId)
      if (!sameOwner) throw new Error('GOOGLE_ACCOUNT_ALREADY_ASSIGNED')
    }

    let ownerQuery = client
      .from('google_connections')
      .select('id,account_email')
      .eq('owner_type', ownerType)
      .eq('status', 'ACTIVE')
    ownerQuery = ownerType === 'EMPLOYEE'
      ? ownerQuery.eq('employee_id', employeeId as string)
      : ownerQuery.is('employee_id', null)
    const { data: activeOwners, error: ownerError } = await ownerQuery.limit(2)
    if (ownerError) throw new Error('GOOGLE_OWNER_LOOKUP_FAILED')
    if ((activeOwners ?? []).some((row) => row.id !== existing?.id)) throw new Error('GOOGLE_OWNER_ALREADY_CONNECTED')

    let refreshCiphertext = existing?.refresh_token_ciphertext ?? null
    if (tokens.refresh_token) refreshCiphertext = await encryptRefreshToken(tokens.refresh_token)
    if (!refreshCiphertext) throw new Error('GOOGLE_REFRESH_TOKEN_MISSING_RECONNECT')

    const { data: connection, error: connectionError } = await client
      .from('google_connections')
      .upsert({
        account_email: accountEmail,
        google_user_id: userInfo.id ?? null,
        refresh_token_ciphertext: refreshCiphertext,
        token_encryption_version: 1,
        scopes: tokens.scope ? tokens.scope.split(' ') : GOOGLE_SCOPES,
        owner_type: ownerType,
        employee_id: employeeId,
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
      .select('id,google_calendar_id')
      .eq('google_connection_id', connection.id)
      .eq('is_active', true)

    for (const known of knownCalendars ?? []) {
      if (!returnedIds.includes(known.google_calendar_id)) {
        await client.from('google_calendars')
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .eq('id', known.id)
      }
    }

    await client.from('audit_logs').insert({
      admin_user_id: stateData?.admin_user_id ?? null,
      entity_type: 'GOOGLE_CONNECTION',
      entity_id: connection.id,
      action: 'GOOGLE_ACCOUNT_CONNECTED',
      after_json: { owner_type: ownerType, employee_id: employeeId, account_email: accountEmail },
      origin: 'ADMIN',
    })

    return redirectResult(destination, 'success')
  } catch (error) {
    const code = error instanceof Error ? error.message : 'GOOGLE_OAUTH_CALLBACK_FAILED'
    return redirectResult(destination, 'error', code)
  }
}

Deno.serve(async (req) => {
  try {
    const url = new URL(req.url)
    if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
    if (url.searchParams.get('action') === 'callback' || url.searchParams.has('code') || url.searchParams.has('error')) {
      return await callback(url)
    }
    if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
    return await start(req)
  } catch (error) {
    const message = error instanceof Error ? error.message : 'GOOGLE_OAUTH_FAILED'
    const status = message === 'ADMIN_PERMISSION_DENIED' ? 403
      : message.startsWith('ADMIN_') ? 401
      : 400
    return errorResponse(error, status)
  }
})
