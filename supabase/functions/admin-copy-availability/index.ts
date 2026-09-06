import { adminClient, requireAdminPermission } from '../_shared/supabase.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function uuid(value: unknown): string {
  const next = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(next)) {
    throw new Error('UUID_INVALID')
  }
  return next
}

function uuidArray(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error('UUID_ARRAY_INVALID')
  const unique = [...new Set(value.map((item) => uuid(item)))]
  if (unique.length < 1 || unique.length > 25) throw new Error('AVAILABILITY_COPY_TARGETS_INVALID')
  return unique
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdminPermission(req, 'SERVICES_MANAGE')
    const body = await req.json().catch(() => null)
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('AVAILABILITY_COPY_PAYLOAD_INVALID')

    const sourceServiceEmployeeId = uuid(body.source_service_employee_id)
    const targetServiceEmployeeIds = uuidArray(body.target_service_employee_ids)
    const copyWorkHours = body.copy_work_hours === true
    const copyBlocks = body.copy_blocks === true
    const copyOpens = body.copy_opens === true

    if (!copyWorkHours && !copyBlocks && !copyOpens) throw new Error('AVAILABILITY_COPY_NOTHING_SELECTED')

    const client = adminClient()
    const { data, error } = await client.rpc('admin_copy_employee_availability_audited', {
      p_source_service_employee_id: sourceServiceEmployeeId,
      p_target_service_employee_ids: targetServiceEmployeeIds,
      p_copy_work_hours: copyWorkHours,
      p_copy_blocks: copyBlocks,
      p_copy_opens: copyOpens,
      p_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return json(data)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'AVAILABILITY_COPY_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'ADMIN_PERMISSION_DENIED'
        ? 403
        : 400
    return json({ error: { code } }, status)
  }
})
