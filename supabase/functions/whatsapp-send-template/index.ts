import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { buildResumeUrl, buildWhatsAppRecoveryTemplatePayload } from '../_shared/whatsapp.ts'

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)
  if (!value) throw new Error(`MISSING_ENV:${name}`)
  return value
}

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    requireInternal(req)
    const body = await req.json()
    const phone = body.phone as string | undefined
    const templateKey = body.template_key as string | undefined
    const resumeToken = body.resume_token as string | undefined
    if (!phone) throw new Error('WHATSAPP_PHONE_REQUIRED')
    if (!templateKey) throw new Error('MESSAGE_TEMPLATE_KEY_REQUIRED')
    if (!resumeToken) throw new Error('RECOVERY_TOKEN_REQUIRED')

    const client = adminClient()
    const { data: template, error: templateError } = await client
      .from('message_templates')
      .select('template_key, channel, provider_template_name, language_code, is_active')
      .eq('template_key', templateKey)
      .eq('channel', 'WHATSAPP')
      .eq('is_active', true)
      .maybeSingle()

    if (templateError || !template) throw new Error('MESSAGE_TEMPLATE_NOT_CONFIGURED')

    const resumeUrl = buildResumeUrl(requiredEnv('PUBLIC_BOOKING_BASE_URL'), resumeToken)
    const payload = buildWhatsAppRecoveryTemplatePayload(phone, template, resumeUrl)

    const version = requiredEnv('WHATSAPP_GRAPH_API_VERSION')
    const phoneNumberId = requiredEnv('WHATSAPP_PHONE_NUMBER_ID')
    const endpoint = `https://graph.facebook.com/${encodeURIComponent(version)}/${encodeURIComponent(phoneNumberId)}/messages`

    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        authorization: `Bearer ${requiredEnv('WHATSAPP_ACCESS_TOKEN')}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify(payload),
    })

    const responseBody = await response.json().catch(() => ({})) as Record<string, any>
    if (!response.ok) {
      const providerCode = responseBody?.error?.code ?? response.status
      throw new Error(`WHATSAPP_PROVIDER_${providerCode}`)
    }

    return jsonResponse({
      sent: true,
      template_key: templateKey,
      provider_message_id: responseBody?.messages?.[0]?.id ?? null,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'WHATSAPP_SEND_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 400)
  }
})
