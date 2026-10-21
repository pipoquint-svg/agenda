/**
 * WhatsApp da reserva para a cliente: confirmação, remarcação e cancelamento no
 * momento do evento, e mensagens com prazo (por exemplo a cobrança de saldo antes do
 * término), que chegam pelo agendamento com schedule_key e template_id.
 * Duas travas independentes, ambas precisam estar liberadas para enviar:
 *   1) WHATSAPP_CUSTOMER_DISPATCH_ENABLED=true no ambiente;
 *   2) um modelo de WhatsApp ATIVO para o evento e o serviço.
 * Fora isso, só envia modelo aprovado e sem alteração desde a aprovação, para a
 * operação BlackSheep (dona do número conectado), uma vez por reserva/versão/evento/prazo.
 */
import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import { timingSafeEqual } from '../_shared/timing-safe-equal.ts'
import { callDracmaGateway } from '../_shared/dracma-gateway.ts'
import { durationLabel } from '../_shared/duration-label.ts'
import { customerLinkSuffix, type CustomerLinkVariable } from '../_shared/customer-link.ts'
import { buildBalancePaymentUrl } from '../_shared/balance-payment-link.ts'
import {
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  templateVariableKeys,
} from '../_shared/notification-email.ts'
import { type WhatsAppSettings, whatsappTemplateParameters } from '../admin-notifications/whatsapp-template.ts'
import { maskPhone, testRecipient } from '../admin-notifications/test-send.ts'

const SCOPE = 'BLACKSHEEP'
const IMMEDIATE_EVENTS = ['APPOINTMENT_APPROVED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_CANCELLED']
// Só por agendamento (prazo antes/depois do início ou do término).
const SCHEDULED_EVENTS = [...IMMEDIATE_EVENTS, 'RENTAL_BALANCE_DUE']

function requireInternal(req: Request) {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  if (!expected || !timingSafeEqual(req.headers.get('x-internal-secret'), expected)) throw new Error('INTERNAL_AUTH_REQUIRED')
}

const skip = (reason: string, extra: Record<string, unknown> = {}) => jsonResponse({ skipped: true, reason, ...extra })

function numeric(value: unknown) {
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}
function money(value: unknown) {
  return numeric(value).toLocaleString('pt-BR', { style: 'currency', currency: 'BRL' })
}
function dateTime(value: unknown) {
  if (!value) return ''
  const date = new Date(String(value))
  if (Number.isNaN(date.getTime())) return ''
  return date.toLocaleString('pt-BR', { timeZone: 'America/Sao_Paulo', dateStyle: 'short', timeStyle: 'short' })
}
const latest = (...values: (string | null | undefined)[]) =>
  values.filter((v): v is string => !!v).sort().at(-1) ?? null

