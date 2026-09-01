import { adminClient } from '../_shared/supabase.ts'

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
  })
}

function validUuid(value: unknown): string {
  const id = typeof value === 'string' ? value.trim() : ''
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(id)) {
    throw new Error('APPOINTMENT_ID_INVALID')
  }
  return id
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const supplied = req.headers.get('x-fastlane-secret')?.trim() ?? ''
    if (!supplied) return json({ error: { code: 'FASTLANE_AUTH_REQUIRED' } }, 401)

    const client = adminClient()
    const { data: authorized, error: authError } = await client.rpc('service_verify_google_appointment_fastlane_secret', {
      p_secret: supplied,
    })
    if (authError || authorized !== true) return json({ error: { code: 'FASTLANE_AUTH_REQUIRED' } }, 401)

    const body = await req.json().catch(() => ({})) as Record<string, unknown>
    const appointmentId = validUuid(body.appointment_id)
    const entityVersion = Number(body.entity_version)
    if (!Number.isInteger(entityVersion) || entityVersion < 1) {
      return json({ error: { code: 'ENTITY_VERSION_REQUIRED' } }, 400)
    }

    const base = Deno.env.get('SUPABASE_URL')?.trim().replace(/\/$/, '') ?? ''
    const internalSecret = Deno.env.get('INTEGRATION_INTERNAL_SECRET')?.trim() ?? ''
    if (!base || !internalSecret) return json({ error: { code: 'FASTLANE_RUNTIME_NOT_CONFIGURED' } }, 500)

    const controller = new AbortController()
    const timeout = setTimeout(() => controller.abort(), 20_000)
    try {
      const response = await fetch(`${base}/functions/v1/google-appointment-sync`, {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-internal-secret': internalSecret,
        },
        body: JSON.stringify({ appointment_id: appointmentId, entity_version: entityVersion }),
        signal: controller.signal,
      })
      const payload = await response.json().catch(() => null) as any
      if (!response.ok) {
        const upstreamCode = typeof payload?.error?.code === 'string'
          ? payload.error.code
          : 'GOOGLE_APPOINTMENT_SYNC_REJECTED'
        console.error('GOOGLE_APPOINTMENT_FASTLANE_SYNC_FAILED', {
          status: response.status,
          appointment_id: appointmentId,
          code: upstreamCode,
        })
        return json({ ok: false, retry_by_queue: true, upstream_code: upstreamCode }, 502)
      }
      return json({ ok: true, result: payload })
    } finally {
      clearTimeout(timeout)
    }
  } catch (error) {
    console.error('GOOGLE_APPOINTMENT_FASTLANE_FAILED', error instanceof Error ? error.message : 'UNKNOWN')
    return json({ ok: false, retry_by_queue: true }, 500)
  }
})
