import { adminClient, errorResponse, jsonResponse, requireAdmin } from '../_shared/supabase.ts'
import { decryptRefreshToken, googleJson, randomSecret, refreshAccessToken, sha256Hex } from '../_shared/google.ts'

async function authorize(req: Request): Promise<void> {
  const internal = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (internal && supplied === internal) return
  await requireAdmin(req)
}

type WatchResponse = {
  id: string
  resourceId: string
  expiration?: string
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    await authorize(req)
    const body = await req.json()
    const calendarId = body.google_calendar_id
    if (!calendarId) throw new Error('GOOGLE_CALENDAR_ID_REQUIRED')

    const webhookUrl = Deno.env.get('GOOGLE_WEBHOOK_URL')
    if (!webhookUrl) throw new Error('MISSING_ENV:GOOGLE_WEBHOOK_URL')

    const client = adminClient()
    const { data: calendar, error: calendarError } = await client
      .from('google_calendars')
      .select('id, google_calendar_id, google_connection_id, is_active')
      .eq('id', calendarId)
      .maybeSingle()
    if (calendarError || !calendar || !calendar.is_active) throw new Error('GOOGLE_CALENDAR_NOT_FOUND')

    const { data: connection } = await client
      .from('google_connections')
      .select('id, refresh_token_ciphertext, status')
      .eq('id', calendar.google_connection_id)
      .maybeSingle()
    if (!connection?.refresh_token_ciphertext || connection.status !== 'ACTIVE') throw new Error('GOOGLE_CONNECTION_UNHEALTHY')

    const refreshToken = await decryptRefreshToken(connection.refresh_token_ciphertext)
    const accessToken = (await refreshAccessToken(refreshToken)).access_token

    const channelId = crypto.randomUUID()
    const channelToken = randomSecret(32)
    const response = await googleJson<WatchResponse>(
      `https://www.googleapis.com/calendar/v3/calendars/${encodeURIComponent(calendar.google_calendar_id)}/events/watch`,
      accessToken,
      {
        method: 'POST',
        body: JSON.stringify({
          id: channelId,
          type: 'web_hook',
          address: webhookUrl,
          token: channelToken,
          params: { ttl: '518400' },
        }),
      },
    )

    if (!response.resourceId) throw new Error('GOOGLE_WATCH_RESOURCE_ID_MISSING')
    const expirationAt = response.expiration
      ? new Date(Number(response.expiration)).toISOString()
      : new Date(Date.now() + 6 * 24 * 60 * 60 * 1000).toISOString()

    const tokenHash = await sha256Hex(channelToken)
    const { error: insertError } = await client.from('google_watch_channels').insert({
      google_calendar_id: calendar.id,
      channel_id: channelId,
      google_resource_id: response.resourceId,
      channel_token_hash: tokenHash,
      expiration_at: expirationAt,
      status: 'ACTIVE',
    })
    if (insertError) throw new Error('GOOGLE_WATCH_SAVE_FAILED')

    const { data: olderChannels } = await client
      .from('google_watch_channels')
      .select('id, channel_id, google_resource_id')
      .eq('google_calendar_id', calendar.id)
      .eq('status', 'ACTIVE')
      .neq('channel_id', channelId)

    for (const old of olderChannels ?? []) {
      try {
        await googleJson<void>('https://www.googleapis.com/calendar/v3/channels/stop', accessToken, {
          method: 'POST',
          body: JSON.stringify({ id: old.channel_id, resourceId: old.google_resource_id }),
        })
        await client.from('google_watch_channels').update({ status: 'STOPPED', updated_at: new Date().toISOString() }).eq('id', old.id)
      } catch {
        await client.from('google_watch_channels').update({ status: 'REPLACED', updated_at: new Date().toISOString() }).eq('id', old.id)
      }
    }

    return jsonResponse({
      google_calendar_id: calendar.id,
      channel_id: channelId,
      expiration_at: expirationAt,
      status: 'ACTIVE',
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'GOOGLE_WATCH_FAILED'
    const authFailure = code.startsWith('ADMIN_')
    return errorResponse(error, authFailure ? 401 : 400)
  }
})
