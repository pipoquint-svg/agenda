export type WhatsAppTemplateConfig = {
  provider_template_name: string
  language_code: string
}

export function normalizeWhatsAppRecipient(value: string): string {
  const normalized = value.replace(/\D/g, '')
  if (normalized.length < 10 || normalized.length > 15) {
    throw new Error('WHATSAPP_RECIPIENT_INVALID')
  }
  return normalized
}

export function buildResumeUrl(baseUrl: string, resumeToken: string): string {
  if (!resumeToken) throw new Error('RECOVERY_TOKEN_REQUIRED')
  const base = baseUrl.replace(/\/+$/, '')
  if (!/^https:\/\//i.test(base)) throw new Error('PUBLIC_BOOKING_BASE_URL_MUST_BE_HTTPS')
  return `${base}/retomar/${encodeURIComponent(resumeToken)}`
}

export function buildWhatsAppRecoveryTemplatePayload(
  recipient: string,
  template: WhatsAppTemplateConfig,
  resumeUrl: string,
): Record<string, unknown> {
  return {
    messaging_product: 'whatsapp',
    to: normalizeWhatsAppRecipient(recipient),
    type: 'template',
    template: {
      name: template.provider_template_name,
      language: { code: template.language_code },
      components: [
        {
          type: 'body',
          parameters: [{ type: 'text', text: resumeUrl }],
        },
      ],
    },
  }
}
