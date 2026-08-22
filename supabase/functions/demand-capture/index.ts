import { adminClient } from '../_shared/supabase.ts'
import { parseConfiguredBrands, validateDemandSubmission } from '../_shared/demand-capture.ts'
import { enforceDistributedPublicRateLimit } from '../_shared/public-rate-limit.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, OPTIONS',
}

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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })

  try {
    const brands = parseConfiguredBrands(Deno.env.get('DEMAND_CAPTURE_BRANDS'))
    const consentText = requiredEnv('DEMAND_CAPTURE_CONSENT_TEXT')
    const consentVersion = requiredEnv('DEMAND_CAPTURE_CONSENT_VERSION')
    if (/\u2014|\u2013/.test(consentText)) throw new Error('DEMAND_CAPTURE_CONSENT_TEXT_INVALID')

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

    // Preserve the existing policy (20 requests / 10 minutes), now in the shared DB
    // counter so separate Edge instances consume one aggregate quota.
    await enforceDistributedPublicRateLimit(client, req, {
      scope: 'DEMAND_CAPTURE',
      limit: 20,
      windowSeconds: 600,
    })

    const submission = validateDemandSubmission(await req.json(), brands)
    if (submission.consent_text_version !== consentVersion) throw new Error('CONSENT_VERSION_STALE')

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
      p_consent_text_version: submission.consent_text_version,
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
      : publicCode === 'CONSENT_VERSION_STALE' ? 409
      : publicCode.startsWith('MISSING_ENV') || publicCode.endsWith('_NOT_CONFIGURED') || publicCode === 'RATE_LIMIT_BACKEND_FAILED' ? 503
      : 400
    return response({ error: { code: publicCode } }, status)
  }
})
