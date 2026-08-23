import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import {
  buildConfirmationEmail,
  isRecipientAllowed,
  isScopeEnabled,
  maskEmail,
  normalizedEmail,
} from '../_shared/transactional-email.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

function isEnabled(): boolean {
  return (Deno.env.get('TRANSACTIONAL_EMAIL_ENABLED') ?? '').trim().toLowerCase() === 'true'
}

function allowRealRecipients(): boolean {
  return (Deno.env.get('ALLOW_REAL_EMAIL_RECIPIENTS') ?? '').trim().toLowerCase() === 'true'
}

function numeric(value: unknown): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function senderForScope(scope: string): { brandName: string; from: string; replyTo: string | null } | null {
  if (scope === 'BLACKSHEEP') {
    const from = Deno.env.get('EMAIL_FROM_BLACKSHEEP')?.trim() ?? ''
    if (!from) return null
    return {
      brandName: 'BlackSheep Estúdio Criativo',
      from,
      replyTo: Deno.env.get('EMAIL_REPLY_TO_BLACKSHEEP')?.trim() || null,
    }
  }

  if (scope === 'SABRINA') {
    const from = Deno.env.get('EMAIL_FROM_SABRINA')?.trim() ?? ''
    if (!from) return null
    return {
      brandName: 'Sabrina Pierri',
      from,
      replyTo: Deno.env.get('EMAIL_REPLY_TO_SABRINA')?.trim() || null,
    }
  }

  return null
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    requireInternal(req)
    const body = await req.json()
    const appointmentId = String(body.appointment_id ?? '').trim()
    const entityVersion = Number(body.entity_version)
    const reason = String(body.reason ?? 'CONFIRMED').trim().toUpperCase()

    if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
    if (!Number.isInteger(entityVersion) || entityVersion < 1) throw new Error('ENTITY_VERSION_REQUIRED')

    if (!isEnabled()) {
      return jsonResponse({ stale: false, skipped: true, reason: 'TRANSACTIONAL_EMAIL_DISABLED' })
    }

    const client = adminClient()
    const { data: appointment, error: appointmentError } = await client
      .from('appointments')
      .select('id, public_code, service_id, primary_customer_id, status, start_at, duration_minutes, commercial_value, version, service_name_snapshot')
      .eq('id', appointmentId)
      .maybeSingle()

    if (appointmentError) throw new Error(`APPOINTMENT_LOOKUP_FAILED:${appointmentError.message}`)
    if (!appointment) throw new Error('APPOINTMENT_NOT_FOUND')

    const currentVersion = Number(appointment.version)
    if (entityVersion < currentVersion) {
      return jsonResponse({ stale: true, current_version: currentVersion, appointment_id: appointmentId })
    }
    if (entityVersion > currentVersion) throw new Error('ENTITY_VERSION_AHEAD_OF_APPOINTMENT')

    if (appointment.status !== 'CONFIRMED') {
      return jsonResponse({ stale: false, skipped: true, reason: 'APPOINTMENT_NOT_CONFIRMED' })
    }

    const { data: service, error: serviceError } = await client
      .from('services')
      .select('id, name, operation_scope')
      .eq('id', appointment.service_id)
      .maybeSingle()
    if (serviceError || !service) throw new Error('SERVICE_LOOKUP_FAILED')

    const scope = String(service.operation_scope ?? '').trim().toUpperCase()
    if (!isScopeEnabled(scope, Deno.env.get('TRANSACTIONAL_EMAIL_SCOPES'))) {
      return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_SCOPE_DISABLED', operation_scope: scope })
    }

    const sender = senderForScope(scope)
    if (!sender) {
      return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_SCOPE_SENDER_NOT_CONFIGURED', operation_scope: scope })
    }

    if (!appointment.primary_customer_id) {
      return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_CUSTOMER_MISSING' })
    }

    const { data: customer, error: customerError } = await client
      .from('customers')
      .select('id, name, email')
      .eq('id', appointment.primary_customer_id)
      .maybeSingle()
    if (customerError || !customer) throw new Error('CUSTOMER_LOOKUP_FAILED')

    const recipient = normalizedEmail(customer.email)
    if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) {
      return jsonResponse({ stale: false, skipped: true, reason: 'EMAIL_RECIPIENT_MISSING_OR_INVALID' })
    }

    if (!isRecipientAllowed(
      recipient,
      allowRealRecipients(),
      Deno.env.get('EMAIL_TEST_RECIPIENT_ALLOWLIST'),
    )) {
      return jsonResponse({
        stale: false,
        skipped: true,
        reason: 'EMAIL_RECIPIENT_NOT_ALLOWLISTED',
        recipient_masked: maskEmail(recipient),
      })
    }

    const { data: financial, error: financialError } = await client.rpc('get_appointment_financial_summary', {
      p_appointment_id: appointmentId,
    })
    if (financialError) throw new Error(`FINANCIAL_SUMMARY_FAILED:${financialError.message}`)

    const message = buildConfirmationEmail({
      brandName: sender.brandName,
      customerName: String(customer.name ?? 'Cliente'),
      serviceName: String(appointment.service_name_snapshot ?? service.name ?? 'Reserva'),
      startAt: String(appointment.start_at),
      durationMinutes: numeric(appointment.duration_minutes),
      publicCode: String(appointment.public_code ?? ''),
      totalValue: numeric(appointment.commercial_value),
      paidValue: numeric(financial?.contract_settled),
      balanceValue: numeric(financial?.contract_balance),
    })

    const apiKey = Deno.env.get('RESEND_API_KEY')?.trim() ?? ''
    if (!apiKey) throw new Error('MISSING_ENV:RESEND_API_KEY')

    const providerPayload: Record<string, unknown> = {
      from: sender.from,
      to: [recipient],
      subject: message.subject,
      text: message.text,
      html: message.html,
    }
    if (sender.replyTo) providerPayload.reply_to = sender.replyTo

    const idempotencyKey = `appointment-confirmed-email:${appointmentId}:v${entityVersion}`
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${apiKey}`,
        'content-type': 'application/json',
        'idempotency-key': idempotencyKey,
      },
      body: JSON.stringify(providerPayload),
    })

    const responseText = await response.text()
    if (!response.ok) {
      throw new Error(`EMAIL_PROVIDER_ERROR:${response.status}:${responseText.slice(0, 500)}`)
    }

    let providerMessageId: string | null = null
    if (responseText) {
      try {
        const parsed = JSON.parse(responseText)
        if (typeof parsed?.id === 'string') providerMessageId = parsed.id
      } catch {
        throw new Error('EMAIL_PROVIDER_INVALID_RESPONSE')
      }
    }

    return jsonResponse({
      stale: false,
      skipped: false,
      appointment_id: appointmentId,
      entity_version: entityVersion,
      reason,
      operation_scope: scope,
      recipient_masked: maskEmail(recipient),
      provider: 'RESEND',
      provider_message_id: providerMessageId,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'TRANSACTIONAL_EMAIL_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
