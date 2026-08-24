import { adminClient } from '../_shared/supabase.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'POST, OPTIONS',
}

const LEGACY_DURATION_BLOCKS_REMOVAL_DATE = '2026-09-07'
const LEGACY_DURATION_BLOCKS_CUTOFF = Date.parse('2026-09-07T03:00:00.000Z')

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function requiredString(value: unknown, code: string): string {
  if (typeof value !== 'string' || !value.trim()) throw new Error(code)
  return value.trim()
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const client = adminClient()
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'CHECKOUT_HOLD_CREATE',
      limit: 30,
      windowSeconds: 600,
    })

    const body = await req.json()
    const pageSlug = requiredString(body?.booking_page_slug, 'BOOKING_PAGE_REQUIRED')
    const serviceId = requiredString(body?.service_id, 'SERVICE_REQUIRED')
    const employeeId = requiredString(body?.service_employee_id, 'SERVICE_EMPLOYEE_REQUIRED')
    const requestedStartAt = requiredString(body?.requested_start_at, 'REQUESTED_START_REQUIRED')
    const extras = Array.isArray(body?.extra_selections) ? body.extra_selections : []
    const peopleCount = Number.isInteger(body?.people_count) ? body.people_count as number : NaN
    if (!Number.isInteger(peopleCount)) throw new Error('INVALID_PEOPLE_COUNT')

    const attribution = body?.attribution_json === undefined || body?.attribution_json === null ? {} : body.attribution_json
    if (typeof attribution !== 'object' || Array.isArray(attribution)) throw new Error('ATTRIBUTION_INVALID')

    const hasContractedMinutes = Object.prototype.hasOwnProperty.call(body ?? {}, 'contracted_minutes')
    const hasDurationBlocks = Object.prototype.hasOwnProperty.call(body ?? {}, 'duration_blocks')
    if (hasContractedMinutes && hasDurationBlocks) throw new Error('AMBIGUOUS_DURATION_CONTRACT')

    const contractedMinutes = body?.contracted_minutes
    const durationBlocks = body?.duration_blocks

    if (hasContractedMinutes && !Number.isInteger(contractedMinutes)) throw new Error('INVALID_CONTRACTED_MINUTES')
    if (hasDurationBlocks && durationBlocks !== null && !Number.isInteger(durationBlocks)) throw new Error('INVALID_DURATION_BLOCKS')

    let rpcName = 'public_create_checkout_hold_tracked'
    let args: Record<string, unknown> = {
      p_booking_page_slug: pageSlug,
      p_service_id: serviceId,
      p_service_employee_id: employeeId,
      p_extra_selections: extras,
      p_people_count: peopleCount,
      p_requested_start_at: requestedStartAt,
      p_attribution_json: attribution,
    }

    if (hasContractedMinutes) {
      rpcName = 'public_create_checkout_hold_tracked_minutes'
      args = { ...args, p_contracted_minutes: contractedMinutes }
    } else if (hasDurationBlocks) {
      if (Date.now() >= LEGACY_DURATION_BLOCKS_CUTOFF) throw new Error('LEGACY_DURATION_CONTRACT_EXPIRED')
      rpcName = 'public_create_checkout_hold_tracked_duration'
      args = { ...args, p_duration_blocks: durationBlocks }
      console.warn('[LEGACY_CONTRACT] duration_blocks received', {
        surface: 'BOOKING_HOLD',
        removal_date: LEGACY_DURATION_BLOCKS_REMOVAL_DATE,
        booking_page_slug: pageSlug,
        service_id: serviceId,
      })
      const { error: metricError } = await client.from('booking_contract_legacy_usage').insert({
        surface: 'BOOKING_HOLD',
        booking_page_slug: pageSlug,
        service_id: serviceId,
        duration_blocks: durationBlocks,
        user_agent: req.headers.get('user-agent'),
      })
      if (metricError) console.error('[OPERATION_ALERT] LEGACY_DURATION_METRIC_WRITE_FAILED', { surface: 'BOOKING_HOLD' })
    }

    const { data, error } = await client.rpc(rpcName, args)
    if (error) throw new Error(error.message)
    return response({ hold: data }, 201)
  } catch (error) {
    const code = error instanceof Error ? error.message : 'CHECKOUT_HOLD_CREATE_FAILED'
    const publicCode = code.match(/(RATE_LIMITED|RATE_LIMIT_BACKEND_FAILED|BOOKING_PAGE_REQUIRED|SERVICE_REQUIRED|SERVICE_EMPLOYEE_REQUIRED|REQUESTED_START_REQUIRED|INVALID_PEOPLE_COUNT|INVALID_DURATION_BLOCKS|INVALID_CONTRACTED_MINUTES|AMBIGUOUS_DURATION_CONTRACT|LEGACY_DURATION_CONTRACT_EXPIRED|ATTRIBUTION_INVALID|BOOKING_PAGE_NOT_FOUND|SERVICE_NOT_AVAILABLE|SERVICE_EMPLOYEE_NOT_AVAILABLE|INVALID_BOOKING_SELECTION|SLOT_NOT_AVAILABLE|RESOURCE_NOT_AVAILABLE|INVALID_EXTRA_SELECTION|REQUIRED_EXTRA_MISSING)/)?.[1] ?? code.split(':')[0]
    const status = publicCode === 'RATE_LIMITED' ? 429
      : publicCode === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : publicCode === 'SLOT_NOT_AVAILABLE' || publicCode === 'RESOURCE_NOT_AVAILABLE' ? 409
      : publicCode === 'LEGACY_DURATION_CONTRACT_EXPIRED' ? 410
      : 400
    return response({ error: { code: publicCode } }, status)
  }
})
