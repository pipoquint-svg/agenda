import { adminClient } from '../_shared/supabase.ts'
import { parseConfiguredBrands, validateDemandSubmission } from '../_shared/demand-capture.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

const ipBuckets = new Map<string, { count: number; resetAt: number }>()

function response(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' },
  })
}

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim()
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function enforceIpRateLimit(req: Request): void {
  const ip = (req.headers.get('x-forwarded-for') ?? req.headers.get('cf-connecting-ip') ?? 'unknown')
    .split(',')[0]
    .trim()
  const now = Date.now()
  const current = ipBuckets.get(ip)
  if (!current || current.resetAt <= now) {
    ipBuckets.set(ip, { count: 1, resetAt: now + 10 * 60 * 1000 })
    return
  }
  if (current.count >= 20) throw new Error('RATE_LIMITED')
  current.count += 1
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    const brands = parseConfiguredBrands(Deno.env.get('DEMAND_CAPTURE_BRANDS'))
    const consentText = requiredEnv('DEMAND_CAPTURE_CONSENT_TEXT')
    const consentVersion = requiredEnv('DEMAND_CAPTURE_CONSENT_VERSION')
    const client = adminClient()

    if (req.method === 'GET') {
      const { data: services, error } = await client
        .from('services')
        .select('id, name')
        .eq('is_active', true)
        .order('sort_order')
        .order('name')
      if (error) throw new Error(`SERVICES_LOAD_FAILED:${error.message}`)

      return response({
        brands,
        services: services ?? [],
        consent: { text: consentText, version: consentVersion },
      })
    }

    if (req.method !== 'POST') return response({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)
    enforceIpRateLimit(req)

    const submission = validateDemandSubmission(await req.json(), brands)

    const { data: service, error: serviceError } = await client
      .from('services')
      .select('id, name')
      .eq('id', submission.service_id)
      .eq('is_active', true)
      .maybeSingle()

    if (serviceError) throw new Error(`SERVICE_LOOKUP_FAILED:${serviceError.message}`)
    if (!service) throw new Error('SERVICE_INVALID')

    const { error: createError } = await client.rpc('create_or_touch_demand_capture', {
      p_name: submission.name,
      p_whatsapp: submission.whatsapp,
      p_email: submission.email,
      p_brand: submission.brand,
      p_service_label: service.name,
      p_desired_date: submission.desired_date,
      p_desired_period: submission.desired_period,
      p_notes: submission.notes,
      p_source: 'site',
      p_campaign: submission.campaign,
      p_consent_contact: true,
      p_consent_text_version: consentVersion,
      p_consent_at: new Date().toISOString(),
    })

    if (createError) {
      const known = createError.message.match(/(CONSENT_REQUIRED|DESIRED_DATE_IN_PAST|RATE_LIMITED)/)?.[1]
      throw new Error(known ?? `DEMAND_CAPTURE_CREATE_FAILED:${createError.message}`)
    }

    return response({ ok: true, message: 'Interesse registrado com sucesso.' })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'DEMAND_CAPTURE_FAILED'
    const publicCode = code.split(':')[0]
    const status = publicCode === 'RATE_LIMITED' ? 429
      : publicCode.startsWith('MISSING_ENV') || publicCode.endsWith('_NOT_CONFIGURED') ? 503
      : 400
    return response({ error: { code: publicCode } }, status)
  }
})
