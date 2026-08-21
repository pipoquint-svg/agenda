import { adminClient } from '../_shared/supabase.ts'
import { sha256Hex } from '../_shared/google.ts'

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response(null, { status: 405 })

  const channelId = req.headers.get('x-goog-channel-id')
  const resourceId = req.headers.get('x-goog-resource-id')
  const token = req.headers.get('x-goog-channel-token')
  const messageNumber = req.headers.get('x-goog-message-number') ?? 'unknown'
  const resourceState = req.headers.get('x-goog-resource-state') ?? 'unknown'

  if (!channelId || !resourceId || !token) return new Response(null, { status: 204 })

  try {
    const client = adminClient()
    const { data: channel } = await client
      .from('google_watch_channels')
      .select('id, google_calendar_id, channel_token_hash, status, expiration_at')
      .eq('channel_id', channelId)
      .eq('google_resource_id', resourceId)
      .eq('status', 'ACTIVE')
      .maybeSingle()

    if (!channel?.channel_token_hash) return new Response(null, { status: 204 })
    if (channel.expiration_at && new Date(channel.expiration_at).getTime() <= Date.now()) return new Response(null, { status: 204 })

    const suppliedHash = await sha256Hex(token)
    if (suppliedHash !== channel.channel_token_hash) return new Response(null, { status: 204 })

    const key = `google-calendar-sync:${channel.google_calendar_id}:${channelId}:${messageNumber}`
    await client.rpc('enqueue_google_calendar_sync', {
      p_google_calendar_id: channel.google_calendar_id,
      p_idempotency_key: key,
      p_payload_json: {
        source: 'GOOGLE_PUSH',
        channel_id: channelId,
        message_number: messageNumber,
        resource_state: resourceState,
      },
    })

    return new Response(null, { status: 204 })
  } catch {
    // Google retries non-2xx responses. The periodic reconciliation path remains the safety net,
    // so malformed/spoofed notifications are acknowledged without creating work.
    return new Response(null, { status: 204 })
  }
})
