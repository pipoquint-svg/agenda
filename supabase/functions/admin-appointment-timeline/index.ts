import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, OPTIONS',
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function requireUuid(raw: string | null): string {
  const value = raw?.trim() ?? ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value)) {
    throw new Error('ADMIN_TIMELINE_APPOINTMENT_ID_INVALID')
  }
  return value
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'GET') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    if (!(await hasAdminPermission(admin.adminId, 'AUDIT_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')

    const appointmentId = requireUuid(new URL(req.url).searchParams.get('appointment_id'))
    const client = adminClient()

    const [appointmentResult, auditResult, tokenResult, tokenEventsResult] = await Promise.all([
      client.from('appointments').select('id,public_code,status,financial_status,start_at,end_at,service_name_snapshot,created_at,updated_at').eq('id', appointmentId).maybeSingle(),
      client.from('audit_logs').select('id,admin_user_id,entity_type,entity_id,action,before_json,after_json,origin,request_id,created_at').eq('entity_id', appointmentId).order('created_at', { ascending: true }),
      client.from('appointment_access_tokens').select('id,appointment_id,scope,expires_at,revoked_at,created_at,last_used_at,delivery_channel,destination_masked,consumed_at,consumed_action,issued_request_id').eq('appointment_id', appointmentId).order('created_at', { ascending: true }),
      client.from('appointment_token_events').select('id,appointment_access_token_id,appointment_id,event_type,channel,destination_masked,request_id,metadata_json,occurred_at,appointment_token_network_evidence(ip_address,user_agent,occurred_at,retain_until)').eq('appointment_id', appointmentId).order('occurred_at', { ascending: true }),
    ])

    if (appointmentResult.error) throw new Error('ADMIN_TIMELINE_APPOINTMENT_QUERY_FAILED')
    if (!appointmentResult.data) throw new Error('ADMIN_TIMELINE_APPOINTMENT_NOT_FOUND')
    if (auditResult.error) throw new Error('ADMIN_TIMELINE_AUDIT_QUERY_FAILED')
    if (tokenResult.error) throw new Error('ADMIN_TIMELINE_TOKEN_QUERY_FAILED')
    if (tokenEventsResult.error) throw new Error('ADMIN_TIMELINE_TOKEN_EVENT_QUERY_FAILED')

    const timeline = [
      ...(auditResult.data ?? []).map((row) => ({ kind: 'AUDIT', occurred_at: row.created_at, ...row })),
      ...(tokenEventsResult.data ?? []).map((row) => ({ kind: 'TOKEN_EVENT', occurred_at: row.occurred_at, ...row })),
    ].sort((a, b) => String(a.occurred_at).localeCompare(String(b.occurred_at)))

    return json({
      appointment: appointmentResult.data,
      tokens: tokenResult.data ?? [],
      timeline,
      export_version: 'appointment-audit-timeline-v1',
      generated_at: new Date().toISOString(),
    })
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'ADMIN_TIMELINE_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED' ? 403
      : code === 'ADMIN_TIMELINE_APPOINTMENT_NOT_FOUND' ? 404
      : 400
    return json({ error: { code } }, status)
  }
})