async function send(body: Record<string, unknown>) {
  if ((Deno.env.get('WHATSAPP_CUSTOMER_DISPATCH_ENABLED') ?? '').trim().toLowerCase() !== 'true') {
    return skip('WHATSAPP_DISPATCH_DISABLED')
  }
  const client = adminClient()
  const appointmentId = String(body.appointment_id ?? '').trim()
  const entityVersion = Number(body.entity_version)
  const eventKey = String(body.event_key ?? 'APPOINTMENT_APPROVED').trim().toUpperCase()
  if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
  if (!Number.isInteger(entityVersion) || entityVersion < 1) throw new Error('ENTITY_VERSION_REQUIRED')
  const scheduleKey = String(body.schedule_key ?? '').trim()
  if (!(scheduleKey ? SCHEDULED_EVENTS : IMMEDIATE_EVENTS).includes(eventKey)) {
    return skip('WHATSAPP_EVENT_NOT_SUPPORTED')
  }

  const { data: appointment, error: appointmentError } = await client.from('appointments')
    .select('id,public_code,service_id,primary_customer_id,status,financial_status,start_at,end_at,duration_minutes,commercial_value,version,service_name_snapshot,service_description_snapshot')
    .eq('id', appointmentId).maybeSingle()
  if (appointmentError) throw new Error('APPOINTMENT_LOOKUP_FAILED')
  if (!appointment) throw new Error('APPOINTMENT_NOT_FOUND')
  const currentVersion = Number(appointment.version)
  if (entityVersion < currentVersion) return jsonResponse({ stale: true, current_version: currentVersion })
  if (entityVersion > currentVersion) throw new Error('ENTITY_VERSION_AHEAD_OF_APPOINTMENT')
  const expectedStatus = eventKey === 'APPOINTMENT_CANCELLED' ? 'CANCELLED' : 'CONFIRMED'
  if (appointment.status !== expectedStatus) return skip('APPOINTMENT_STATUS_CHANGED')
  if (!appointment.primary_customer_id) return skip('WHATSAPP_CUSTOMER_MISSING')

  const [{ data: service }, { data: customer }] = await Promise.all([
    client.from('services').select('id,name,full_description,operation_scope').eq('id', appointment.service_id).maybeSingle(),
    client.from('customers').select('id,name,email,phone').eq('id', appointment.primary_customer_id).maybeSingle(),
  ])
  if (!service || !customer) throw new Error('APPOINTMENT_CONTEXT_LOOKUP_FAILED')
  if (String(service.operation_scope ?? '').toUpperCase() !== SCOPE) return skip('WHATSAPP_SCOPE_NOT_CONNECTED')
  let phone: string
  try {
    phone = testRecipient(customer.phone)
  } catch {
    return skip('WHATSAPP_RECIPIENT_MISSING_OR_INVALID')
  }

  // Trava 2: só um modelo de WhatsApp ATIVO entra aqui.
  let templateId: string
  if (scheduleKey) {
    // Agendado: o modelo é o do agendamento, e o prazo ainda precisa ser o mesmo.
    const scheduledId = String(body.template_id ?? '').trim()
    const { data: scheduled, error: scheduledError } = await client.from('notification_template_configs')
      .select('id,event_key,channel,audience,operation_scope,is_active,schedule_mode,schedule_offset_minutes')
      .eq('id', scheduledId).maybeSingle()
    if (scheduledError) throw new Error('NOTIFICATION_TEMPLATE_LOOKUP_FAILED')
    if (!scheduled || scheduled.channel !== 'WHATSAPP' || scheduled.audience !== 'CUSTOMER' || scheduled.event_key !== eventKey) {
      return skip('WHATSAPP_TEMPLATE_NOT_FOUND')
    }
    if (scheduled.is_active !== true) return skip('WHATSAPP_TEMPLATE_NOT_ACTIVE')
    if (scheduled.operation_scope && scheduled.operation_scope !== SCOPE) return skip('WHATSAPP_SCOPE_NOT_CONNECTED')
    const currentKey = `${scheduled.id}:${entityVersion}:${scheduled.schedule_mode}:${scheduled.schedule_offset_minutes}`
    if (scheduleKey !== currentKey) return skip('WHATSAPP_SCHEDULE_CHANGED')
    const { data: targets, error: targetsError } = await client.from('notification_template_services')
      .select('service_id').eq('template_id', scheduledId)
    if (targetsError) throw new Error('NOTIFICATION_TEMPLATE_SERVICES_LOOKUP_FAILED')
    if ((targets ?? []).length > 0 && !(targets ?? []).some((row: { service_id: string }) => row.service_id === appointment.service_id)) {
      return skip('WHATSAPP_SERVICE_NOT_TARGETED')
    }
    templateId = scheduledId
  } else {
    const { data: rows, error: resolveError } = await client.rpc('resolve_notification_template_v2', {
      p_event_key: eventKey,
      p_channel: 'WHATSAPP',
      p_audience: 'CUSTOMER',
      p_service_id: appointment.service_id,
    })
    if (resolveError) throw new Error('NOTIFICATION_TEMPLATE_RESOLUTION_FAILED')
    const template = (Array.isArray(rows) ? rows[0] : null) as Record<string, unknown> | null
    if (!template?.id) return skip('WHATSAPP_TEMPLATE_NOT_ACTIVE')
    templateId = String(template.id)
  }

  // Cobrança de saldo: só com cobrança pendente, dentro do prazo e com saldo em aberto.
  let balanceCollection: { id: string } | null = null
  if (eventKey === 'RENTAL_BALANCE_DUE') {
    const { data: collection, error: collectionError } = await client.from('appointment_balance_collections')
      .select('id,status,expires_at').eq('appointment_id', appointmentId).eq('status', 'PENDING')
      .order('sequence', { ascending: false }).limit(1).maybeSingle()
    if (collectionError) throw new Error('BALANCE_COLLECTION_LOOKUP_FAILED')
    if (!collection || new Date(String(collection.expires_at)).getTime() <= Date.now()) return skip('BALANCE_COLLECTION_NOT_PENDING')
    const { data: summary, error: summaryError } = await client.rpc('get_appointment_financial_summary', { p_appointment_id: appointmentId })
    if (summaryError) throw new Error('FINANCIAL_SUMMARY_FAILED')
    if (numeric(summary?.contract_balance) <= 0.005) return skip('BALANCE_ALREADY_PAID')
    balanceCollection = { id: String(collection.id) }
  }

  const { data: integration } = await client.from('whatsapp_tenant_integrations')
    .select('tenant_id,dispatch_admin_id,tenants(id,name)').eq('status', 'CONNECTED')
    .not('dispatch_admin_id', 'is', null).order('updated_at', { ascending: false }).limit(1).maybeSingle()
  const tenantRow = (integration as { tenants?: { id: string; name: string } } | null)?.tenants
  if (!integration || !tenantRow) return skip('WHATSAPP_NOT_CONNECTED')
  const tenant = { id: String(tenantRow.id), name: String(tenantRow.name) }

  const [{ data: submission }, { data: settingsRow }, { data: fullTemplate }] = await Promise.all([
    client.from('whatsapp_template_submissions').select('status,provider_template_name,submitted_at')
      .eq('tenant_id', tenant.id).eq('notification_template_id', templateId).maybeSingle(),
    client.from('notification_whatsapp_settings')
      .select('category,header_text,footer_text,ttl_seconds,variable_examples,button_text,button_variable,updated_at')
      .eq('template_id', templateId).maybeSingle(),
    client.from('notification_template_configs').select('body_template,variable_schema,updated_at').eq('id', templateId).maybeSingle(),
  ])
  if (submission?.status !== 'APPROVED' || !submission.provider_template_name) return skip('WHATSAPP_TEMPLATE_NOT_APPROVED')
  // Só o texto que a Meta aprovou: editado depois do envio, espera nova aprovação.
  const edited = latest(String(fullTemplate?.updated_at ?? ''), settingsRow?.updated_at ? String(settingsRow.updated_at) : null)
  if (edited && submission.submitted_at && edited > String(submission.submitted_at)) return skip('WHATSAPP_TEMPLATE_CHANGED_SINCE_APPROVAL')

  const idempotencyKey = `notification:${templateId}:${appointmentId}:v${entityVersion}:${eventKey}:${scheduleKey || 'IMMEDIATE'}:WHATSAPP:CUSTOMER`
  const delivery = await beginNotificationDelivery(client, {
    templateId,
    eventKey,
    audience: 'CUSTOMER',
    appointmentId,
    customerId: String(customer.id),
    recipient: phone,
    recipientMasked: maskPhone(phone),
    channel: 'WHATSAPP',
    idempotencyKey,
    payloadSnapshot: { template_id: templateId, appointment_id: appointmentId, entity_version: entityVersion, operation_scope: SCOPE, schedule_key: scheduleKey || null },
  })
  if (delivery.alreadySent) return skip('NOTIFICATION_ALREADY_SENT')

  try {
    const catalog = [...templateVariableKeys(fullTemplate?.variable_schema)]
    const settings = settingsRow as unknown as WhatsAppSettings | null
    const [{ data: financial }, { data: extras }, { data: discount }] = await Promise.all([
      client.rpc('get_appointment_financial_summary', { p_appointment_id: appointmentId }),
      client.from('appointment_extras').select('name_snapshot,quantity').eq('appointment_id', appointmentId),
      client.from('appointment_discounts').select('code_snapshot,calculated_discount_amount').eq('appointment_id', appointmentId).maybeSingle(),
    ])
    let manageUrl = ''
    let tokenId: string | null = null
    const usesManage = catalog.includes('appointment.manage_url') || settings?.button_variable === 'appointment.manage_url'
    if (usesManage && appointment.status === 'CONFIRMED') {
      const { data: token, error: tokenError } = await client.rpc('service_issue_appointment_action_token', {
        p_appointment_id: appointmentId,
        p_scope: 'RESCHEDULE',
        p_channel: 'WHATSAPP',
        p_destination_masked: maskPhone(phone),
        p_request_id: `whatsapp:${appointmentId}:v${entityVersion}`,
      })
      if (tokenError || !token?.access_token || !token?.token_id) throw new Error('APPOINTMENT_MANAGE_TOKEN_ISSUE_FAILED')
      tokenId = String(token.token_id)
      manageUrl = `https://www.blacksheepestudiocriativo.com.br/reserva/gerenciar?token=${encodeURIComponent(String(token.access_token))}&scope=RESCHEDULE`
    }
    const balance: Record<string, string> = {}
    if (balanceCollection) {
      const { data: tokenEnvelope, error: tokenError } = await client.rpc('service_issue_balance_collection_payment_token', {
        p_collection_id: balanceCollection.id,
      })
      const accessToken = typeof tokenEnvelope?.access_token === 'string' ? tokenEnvelope.access_token : ''
      if (tokenError || !/^[0-9a-f]{64}$/i.test(accessToken)) throw new Error('BALANCE_PAYMENT_TOKEN_ISSUE_FAILED')
      const baseUrl = Deno.env.get('PUBLIC_BOOKING_BASE_URL')?.trim().replace(/\/$/, '') ?? ''
      balance['balance.amount'] = money(tokenEnvelope.amount)
      balance['balance.expires_at'] = dateTime(tokenEnvelope.expires_at)
      balance['balance.payment_url'] = buildBalancePaymentUrl(baseUrl, accessToken)
    }
    const values: Record<string, string> = {
      ...balance,
      'appointment.public_code': String(appointment.public_code ?? ''),
      'appointment.start_at': dateTime(appointment.start_at),
      'appointment.end_at': dateTime(appointment.end_at),
      'appointment.duration': durationLabel(appointment.duration_minutes),
      'appointment.manage_url': manageUrl,
      'appointment.previous_start_at': body.previous_start_at ? dateTime(body.previous_start_at) : '',
      'customer.name': String(customer.name ?? ''),
      'customer.email': String(customer.email ?? ''),
      'customer.phone': String(customer.phone ?? ''),
      'service.name': String(appointment.service_name_snapshot ?? service.name ?? ''),
      'service.description': String(appointment.service_description_snapshot ?? service.full_description ?? ''),
      'payment.total': money(appointment.commercial_value),
      'payment.paid': money(financial?.contract_settled),
      'payment.balance': money(financial?.contract_balance),
      'payment.status': String(appointment.financial_status ?? ''),
      'extras.summary': (extras ?? []).map((item: Record<string, unknown>) => `${item.name_snapshot} × ${item.quantity}`).join(', '),
      'coupon.code': String(discount?.code_snapshot ?? ''),
      'coupon.discount': money(discount?.calculated_discount_amount ?? 0),
    }
    const parameters = whatsappTemplateParameters({
      body: String(fullTemplate?.body_template ?? ''),
      catalog: [...catalog, ...(settings?.button_variable ? [settings.button_variable] : [])],
      settings,
      values,
      buttonSuffix: (variable, link) => customerLinkSuffix(variable as CustomerLinkVariable, link),
    })
    const sent = await callDracmaGateway({
      operation: 'SEND_TEMPLATE',
      tenant,
      adminId: String(integration.dispatch_admin_id),
      payload: { name: submission.provider_template_name, language: 'pt_BR', to: phone, ...parameters },
    })
    const messageId = typeof sent.message_id === 'string' ? sent.message_id : null
    await markNotificationSent(client, delivery.id, messageId)
    if (tokenId) {
      await client.rpc('service_record_appointment_token_delivery', {
        p_token_id: tokenId,
        p_channel: 'WHATSAPP',
        p_destination_masked: maskPhone(phone),
        p_request_id: `whatsapp:${appointmentId}:v${entityVersion}`,
        p_provider_message_id: messageId,
      })
    }
    return jsonResponse({ skipped: false, event_key: eventKey, recipient_masked: maskPhone(phone), template_id: templateId })
  } catch (error) {
    await markNotificationFailed(client, delivery.id, error)
    throw error
  }
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)
  try {
    requireInternal(req)
    return await send(await req.json() as Record<string, unknown>)
  } catch (error) {
    const code = error instanceof Error ? error.message : 'WHATSAPP_SEND_FAILED'
    console.error('WHATSAPP_SEND_FAILED', code)
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 500)
  }
})
