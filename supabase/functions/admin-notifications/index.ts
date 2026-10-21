import { adminClient, hasAdminPermission, requireAdmin } from '../_shared/supabase.ts'
import { notificationSenderForScope, sendEmailWithProvider, type EmailProviderPayload } from '../_shared/email-provider.ts'
import { maskEmail, normalizedEmail } from '../_shared/transactional-email.ts'
import {
  assertSafeCustomHtml,
  beginNotificationDelivery,
  markNotificationFailed,
  markNotificationSent,
  renderNotificationMessage,
  templateVariableKeys,
  type NotificationTemplate,
} from '../_shared/notification-email.ts'
import { type AgendaTenant, callDracmaGateway, tenantForAdmin } from '../_shared/dracma-gateway.ts'
import { BOOKING_URL, customerLinkButton, customerLinkSuffix, type CustomerLinkVariable } from '../_shared/customer-link.ts'
import { couponDateLabel, couponDaysLeft, couponDiscountLabel } from '../whatsapp-send/rewards.ts'
import {
  isAgendaTemplate,
  type MetaTemplateRef,
  rotateTemplateVersions,
  type TemplateVersions,
  type VersionDeps,
} from './template-versions.ts'
import { maskPhone, testParameters, testRecipient } from './test-send.ts'
import { greetingName, winbackKeys } from './winback.ts'
import {
  type SubmissionRow,
  submissionStatus,
  submissionView,
  type WhatsAppSettings,
  whatsappSettings,
  whatsappTemplateDefinition,
  whatsappTemplateParameters,
} from './whatsapp-template.ts'

const corsHeaders = {
  'access-control-allow-origin': '*',
  'access-control-allow-headers': 'content-type, authorization, apikey, x-client-info',
  'access-control-allow-methods': 'GET, POST, PUT, OPTIONS',
  'access-control-max-age': '7200',
}

const events = [
  'APPOINTMENT_APPROVED', 'APPOINTMENT_PENDING', 'APPOINTMENT_REJECTED', 'APPOINTMENT_CANCELLED',
  'APPOINTMENT_CHANGED', 'APPOINTMENT_RESCHEDULED', 'APPOINTMENT_REMINDER', 'WAITLIST_AVAILABLE', 'WAITLIST_SIGNUP_TEAM', 'BIRTHDAY',
  'RENTAL_BALANCE_DUE', 'ADMIN_USER_INVITE', 'PRE_RESERVATION_CREATED', 'REFUND_FAILED', 'REFUND_COMPLETED', 'PAYMENT_PENDING_CREATED', 'MANUAL',
]
const channels = ['EMAIL', 'GOOGLE_CALENDAR', 'WHATSAPP']
const audiences = ['CUSTOMER', 'EMPLOYEE']
const variables = [
  'appointment.public_code', 'appointment.start_at', 'appointment.end_at', 'appointment.duration',
  'appointment.manage_url', 'appointment.previous_start_at',
  'customer.name', 'customer.email', 'customer.phone', 'employee.name', 'auth.invite_url', 'service.name', 'service.description',
  'waitlist.name', 'waitlist.email', 'waitlist.whatsapp', 'waitlist.created_at',
  'operation.name', 'operation.email', 'operation.phone', 'operation.address', 'operation.site_url',
  'payment.total', 'payment.paid', 'payment.balance', 'payment.status', 'payment.resume_url', 'payment.expires_at', 'extras.summary',
  'coupon.code', 'coupon.discount', 'coupon.expires_at',
  'balance.amount', 'balance.expires_at', 'balance.payment_url',
  'pre_reservation.expires_at', 'pre_reservation.payment_url',
  'refund.amount', 'refund.error_code',
]
// Rewards messages (one set per campaign) use their own catalog. They are drafts
// only: nothing enqueues these events while Rewards delivery (S6) is frozen.
const rewardsEvents = [
  'REWARDS_WINBACK', 'REWARDS_COUPON_ISSUED', 'REWARDS_COUPON_EXPIRING', 'REWARDS_REFERRAL_CODE', 'REWARDS_REFERRAL_REWARD',
]
const rewardsVariables = [
  'customer.name', 'customer.last_rental_at', 'campaign.name',
  'coupon.code', 'coupon.discount', 'coupon.expires_at', 'coupon.days_left',
  'referral.code', 'referral.referred_name',
  'reward.hours', 'reward.expires_at', 'reward.balance',
  'operation.name', 'operation.site_url', 'booking.url',
]
const isRewardsEvent = (eventKey: string) => rewardsEvents.includes(eventKey)
const catalogFor = (eventKey: string) => isRewardsEvent(eventKey) ? rewardsVariables : variables

const financialVariables = new Set([
  'payment.total', 'payment.paid', 'payment.balance', 'payment.status', 'coupon.discount', 'balance.amount', 'refund.amount',
])

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'content-type': 'application/json; charset=utf-8' } })
}
function text(value: unknown, nullable = false): string | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  if (typeof value !== 'string' || !value.trim()) throw new Error('NOTIFICATION_TEXT_INVALID')
  return value.trim()
}
function uuid(value: unknown, nullable = false): string | null {
  if (nullable && (value === null || value === undefined || value === '')) return null
  const next = text(value) as string
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(next)) throw new Error('UUID_INVALID')
  return next
}
function uuidArray(value: unknown): string[] {
  if (!Array.isArray(value)) throw new Error('NOTIFICATION_SERVICES_INVALID')
  return value.map((item) => uuid(item) as string)
}
function integer(value: unknown): number | null {
  if (value === null || value === undefined || value === '') return null
  const next = Number(value)
  if (!Number.isInteger(next) || next < 0) throw new Error('NOTIFICATION_REMINDER_OFFSET_INVALID')
  return next
}
function positiveInteger(value: string | null, fallback: number): number {
  const next = Number(value ?? fallback)
  return Number.isInteger(next) && next > 0 ? next : fallback
}
function records(value: unknown): Record<string, unknown>[] {
  return Array.isArray(value) ? value as Record<string, unknown>[] : []
}

function testValues(recipient: string, brandName: string): Record<string, string> {
  return {
    'appointment.public_code': 'TESTE-1234',
    'appointment.start_at': '30/08/2026 14:00',
    'appointment.end_at': '30/08/2026 15:00',
    'appointment.duration': '1h',
    'appointment.previous_start_at': '28/08/2026 10:00',
    'appointment.manage_url': 'https://www.blacksheepestudiocriativo.com.br/reserva/gerenciar?token=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa&scope=RESCHEDULE',
    'customer.name': 'Teste BlackSheep',
    'customer.email': recipient,
    'customer.phone': '(48) 99999-0000',
    'employee.name': 'Equipe BlackSheep',
    'auth.invite_url': 'https://www.blacksheepestudiocriativo.com.br/gestao/primeiro-acesso',
    'service.name': 'Serviço de teste',
    'service.description': 'Descrição de exemplo para conferir a apresentação do e-mail.',
    'waitlist.name': 'Cliente da lista de espera',
    'waitlist.email': 'cliente.lista@example.com',
    'waitlist.whatsapp': '(48) 99999-0000',
    'waitlist.created_at': '31/08/2026 14:30',
    'operation.name': brandName,
    'operation.email': recipient,
    'operation.phone': '(48) 0000-0000',
    'operation.address': 'Palhoça/SC',
    'operation.site_url': 'https://www.blacksheepestudiocriativo.com.br',
    'payment.total': 'R$ 1.000,00',
    'payment.paid': 'R$ 500,00',
    'payment.balance': 'R$ 500,00',
    'payment.status': 'PAGO PARCIALMENTE',
    'payment.resume_url': 'https://www.blacksheepestudiocriativo.com.br/reserva/pagamento?token=teste',
    'payment.expires_at': '30/08/2026 16:00',
    'extras.summary': 'Adicional de teste × 1',
    'coupon.code': 'TESTE50',
    'coupon.discount': 'R$ 500,00',
    'coupon.expires_at': '30/09/2026',
    'balance.amount': 'R$ 500,00',
    'balance.expires_at': '30/08/2026 16:00',
    'balance.payment_url': 'https://www.blacksheepestudiocriativo.com.br/reserva/saldo?collection=teste',
    'pre_reservation.expires_at': '30/08/2026 16:00',
    'pre_reservation.payment_url': 'https://www.blacksheepestudiocriativo.com.br/reserva/pagamento?pre_reservation=teste',
    'refund.amount': 'R$ 500,00',
    'refund.error_code': 'REFUND_TEST',
    'customer.last_rental_at': '20/07/2026',
    'campaign.name': 'Volte ao estúdio',
    'coupon.days_left': '5',
    'booking.url': 'https://www.blacksheepestudiocriativo.com.br/agenda-e-valores',
    'referral.code': 'INDICA-TESTE',
    'referral.referred_name': 'Fotógrafa Indicada',
    'reward.hours': '1 hora',
    'reward.expires_at': '20/04/2027',
    'reward.balance': '2 horas',
  }
}

const submissionColumns = 'notification_template_id,status,provider_error_code,provider_error_message,submitted_at,approved_at,updated_at'

async function whatsappContext(authUserId: string) {
  const tenant = await tenantForAdmin(authUserId)
  if (!tenant) throw new Error('WHATSAPP_TENANT_REQUIRED')
  const { data, error } = await adminClient().from('whatsapp_tenant_integrations')
    .select('id').eq('tenant_id', tenant.id).eq('status', 'CONNECTED')
    .order('updated_at', { ascending: false }).limit(1).maybeSingle()
  if (error) throw new Error('WHATSAPP_INTEGRATION_LOOKUP_FAILED')
  if (!data?.id) throw new Error('WHATSAPP_NOT_CONNECTED')
  return { tenant, integrationId: String(data.id) }
}

async function saveSubmission(row: Record<string, unknown>) {
  const { data, error } = await adminClient().from('whatsapp_template_submissions')
    .upsert({ ...row, updated_at: new Date().toISOString() }, { onConflict: 'tenant_id,notification_template_id' })
    .select(submissionColumns).single()
  if (error || !data) throw new Error('WHATSAPP_SUBMISSION_SAVE_FAILED')
  return data as SubmissionRow
}

async function updateSubmission(tenantId: string, templateId: string, fields: Record<string, unknown>) {
  const { data, error } = await adminClient().from('whatsapp_template_submissions')
    .update({ ...fields, updated_at: new Date().toISOString() })
    .eq('tenant_id', tenantId).eq('notification_template_id', templateId)
    .select(submissionColumns).single()
  if (error || !data) throw new Error('WHATSAPP_SUBMISSION_SAVE_FAILED')
  return data as SubmissionRow
}

/** Name of a template on Meta from its id (rows sent before names were stored). */
async function metaNameForId(tenant: AgendaTenant, adminId: string, id: string) {
  const list = await callDracmaGateway({ operation: 'LIST_TEMPLATES', tenant, adminId, payload: {} })
  const match = records(list.templates).find((item) => String(item.template_id) === id)
  return match ? String(match.name) : null
}

/** Status of a template on Meta, or null when Meta could not be asked. */
async function metaStatusOf(tenant: AgendaTenant, adminId: string, name: string) {
  try {
    const lookup = await callDracmaGateway({ operation: 'TEMPLATE_STATUS', tenant, adminId, payload: { names: [name] } })
    const status = records(lookup.templates)[0]?.status
    return typeof status === 'string' ? status : null
  } catch {
    return null
  }
}

/**
 * Deletes one of Agenda's own templates on Meta. A template already gone counts as
 * deleted; a failure returns false so the caller keeps it for a later retry.
 */
async function deleteMetaTemplate(tenant: AgendaTenant, adminId: string, ref: MetaTemplateRef) {
  if (!isAgendaTemplate(ref.name)) return false
  try {
    if ((await metaStatusOf(tenant, adminId, ref.name)) === 'NOT_FOUND') return true
    await callDracmaGateway({
      operation: 'DELETE_TEMPLATE',
      tenant,
      adminId,
      payload: ref.id ? { name: ref.name, template_id: ref.id } : { name: ref.name },
    })
    return true
  } catch (error) {
    console.error('admin-notifications', 'WHATSAPP_TEMPLATE_DELETE_FAILED', error instanceof Error ? error.message : 'unknown')
    return false
  }
}

function versionDeps(tenant: AgendaTenant, adminId: string): VersionDeps {
  return {
    statusOf: (name) => metaStatusOf(tenant, adminId, name),
    nameForId: (id) => metaNameForId(tenant, adminId, id),
    remove: (ref) => deleteMetaTemplate(tenant, adminId, ref),
  }
}

function variablesIn(body: string) {
  return [...body.matchAll(/\{\{\s*([^}]+?)\s*\}\}/g)].map((match) => match[1].trim())
}

type StoredWhatsAppSettings = WhatsAppSettings & { updated_at: string | null }

/** WhatsApp-only fields per template id. */
async function loadWhatsAppSettings(templateIds: string[] | null) {
  const settings = new Map<string, StoredWhatsAppSettings>()
  if (templateIds && !templateIds.length) return settings
  // null loads every row: the table holds one small row per WhatsApp draft.
  let query = adminClient().from('notification_whatsapp_settings')
    .select('template_id,category,header_text,footer_text,ttl_seconds,variable_examples,button_text,button_variable,updated_at')
  if (templateIds) query = query.in('template_id', templateIds)
  const { data, error } = await query
  if (error) throw new Error('WHATSAPP_SETTINGS_LOOKUP_FAILED')
  for (const row of records(data)) {
    settings.set(String(row.template_id), {
      category: row.category === 'MARKETING' ? 'MARKETING' : 'UTILITY',
      header_text: typeof row.header_text === 'string' ? row.header_text : null,
      footer_text: typeof row.footer_text === 'string' ? row.footer_text : null,
      ttl_seconds: typeof row.ttl_seconds === 'number' ? row.ttl_seconds : null,
      variable_examples: row.variable_examples && typeof row.variable_examples === 'object' && !Array.isArray(row.variable_examples)
        ? Object.fromEntries(Object.entries(row.variable_examples as Record<string, unknown>).filter((entry): entry is [string, string] => typeof entry[1] === 'string'))
        : {},
      button_text: typeof row.button_text === 'string' ? row.button_text : null,
      button_variable: typeof row.button_variable === 'string' ? row.button_variable : null,
      updated_at: row.updated_at ? String(row.updated_at) : null,
    })
  }
  return settings
}

/** A draft changes when either the template or its WhatsApp fields change. */
function latest(...values: (string | null | undefined)[]) {
  return values.filter((value): value is string => Boolean(value) && Number.isFinite(Date.parse(String(value))))
    .sort((left, right) => Date.parse(right) - Date.parse(left))[0] ?? null
}

async function templateDefinition(template: Record<string, unknown>, tenant: AgendaTenant, settings: WhatsAppSettings | null = null) {
  return await whatsappTemplateDefinition({
    settings,
    templateId: String(template.id),
    eventKey: String(template.event_key),
    body: String(template.body_template ?? ''),
    catalog: catalogFor(String(template.event_key)),
    examples: testValues('cliente@exemplo.com.br', tenant.name),
    buttonLink: (variable) => customerLinkButton(variable as CustomerLinkVariable),
  })
}

async function rewardsCampaign(authUserId: string, campaignId: string) {
  const tenant = await tenantForAdmin(authUserId)
  if (!tenant) throw new Error('WHATSAPP_TENANT_REQUIRED')
  const { data, error } = await adminClient().from('marketing_campaigns')
    .select('id,internal_name,public_name,state').eq('id', campaignId).eq('tenant_id', tenant.id).maybeSingle()
  if (error) throw new Error('REWARDS_CAMPAIGN_LOOKUP_FAILED')
  if (!data) throw new Error('REWARDS_CAMPAIGN_NOT_FOUND')
  return { tenant, campaign: data as Record<string, unknown> }
}

/** The campaign's three Rewards drafts (or null when not written yet), with WhatsApp fields and Meta status. */
async function rewardsTemplatesView(authUserId: string, campaignId: string, canViewFinance: boolean) {
  const { tenant, campaign } = await rewardsCampaign(authUserId, campaignId)
  const client = adminClient()
  const { data: links, error: linksError } = await client.from('marketing_campaign_message_templates')
    .select('event_key,template_id').eq('campaign_id', campaignId)
  if (linksError) throw new Error('REWARDS_TEMPLATES_LOOKUP_FAILED')
  const templateIds = records(links).map((row) => String(row.template_id))
  const { data: rows, error: rowsError } = templateIds.length
    ? await client.from('notification_template_configs')
      .select('id,event_key,channel,audience,operation_scope,title_template,body_template,is_active,variable_schema,updated_at,schedule_mode,schedule_offset_minutes')
      .in('id', templateIds)
    : { data: [], error: null }
  if (rowsError) throw new Error('REWARDS_TEMPLATES_LOOKUP_FAILED')
  const [{ data: targetRows, error: targetsError }, { data: serviceRows, error: servicesError }] = await Promise.all([
    templateIds.length
      ? client.from('notification_template_services').select('template_id,service_id').in('template_id', templateIds)
      : Promise.resolve({ data: [], error: null }),
    client.from('services').select('id,name').eq('operation_scope', 'BLACKSHEEP').eq('is_active', true).order('name'),
  ])
  if (targetsError || servicesError) throw new Error('REWARDS_TEMPLATES_LOOKUP_FAILED')
  const targets = new Map<string, string[]>()
  for (const row of records(targetRows)) targets.set(String(row.template_id), [...(targets.get(String(row.template_id)) ?? []), String(row.service_id)])
  const settings = await loadWhatsAppSettings(templateIds)
  const { data: submissionRows, error: submissionError } = templateIds.length
    ? await client.from('whatsapp_template_submissions').select(submissionColumns).eq('tenant_id', tenant.id).in('notification_template_id', templateIds)
    : { data: [], error: null }
  if (submissionError) throw new Error(submissionError.message)
  const byEvent = new Map(records(rows).map((row) => [String(row.event_key), row]))
  const submissions = new Map(((submissionRows ?? []) as SubmissionRow[]).map((row) => [row.notification_template_id, row]))
  const visibleVariables = canViewFinance ? rewardsVariables : rewardsVariables.filter((item) => !financialVariables.has(item))
  return {
    campaign: { id: campaign.id, name: campaign.public_name ?? campaign.internal_name, state: campaign.state },
    templates: rewardsEvents.map((eventKey) => {
      const row = byEvent.get(eventKey)
      if (!row) return { event_key: eventKey, template: null, submission: null }
      const whatsapp = settings.get(String(row.id)) ?? null
      const submission = submissions.get(String(row.id))
      return {
        event_key: eventKey,
        template: { ...row, whatsapp, service_ids: targets.get(String(row.id)) ?? [] },
        submission: submission ? submissionView(submission, latest(row.updated_at ? String(row.updated_at) : null, whatsapp?.updated_at)) : null,
      }
    }),
    services: records(serviceRows).map((service) => ({ id: service.id, name: service.name })),
    options: {
      events: rewardsEvents,
      variables: visibleVariables,
      whatsapp_examples: Object.fromEntries(Object.entries(testValues('cliente@exemplo.com.br', 'BlackSheep'))
        .filter(([key]) => visibleVariables.includes(key))),
    },
  }
}

/** A "Cupom Rewards liberado" message of a campaign of the admin's tenant. */
async function rewardsCouponTemplate(authUserId: string, templateId: string) {
  const client = adminClient()
  const { data: link, error: linkError } = await client.from('marketing_campaign_message_templates')
    .select('campaign_id,event_key').eq('template_id', templateId).maybeSingle()
  if (linkError) throw new Error('REWARDS_TEMPLATES_LOOKUP_FAILED')
  if (!link) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
  if (!['REWARDS_COUPON_ISSUED', 'REWARDS_REFERRAL_REWARD'].includes(String(link.event_key))) throw new Error('REWARDS_TRIGGER_NOT_SUPPORTED')
  const { tenant } = await rewardsCampaign(authUserId, String(link.campaign_id))
  const { data: template, error } = await client.from('notification_template_configs')
    .select('id,is_active,schedule_mode,updated_at').eq('id', templateId).maybeSingle()
  if (error) throw new Error('NOTIFICATION_TEMPLATE_LOOKUP_FAILED')
  if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
  return { tenantId: tenant.id, is_active: template.is_active === true, schedule_mode: template.schedule_mode, updated_at: String(template.updated_at ?? '') }
}

async function saveRewardsTemplate(admin: { adminId: string; authUserId: string }, record: Record<string, unknown>) {
  const campaignId = uuid(record.campaign_id) as string
  const eventKey = (text(record.event_key) as string).toUpperCase()
  if (!isRewardsEvent(eventKey)) throw new Error('NOTIFICATION_EVENT_INVALID')
  const { tenant } = await rewardsCampaign(admin.authUserId, campaignId)
  const body = typeof record.body_template === 'string' ? record.body_template : ''
  const requestedVariables = [...new Set(variablesIn(body))]
  if (requestedVariables.some((item) => !rewardsVariables.includes(item))) throw new Error('WHATSAPP_TEMPLATE_VARIABLE_INVALID')
  if (requestedVariables.some((item) => financialVariables.has(item)) && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) {
    throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')
  }
  // Validate WhatsApp fields before saving, so a bad field never leaves a half-saved draft.
  const whatsapp = whatsappSettings(record.whatsapp ?? { category: 'MARKETING' }, rewardsVariables)
  const client = adminClient()
  const { data, error } = await client.rpc('service_admin_upsert_rewards_message_template', {
    p_tenant_id: tenant.id,
    p_campaign_id: campaignId,
    p_event_key: eventKey,
    p_title_template: text(record.title_template),
    p_body_template: body,
    p_variable_schema: requestedVariables,
    p_actor_admin_id: admin.adminId,
  })
  if (error) throw new Error(error.message)
  const { error: settingsError } = await client.from('notification_whatsapp_settings').upsert({
    template_id: data,
    ...whatsapp,
    updated_by_admin_id: admin.adminId,
    updated_at: new Date().toISOString(),
  }, { onConflict: 'template_id' })
  if (settingsError) throw new Error('WHATSAPP_SETTINGS_SAVE_FAILED')
  return { id: data, campaign_id: campaignId, event_key: eventKey }
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders })
  if (!['GET', 'POST', 'PUT'].includes(req.method)) return json({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      if (!(await hasAdminPermission(admin.adminId, 'SERVICES_VIEW'))) throw new Error('ADMIN_PERMISSION_DENIED')
      const canViewFinance = await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE')
      const url = new URL(req.url)

      if (url.searchParams.get('view') === 'history') {
        const page = positiveInteger(url.searchParams.get('page'), 1)
        const limit = Math.min(positiveInteger(url.searchParams.get('limit'), 50), 100)
        const status = text(url.searchParams.get('status'), true)?.toUpperCase() ?? null
        const eventKey = text(url.searchParams.get('event_key'), true)?.toUpperCase() ?? null
        if (status !== null && !['PENDING', 'SENT', 'FAILED', 'SKIPPED'].includes(status)) throw new Error('NOTIFICATION_STATUS_INVALID')
        if (eventKey !== null && !events.includes(eventKey)) throw new Error('NOTIFICATION_EVENT_INVALID')
        const { data, error } = await client.rpc('service_admin_list_notification_delivery_logs', {
          p_channel: 'EMAIL',
          p_status: status,
          p_event_key: eventKey,
          p_limit: limit,
          p_offset: (page - 1) * limit,
        })
        if (error) throw new Error(error.message)
        const deliveries = data ?? []
        const total = Number(deliveries[0]?.total_count ?? 0)
        return json({
          deliveries: deliveries.map((item: Record<string, unknown>) => {
            const { total_count: _totalCount, ...safe } = item
            return safe
          }),
          pagination: { page, limit, total, total_pages: Math.ceil(total / limit) },
        })
      }

      if (url.searchParams.get('view') === 'rewards') {
        return json(await rewardsTemplatesView(admin.authUserId, uuid(url.searchParams.get('campaign_id')) as string, canViewFinance))
      }

      const templateId = url.searchParams.get('template_id')
      if (templateId) {
        const { data, error } = await client.rpc('service_admin_notification_template_versions', { p_template_id: uuid(templateId) })
        if (error) throw new Error(error.message)
        return json({ versions: data ?? [] })
      }
      // Everything that does not depend on another answer goes in one round trip.
      const [templates, services, categories, whatsappByTemplate, tenant] = await Promise.all([
        client.rpc('service_admin_list_notification_templates_v3'),
        // Só os 5 campos usados nos filtros; a função completa de configurações lia
        // campos, faixas, atalhos e políticas de cada serviço para depois descartar.
        client.from('services').select('id,name,operation_scope,category_id,is_active').order('name'),
        client.rpc('service_admin_list_categories'),
        loadWhatsAppSettings(null),
        tenantForAdmin(admin.authUserId).catch(() => null),
      ])
      if (templates.error) throw new Error(templates.error.message)
      if (services.error) throw new Error(services.error.message)
      if (categories.error) throw new Error(categories.error.message)
      const allTemplates = records(templates.data)
      // Rewards drafts are edited in their campaign's editor; the WhatsApp list only links to them.
      templates.data = allTemplates.filter((item) => !isRewardsEvent(String(item.event_key)))
      const rewardsRows = allTemplates.filter((item) => isRewardsEvent(String(item.event_key)) && item.channel === 'WHATSAPP')
      let rewardsTemplates: Record<string, unknown>[] = []
      if (tenant && rewardsRows.length) {
        const { data: links, error: linksError } = await client.from('marketing_campaign_message_templates')
          .select('template_id,event_key,campaign_id,marketing_campaigns(internal_name,state,tenant_id)')
          .in('template_id', rewardsRows.map((item) => String(item.id)))
        if (linksError) throw new Error('REWARDS_TEMPLATES_LOOKUP_FAILED')
        const rowsById = new Map(rewardsRows.map((item) => [String(item.id), item]))
        rewardsTemplates = records(links).flatMap((link) => {
          const campaign = link.marketing_campaigns as Record<string, unknown> | null
          const row = rowsById.get(String(link.template_id))
          if (!campaign || !row || campaign.tenant_id !== tenant.id || campaign.state === 'ARCHIVED') return []
          return [{
            template_id: link.template_id, event_key: link.event_key, campaign_id: link.campaign_id,
            campaign_name: campaign.internal_name, campaign_state: campaign.state,
            title_template: row.title_template, is_active: row.is_active === true,
          }]
        })
      }
      // WhatsApp approval status per template, for the admin's tenant only.
      let whatsappSubmissions: ReturnType<typeof submissionView>[] = []
      if (tenant) {
        const { data: rows, error: rowsError } = await client.from('whatsapp_template_submissions')
          .select(submissionColumns).eq('tenant_id', tenant.id)
        if (rowsError) throw new Error(rowsError.message)
        const updatedAt = new Map(allTemplates.map((item) => [String(item.id), latest(item.updated_at ? String(item.updated_at) : null, whatsappByTemplate.get(String(item.id))?.updated_at)]))
        whatsappSubmissions = ((rows ?? []) as SubmissionRow[]).map((row) => submissionView(row, updatedAt.get(row.notification_template_id) ?? null))
      }
      return json({
        whatsapp_submissions: whatsappSubmissions,
        rewards_templates: rewardsTemplates,
        templates: records(templates.data).map((item) => item.channel === 'WHATSAPP'
          ? { ...item, whatsapp: whatsappByTemplate.get(String(item.id)) ?? null }
          : item),
        services: records(services.data).map((service) => ({
          id: service.id, name: service.name, operation_scope: service.operation_scope, category_id: service.category_id, is_active: service.is_active,
        })),
        categories: records(categories.data).map((category) => ({
          id: category.id, name: category.name, operation_scope: category.operation_scope, is_active: category.is_active,
        })),
        options: {
          events,
          channels,
          audiences,
          variables: canViewFinance ? variables : variables.filter((item) => !financialVariables.has(item)),
          // Default samples the editor pre-fills for WhatsApp variables.
          whatsapp_examples: Object.fromEntries(Object.entries(testValues('cliente@exemplo.com.br', 'BlackSheep'))
            .filter(([key]) => canViewFinance || !financialVariables.has(key))),
        },
      })
    }

    if (!(await hasAdminPermission(admin.adminId, 'SERVICES_MANAGE'))) throw new Error('ADMIN_PERMISSION_DENIED')
    const body = await req.json()
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('NOTIFICATION_PAYLOAD_INVALID')
    const record = body as Record<string, unknown>

    const action = String(record.action ?? '').toUpperCase()
    if (req.method === 'POST' && action === 'SUBMIT_WHATSAPP') {
      const templateId = uuid(record.template_id) as string
      const { data: template, error: templateError } = await client
        .from('notification_template_configs')
        .select('id,event_key,channel,body_template,updated_at')
        .eq('id', templateId).maybeSingle()
      if (templateError || !template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      if (template.channel !== 'WHATSAPP') throw new Error('WHATSAPP_TEMPLATE_CHANNEL_INVALID')
      if (variablesIn(String(template.body_template ?? '')).some((item) => financialVariables.has(item)) && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) {
        throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')
      }
      const { tenant, integrationId } = await whatsappContext(admin.authUserId)
      // Quem envia modelos para a Meta passa a responder pelos envios automáticos
      // (autor no Dracma), se ninguém foi definido ainda.
      await client.from('whatsapp_tenant_integrations').update({ dispatch_admin_id: admin.adminId })
        .eq('id', integrationId).is('dispatch_admin_id', null)
      const settings = (await loadWhatsAppSettings([templateId])).get(templateId) ?? null
      const draftUpdatedAt = latest(String(template.updated_at ?? ''), settings?.updated_at)
      const definition = await templateDefinition(template, tenant, settings)
      const base = { tenant_id: tenant.id, integration_id: integrationId, notification_template_id: templateId }
      const { data: existingRow } = await client.from('whatsapp_template_submissions')
        .select('status,provider_template_id,provider_template_name,previous_template_name,previous_template_id')
        .eq('tenant_id', tenant.id).eq('notification_template_id', templateId).maybeSingle()
      const versions = (existingRow ?? null) as unknown as TemplateVersions | null
      try {
        // Re-sending unchanged text finds the template Meta already has.
        const lookup = await callDracmaGateway({ operation: 'TEMPLATE_STATUS', tenant, adminId: admin.adminId, payload: { names: [definition.name] } })
        const existing = records(lookup.templates)[0]
        const provider = existing && existing.status !== 'NOT_FOUND'
          ? existing
          : await callDracmaGateway({ operation: 'SUBMIT_TEMPLATE', tenant, adminId: admin.adminId, payload: definition })
        const mapped = submissionStatus(provider.status) ?? { status: 'FAILED' as const, errorCode: 'META_TEMPLATE_NOT_FOUND' }
        const now = new Date().toISOString()
        const providerId = typeof provider.template_id === 'string' && provider.template_id ? provider.template_id : null
        // The previous version leaves Meta now, or once this one is approved.
        const previous = await rotateTemplateVersions(versionDeps(tenant, admin.adminId), versions, {
          name: definition.name,
          id: providerId,
          approved: mapped.status === 'APPROVED',
        })
        const row = await saveSubmission({
          ...base,
          provider_template_id: providerId,
          provider_template_name: definition.name,
          previous_template_name: previous.name,
          previous_template_id: previous.id,
          status: mapped.status,
          provider_error_code: mapped.errorCode,
          provider_error_message: typeof provider.rejected_reason === 'string' ? provider.rejected_reason : null,
          submitted_at: now,
          approved_at: mapped.status === 'APPROVED' ? now : null,
        })
        return json({ submission: submissionView(row, draftUpdatedAt), category: definition.category })
      } catch (submitError) {
        const code = submitError instanceof Error && /^[A-Z][A-Z0-9_]{2,95}$/.test(submitError.message)
          ? submitError.message
          : 'WHATSAPP_SUBMISSION_FAILED'
        await saveSubmission({ ...base, status: 'FAILED', provider_error_code: code, provider_error_message: null }).catch(() => undefined)
        throw submitError
      }
    }

    if (req.method === 'POST' && action === 'SYNC_WHATSAPP') {
      const { tenant } = await whatsappContext(admin.authUserId)
      const { data: rows, error: rowsError } = await client.from('whatsapp_template_submissions')
        .select(`${submissionColumns},provider_template_id`).eq('tenant_id', tenant.id)
        .not('provider_template_id', 'is', null).limit(20)
      if (rowsError) throw new Error(rowsError.message)
      const submissions = (rows ?? []) as (SubmissionRow & { provider_template_id: string })[]
      const { data: templateRows, error: templateRowsError } = await client.from('notification_template_configs')
        .select('id,event_key,body_template,updated_at').in('id', submissions.map((row) => row.notification_template_id))
      if (templateRowsError) throw new Error(templateRowsError.message)
      const templatesById = new Map(records(templateRows).map((item) => [String(item.id), item]))
      const settingsById = await loadWhatsAppSettings([...templatesById.keys()])
      // Only unchanged drafts still match the name that was sent to Meta.
      const tracked: { row: SubmissionRow; name: string; updatedAt: string | null }[] = []
      for (const row of submissions) {
        const template = templatesById.get(row.notification_template_id)
        if (!template) continue
        const settings = settingsById.get(row.notification_template_id) ?? null
        const updatedAt = latest(String(template.updated_at ?? ''), settings?.updated_at)
        if (submissionView(row, updatedAt).changed_since_submission) continue
        tracked.push({ row, name: (await templateDefinition(template, tenant, settings)).name, updatedAt })
      }
      const result = tracked.length
        ? await callDracmaGateway({ operation: 'TEMPLATE_STATUS', tenant, adminId: admin.adminId, payload: { names: tracked.map((item) => item.name) } })
        : { templates: [] }
      const byName = new Map(records(result.templates).map((item) => [String(item.name), item]))
      const views = []
      for (const item of tracked) {
        const provider = byName.get(item.name)
        const mapped = submissionStatus(provider?.status) ?? { status: 'FAILED' as const, errorCode: 'META_TEMPLATE_NOT_FOUND' }
        const row = await updateSubmission(tenant.id, item.row.notification_template_id, {
          provider_template_name: item.name,
          status: mapped.status,
          provider_error_code: mapped.errorCode,
          provider_error_message: typeof provider?.rejected_reason === 'string' ? provider.rejected_reason : null,
          approved_at: mapped.status === 'APPROVED' ? (item.row.approved_at ?? new Date().toISOString()) : null,
        })
        views.push(submissionView(row, item.updatedAt))
      }
      // A kept version leaves Meta once its replacement is approved.
      const { data: kept } = await client.from('whatsapp_template_submissions')
        .select('notification_template_id,status,previous_template_name,previous_template_id')
        .eq('tenant_id', tenant.id).eq('status', 'APPROVED').not('previous_template_name', 'is', null)
      for (const row of records(kept)) {
        const ref = { name: String(row.previous_template_name), id: row.previous_template_id ? String(row.previous_template_id) : null }
        if (await deleteMetaTemplate(tenant, admin.adminId, ref)) {
          await updateSubmission(tenant.id, String(row.notification_template_id), { previous_template_name: null, previous_template_id: null })
        }
      }
      return json({ submissions: views })
    }

    if (req.method === 'POST' && (action === 'LIST_META_TEMPLATES' || action === 'DELETE_META_TEMPLATE')) {
      const { tenant } = await whatsappContext(admin.authUserId)
      const { data: subs, error: subsError } = await client.from('whatsapp_template_submissions')
        .select('notification_template_id,status,provider_template_name,previous_template_name,previous_template_id')
        .eq('tenant_id', tenant.id)
      if (subsError) throw new Error(subsError.message)
      const { data: drafts } = await client.from('notification_template_configs')
        .select('id,event_key').in('id', records(subs).map((row) => String(row.notification_template_id)))
      const eventById = new Map(records(drafts).map((item) => [String(item.id), String(item.event_key)]))
      // Which draft uses each name: the current version or the one kept until approval.
      const usage = new Map<string, { role: 'CURRENT' | 'PREVIOUS'; template_id: string; event_key: string | null }>()
      for (const row of records(subs)) {
        const templateId = String(row.notification_template_id)
        const event = eventById.get(templateId) ?? null
        if (row.provider_template_name) usage.set(String(row.provider_template_name), { role: 'CURRENT', template_id: templateId, event_key: event })
        if (row.previous_template_name) usage.set(String(row.previous_template_name), { role: 'PREVIOUS', template_id: templateId, event_key: event })
      }
      if (action === 'DELETE_META_TEMPLATE') {
        const name = String(record.name ?? '')
        if (!isAgendaTemplate(name)) throw new Error('WHATSAPP_TEMPLATE_NOT_AGENDA_OWNED')
        const used = usage.get(name)
        if (used?.role === 'CURRENT') throw new Error('WHATSAPP_TEMPLATE_IN_USE')
        const kept = records(subs).find((row) => row.previous_template_name === name)
        const ok = await deleteMetaTemplate(tenant, admin.adminId, {
          name,
          id: kept?.previous_template_id ? String(kept.previous_template_id) : null,
        })
        if (!ok) throw new Error('WHATSAPP_TEMPLATE_DELETE_FAILED')
        if (kept) {
          await updateSubmission(tenant.id, String(kept.notification_template_id), { previous_template_name: null, previous_template_id: null })
        }
        return json({ deleted: name })
      }
      const list = await callDracmaGateway({ operation: 'LIST_TEMPLATES', tenant, adminId: admin.adminId, payload: {} })
      return json({
        templates: records(list.templates).map((item) => ({
          name: String(item.name),
          status: String(item.status),
          category: String(item.category ?? ''),
          language: String(item.language ?? ''),
          rejected_reason: typeof item.rejected_reason === 'string' ? item.rejected_reason : null,
          // Created by Gestão (agenda_*) can be deleted here; others (Kommo) are read-only.
          managed: isAgendaTemplate(String(item.name)),
          usage: usage.get(String(item.name)) ?? null,
        })),
      })
    }

    if (req.method === 'POST' && action === 'TEST_WHATSAPP') {
      // Controlled test: one approved template, unchanged since approval, to one number,
      // with the samples Meta approved. Independent of activation (bookings stay locked).
      const templateId = uuid(record.template_id) as string
      const to = testRecipient(record.phone)
      const { data: template, error: templateError } = await client
        .from('notification_template_configs')
        .select('id,event_key,channel,body_template,updated_at')
        .eq('id', templateId).maybeSingle()
      if (templateError || !template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      if (template.channel !== 'WHATSAPP') throw new Error('WHATSAPP_TEMPLATE_CHANNEL_INVALID')
      const { tenant } = await whatsappContext(admin.authUserId)
      const { data: submission } = await client.from('whatsapp_template_submissions')
        .select('status,provider_template_name').eq('tenant_id', tenant.id).eq('notification_template_id', templateId).maybeSingle()
      if (submission?.status !== 'APPROVED') throw new Error('WHATSAPP_TEST_NOT_APPROVED')
      const settings = (await loadWhatsAppSettings([templateId])).get(templateId) ?? null
      const definition = await templateDefinition(template, tenant, settings)
      if (submission.provider_template_name && submission.provider_template_name !== definition.name) {
        throw new Error('WHATSAPP_TEST_TEMPLATE_CHANGED')
      }
      const sent = await callDracmaGateway({
        operation: 'SEND_TEST_TEMPLATE',
        tenant,
        adminId: admin.adminId,
        payload: { ...testParameters(definition), to },
      })
      console.log('admin-notifications', 'WHATSAPP_TEST_SENT', JSON.stringify({ template: definition.name, to: maskPhone(to), by: admin.adminId }))
      return json({ sent: sent.sent === true, to: maskPhone(to) })
    }

    // Win-back batch: every customer the campaign rule finds now (N days without renting, no
    // booking ahead, once per absence) gets the campaign coupon in the approved "Cliente sem
    // locar" message. dry_run only lists them. A customer without a valid WhatsApp gets nothing.
    if (req.method === 'POST' && action === 'DISPATCH_REWARDS_WINBACK') {
      const campaignId = uuid(record.campaign_id) as string
      const dryRun = record.dry_run !== false
      const { error: actorError } = await client.rpc('service_admin_assert_marketing_campaign_actor', { p_admin_id: admin.adminId })
      if (actorError) throw new Error(actorError.message)
      const { tenant, campaign } = await rewardsCampaign(admin.authUserId, campaignId)
      if (campaign.state !== 'ACTIVE') throw new Error('REWARDS_CAMPAIGN_NOT_ACTIVE')
      const { data: link, error: linkError } = await client.from('marketing_campaign_message_templates')
        .select('template_id').eq('campaign_id', campaignId).eq('event_key', 'REWARDS_WINBACK').maybeSingle()
      if (linkError) throw new Error('REWARDS_TEMPLATES_LOOKUP_FAILED')
      if (!link) throw new Error('REWARDS_WINBACK_MESSAGE_MISSING')
      const templateId = String(link.template_id)
      const { data: template, error: templateError } = await client.from('notification_template_configs')
        .select('id,event_key,channel,body_template,variable_schema,updated_at').eq('id', templateId).maybeSingle()
      if (templateError || !template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      const { data: submission } = await client.from('whatsapp_template_submissions')
        .select('status,provider_template_name,submitted_at').eq('tenant_id', tenant.id).eq('notification_template_id', templateId).maybeSingle()
      if (submission?.status !== 'APPROVED' || !submission.provider_template_name) throw new Error('WHATSAPP_TEMPLATE_NOT_APPROVED')
      const settings = (await loadWhatsAppSettings([templateId])).get(templateId) ?? null
      const edited = latest(String(template.updated_at ?? ''), settings?.updated_at)
      if (edited && submission.submitted_at && edited > String(submission.submitted_at)) throw new Error('WHATSAPP_TEMPLATE_CHANGED_SINCE_APPROVAL')

      const { data: candidates, error: candidatesError } = await client.rpc('service_list_marketing_campaign_candidates', {
        p_campaign_id: campaignId, p_limit: 1000,
      })
      if (candidatesError) throw new Error('REWARDS_CANDIDATES_FAILED')
      const list = (Array.isArray(candidates) ? candidates : []) as { customer_id: string; last_rental_at: string | null }[]
      const { data: customerRows, error: customersError } = list.length
        ? await client.from('customers').select('id,name,phone').in('id', list.map((item) => item.customer_id))
        : { data: [], error: null }
      if (customersError) throw new Error('REWARDS_CANDIDATES_FAILED')
      const customers = new Map(records(customerRows).map((row) => [String(row.id), row]))
      const recipients = list.flatMap((item) => {
        const customer = customers.get(item.customer_id)
        if (!customer) return []
        try {
          return [{ ...item, name: String(customer.name ?? ''), phone: testRecipient(customer.phone) }]
        } catch {
          return []
        }
      })
      if (dryRun) {
        return json({
          eligible: list.length,
          sendable: recipients.length,
          without_whatsapp: list.length - recipients.length,
          recipients: recipients.map((item) => ({ name: greetingName(item.name), phone: maskPhone(item.phone), last_rental_at: couponDateLabel(item.last_rental_at) })),
        })
      }

      const { data: integration } = await client.from('whatsapp_tenant_integrations')
        .select('dispatch_admin_id').eq('tenant_id', tenant.id).eq('status', 'CONNECTED')
        .not('dispatch_admin_id', 'is', null).order('updated_at', { ascending: false }).limit(1).maybeSingle()
      if (!integration) throw new Error('WHATSAPP_NOT_CONNECTED')
      const catalog = [...templateVariableKeys(template.variable_schema), ...(settings?.button_variable ? [settings.button_variable] : [])]
      const summary = { sent: 0, already_sent: 0, skipped: 0, failed: 0, failures: [] as string[] }
      for (const item of recipients) {
        const keys = winbackKeys(campaignId, templateId, item.customer_id, item.last_rental_at)
        const { data: previous } = await client.from('notification_delivery_logs').select('status,provider_message_id')
          .eq('idempotency_key', keys.delivery).maybeSingle()
        if (previous?.status === 'SENT' || previous?.provider_message_id) {
          summary.already_sent += 1
          continue
        }
        const { data: issued, error: issueError } = await client.rpc('service_issue_marketing_campaign_customer_coupon', {
          p_campaign_id: campaignId, p_customer_id: item.customer_id, p_idempotency_key: keys.issuance,
        })
        if (issueError) {
          summary.skipped += 1
          continue
        }
        const { data: coupon } = await client.from('coupons').select('code,discount_type,discount_value,valid_until').eq('id', issued.coupon_id).maybeSingle()
        if (!coupon) {
          summary.failed += 1
          continue
        }
        const delivery = await beginNotificationDelivery(client, {
          templateId,
          eventKey: 'REWARDS_WINBACK',
          audience: 'CUSTOMER',
          customerId: item.customer_id,
          recipient: item.phone,
          recipientMasked: maskPhone(item.phone),
          channel: 'WHATSAPP',
          idempotencyKey: keys.delivery,
          payloadSnapshot: { template_id: templateId, campaign_id: campaignId, coupon_id: issued.coupon_id, last_rental_at: item.last_rental_at },
        })
        if (delivery.alreadySent) {
          summary.already_sent += 1
          continue
        }
        try {
          const parameters = whatsappTemplateParameters({
            body: String(template.body_template ?? ''),
            catalog,
            settings,
            values: {
              'customer.name': greetingName(item.name),
              'customer.last_rental_at': couponDateLabel(item.last_rental_at),
              'campaign.name': String(campaign.public_name ?? campaign.internal_name ?? ''),
              'coupon.code': String(coupon.code),
              'coupon.discount': couponDiscountLabel(coupon.discount_type, coupon.discount_value),
              'coupon.expires_at': couponDateLabel(coupon.valid_until),
              'coupon.days_left': couponDaysLeft(coupon.valid_until),
              'booking.url': BOOKING_URL,
            },
            buttonSuffix: (variable, url) => customerLinkSuffix(variable as CustomerLinkVariable, url),
          })
          const sent = await callDracmaGateway({
            operation: 'SEND_TEMPLATE',
            tenant,
            adminId: String(integration.dispatch_admin_id),
            payload: { name: submission.provider_template_name, language: 'pt_BR', to: item.phone, ...parameters },
          })
          await markNotificationSent(client, delivery.id, typeof sent.message_id === 'string' ? sent.message_id : null)
          summary.sent += 1
        } catch (sendError) {
          await markNotificationFailed(client, delivery.id, sendError)
          summary.failed += 1
          summary.failures.push(`${maskPhone(item.phone)}: ${sendError instanceof Error ? sendError.message.slice(0, 60) : 'erro'}`)
        }
      }
      console.log('admin-notifications', 'REWARDS_WINBACK_DISPATCHED', JSON.stringify({ campaign: campaignId, by: admin.adminId, ...summary, failures: summary.failures.length }))
      return json({ eligible: list.length, without_whatsapp: list.length - recipients.length, ...summary })
    }

    // Complete Rewards test: a real single-use coupon of the campaign for the customer with
    // this phone, sent in the approved message with the real values. Not a campaign issuance.
    if (req.method === 'POST' && action === 'TEST_REWARDS_COMPLETE') {
      const templateId = uuid(record.template_id) as string
      const to = testRecipient(record.phone)
      const { data: link, error: linkError } = await client.from('marketing_campaign_message_templates')
        .select('campaign_id,event_key').eq('template_id', templateId).maybeSingle()
      if (linkError) throw new Error('REWARDS_TEMPLATES_LOOKUP_FAILED')
      if (!link) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      if (!['REWARDS_COUPON_ISSUED', 'REWARDS_WINBACK', 'REWARDS_COUPON_EXPIRING', 'REWARDS_REFERRAL_REWARD'].includes(String(link.event_key))) {
        throw new Error('REWARDS_TEST_NO_COUPON')
      }
      const { tenant, campaign } = await rewardsCampaign(admin.authUserId, String(link.campaign_id))
      const { data: template, error: templateError } = await client.from('notification_template_configs')
        .select('id,event_key,channel,body_template,variable_schema,updated_at').eq('id', templateId).maybeSingle()
      if (templateError || !template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      const { data: submission } = await client.from('whatsapp_template_submissions')
        .select('status,provider_template_name').eq('tenant_id', tenant.id).eq('notification_template_id', templateId).maybeSingle()
      if (submission?.status !== 'APPROVED') throw new Error('WHATSAPP_TEST_NOT_APPROVED')
      const settings = (await loadWhatsAppSettings([templateId])).get(templateId) ?? null
      const definition = await templateDefinition(template, tenant, settings)
      if (submission.provider_template_name && submission.provider_template_name !== definition.name) {
        throw new Error('WHATSAPP_TEST_TEMPLATE_CHANGED')
      }
      const { data: coupon, error: couponError } = await client.rpc('service_admin_issue_rewards_test_coupon', {
        p_tenant_id: tenant.id,
        p_campaign_id: link.campaign_id,
        p_phone: to,
        p_admin_id: admin.adminId,
        // The reminder talks about a coupon the customer already has: it never creates one.
        p_reuse_existing: link.event_key === 'REWARDS_COUPON_EXPIRING',
      })
      if (couponError) throw new Error(couponError.message)
      // Real values for the customer and the coupon; anything else keeps the approved sample.
      const values: Record<string, string> = {
        ...testValues('cliente@exemplo.com.br', tenant.name),
        'customer.name': String(coupon.customer_name ?? ''),
        'campaign.name': String(campaign.public_name ?? campaign.internal_name ?? ''),
        'coupon.code': String(coupon.code),
        'coupon.discount': couponDiscountLabel(coupon.discount_type, coupon.discount_value),
        'coupon.expires_at': couponDateLabel(coupon.valid_until),
        'coupon.days_left': couponDaysLeft(coupon.valid_until),
        'booking.url': BOOKING_URL,
        ...(coupon.last_rental_at ? { 'customer.last_rental_at': couponDateLabel(coupon.last_rental_at) } : {}),
      }
      const parameters = whatsappTemplateParameters({
        body: String(template.body_template ?? ''),
        catalog: [...templateVariableKeys(template.variable_schema), ...(settings?.button_variable ? [settings.button_variable] : [])],
        settings,
        values,
        buttonSuffix: (variable, url) => customerLinkSuffix(variable as CustomerLinkVariable, url),
      })
      const sent = await callDracmaGateway({
        operation: 'SEND_TEST_TEMPLATE',
        tenant,
        adminId: admin.adminId,
        payload: { name: definition.name, language: definition.language, to, ...parameters },
      })
      console.log('admin-notifications', 'REWARDS_COMPLETE_TEST_SENT', JSON.stringify({ template: definition.name, to: maskPhone(to), coupon: coupon.coupon_id, by: admin.adminId }))
      return json({ sent: sent.sent === true, to: maskPhone(to), coupon_code: coupon.code, customer_name: coupon.customer_name, reused: coupon.reused === true })
    }

    if (req.method === 'POST' && action === 'TEST') {
      const templateId = uuid(record.template_id) as string
      const { data: template, error: templateError } = await client
        .from('notification_template_configs')
        .select('id,event_key,channel,audience,operation_scope,category_id,title_template,body_template,html_template,is_active,variable_schema')
        .eq('id', templateId).maybeSingle()
      if (templateError || !template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      if (template.channel !== 'EMAIL') throw new Error('NOTIFICATION_TEST_EMAIL_ONLY')
      const requestedVariables = Array.isArray(template.variable_schema) ? template.variable_schema.map((item: unknown) => String(item)) : []
      if (requestedVariables.some((item: string) => financialVariables.has(item)) && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) {
        throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')
      }

      let scope = String(template.operation_scope ?? '').trim().toUpperCase()
      if (!scope && template.category_id) {
        const { data: categoryRows, error: categoryError } = await client.rpc('service_admin_list_categories')
        if (categoryError) throw new Error(categoryError.message)
        const category = records(categoryRows).find((item) => String(item.id ?? '') === String(template.category_id))
        scope = String(category?.operation_scope ?? '').trim().toUpperCase()
      }
      if (!scope) {
        const { data: binding } = await client.from('notification_template_services').select('service_id').eq('template_id', templateId).limit(1).maybeSingle()
        if (binding?.service_id) {
          const { data: serviceRows, error: serviceError } = await client.rpc('service_admin_list_service_settings')
          if (serviceError) throw new Error(serviceError.message)
          const service = records(serviceRows).find((item) => String(item.id ?? '') === String(binding.service_id))
          scope = String(service?.operation_scope ?? '').trim().toUpperCase()
        }
      }
      if (!['BLACKSHEEP', 'SABRINA'].includes(scope)) scope = 'BLACKSHEEP'
      const sender = notificationSenderForScope(scope)
      if (!sender) throw new Error('EMAIL_SCOPE_SENDER_NOT_CONFIGURED')

      const { data: authUser, error: authUserError } = await client.auth.admin.getUserById(admin.authUserId)
      if (authUserError || !authUser.user) throw new Error('ADMIN_TEST_RECIPIENT_LOOKUP_FAILED')
      const recipient = normalizedEmail(authUser.user.email)
      if (!recipient || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(recipient)) throw new Error('ADMIN_TEST_RECIPIENT_INVALID')

      const message = renderNotificationMessage(template as NotificationTemplate, testValues(recipient, sender.brandName), sender.brandName)
      const idempotencyKey = `notification-test:${templateId}:${crypto.randomUUID()}`
      const delivery = await beginNotificationDelivery(client, {
        templateId,
        eventKey: String(template.event_key),
        audience: template.audience === 'EMPLOYEE' ? 'EMPLOYEE' : 'CUSTOMER',
        recipient,
        idempotencyKey,
        isTest: true,
        payloadSnapshot: { template_id: templateId, operation_scope: scope, test: true },
      })
      const payload: EmailProviderPayload = { from: sender.from, to: [recipient], subject: message.subject, text: message.text, html: message.html }
      if (sender.replyTo) payload.reply_to = sender.replyTo
      try {
        const providerMessageId = await sendEmailWithProvider(payload, idempotencyKey)
        await markNotificationSent(client, delivery.id, providerMessageId)
        return json({ sent: true, template_id: templateId, recipient_masked: maskEmail(recipient), provider_message_id: providerMessageId })
      } catch (sendError) {
        await markNotificationFailed(client, delivery.id, sendError)
        throw sendError
      }
    }

    if (req.method === 'POST' && action === 'SAVE_REWARDS_TEMPLATE') {
      return json(await saveRewardsTemplate(admin, record), 200)
    }

    // Rewards "Cupom Rewards liberado": when it goes out (N minutes after the reservation
    // ends) and whether it is on. Same rules as the reservation messages.
    if (req.method === 'POST' && (action === 'SAVE_REWARDS_TRIGGER' || action === 'SET_REWARDS_ACTIVE')) {
      const templateId = uuid(record.template_id) as string
      const template = await rewardsCouponTemplate(admin.authUserId, templateId)
      if (action === 'SAVE_REWARDS_TRIGGER') {
        // Same trigger panel as the reservation messages; the coupon only goes after the end.
        if ((text(record.schedule_mode, true)?.toUpperCase() ?? 'AFTER_END') !== 'AFTER_END') throw new Error('REWARDS_TRIGGER_AFTER_END_ONLY')
        const offset = integer(record.schedule_offset_minutes)
        if (offset === null || offset < 1 || offset > 10080) throw new Error('NOTIFICATION_SCHEDULE_OFFSET_INVALID')
        const serviceIds = uuidArray(record.service_ids ?? [])
        const { error } = await client.rpc('service_admin_update_notification_trigger_v1', {
          p_template_id: templateId,
          p_schedule_mode: 'AFTER_END',
          p_schedule_offset_minutes: offset,
          p_service_ids: serviceIds,
          p_actor_admin_id: admin.adminId,
        })
        if (error) throw new Error(error.message)
        return json({ id: templateId, schedule_mode: 'AFTER_END', schedule_offset_minutes: offset, service_ids: serviceIds }, 200)
      }
      const active = record.is_active === true
      if (active) {
        if (template.schedule_mode !== 'AFTER_END') throw new Error('REWARDS_TRIGGER_REQUIRED')
        const { data: submission, error: submissionError } = await client.from('whatsapp_template_submissions')
          .select('status,submitted_at').eq('tenant_id', template.tenantId).eq('notification_template_id', templateId).maybeSingle()
        if (submissionError) throw new Error('WHATSAPP_SUBMISSION_LOOKUP_FAILED')
        if (submission?.status !== 'APPROVED') throw new Error('WHATSAPP_TEMPLATE_NOT_APPROVED')
        const settings = (await loadWhatsAppSettings([templateId])).get(templateId) ?? null
        const edited = latest(template.updated_at, settings?.updated_at)
        if (edited && submission.submitted_at && edited > String(submission.submitted_at)) throw new Error('WHATSAPP_TEMPLATE_CHANGED_SINCE_APPROVAL')
      }
      const { error: updateError } = await client.from('notification_template_configs')
        .update({ is_active: active, updated_by_admin_id: admin.adminId }).eq('id', templateId)
      if (updateError) throw new Error('NOTIFICATION_TEMPLATE_UPDATE_FAILED')
      await client.from('audit_logs').insert({
        admin_user_id: admin.adminId, entity_type: 'NOTIFICATION_TEMPLATE', entity_id: templateId,
        action: active ? 'WHATSAPP_ACTIVATE' : 'WHATSAPP_DEACTIVATE',
        before_json: { is_active: template.is_active }, after_json: { is_active: active }, origin: 'ADMIN',
      })
      return json({ id: templateId, is_active: active }, 200)
    }

    // Liga ou desliga o envio de um modelo de WhatsApp. Ligar só vale para o texto
    // que a Meta aprovou e não mexe em updated_at (é o que o whatsapp-send compara).
    if (req.method === 'POST' && action === 'SET_WHATSAPP_ACTIVE') {
      const templateId = uuid(record.template_id) as string
      const active = record.is_active === true
      const { data: template, error: templateError } = await client.from('notification_template_configs')
        .select('id,event_key,channel,is_active,updated_at').eq('id', templateId).maybeSingle()
      if (templateError) throw new Error('NOTIFICATION_TEMPLATE_LOOKUP_FAILED')
      if (!template) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      if (template.channel !== 'WHATSAPP') throw new Error('NOTIFICATION_CHANNEL_INVALID')
      if (isRewardsEvent(String(template.event_key))) throw new Error('NOTIFICATION_TEMPLATE_IS_REWARDS')
      if (active) {
        const { tenant } = await whatsappContext(admin.authUserId)
        const { data: submission, error: submissionError } = await client.from('whatsapp_template_submissions')
          .select('status,submitted_at').eq('tenant_id', tenant.id).eq('notification_template_id', templateId).maybeSingle()
        if (submissionError) throw new Error('WHATSAPP_SUBMISSION_LOOKUP_FAILED')
        if (submission?.status !== 'APPROVED') throw new Error('WHATSAPP_TEMPLATE_NOT_APPROVED')
        const settings = (await loadWhatsAppSettings([templateId])).get(templateId) ?? null
        const edited = latest(String(template.updated_at ?? ''), settings?.updated_at)
        if (edited && submission.submitted_at && edited > String(submission.submitted_at)) throw new Error('WHATSAPP_TEMPLATE_CHANGED_SINCE_APPROVAL')
      }
      const { error: updateError } = await client.from('notification_template_configs')
        .update({ is_active: active, updated_by_admin_id: admin.adminId }).eq('id', templateId)
      if (updateError) throw new Error(updateError.message.includes('whatsapp_dispatchable_events') ? 'WHATSAPP_EVENT_NOT_DISPATCHABLE' : 'NOTIFICATION_TEMPLATE_UPDATE_FAILED')
      await client.from('audit_logs').insert({
        admin_user_id: admin.adminId, entity_type: 'NOTIFICATION_TEMPLATE', entity_id: templateId,
        action: active ? 'WHATSAPP_ACTIVATE' : 'WHATSAPP_DEACTIVATE',
        before_json: { is_active: template.is_active }, after_json: { is_active: active }, origin: 'ADMIN',
      })
      return json({ id: templateId, is_active: active }, 200)
    }

    // Só o disparo (quando e para quais serviços): não mexe no texto, em is_active
    // nem em updated_at, então um modelo de WhatsApp aprovado continua aprovado.
    if (req.method === 'POST' && action === 'SAVE_TRIGGER') {
      const templateId = uuid(record.template_id) as string
      const { data: existing, error: existingError } = await client.from('notification_template_configs')
        .select('event_key').eq('id', templateId).maybeSingle()
      if (existingError) throw new Error('NOTIFICATION_TEMPLATE_LOOKUP_FAILED')
      if (!existing) throw new Error('NOTIFICATION_TEMPLATE_NOT_FOUND')
      if (isRewardsEvent(String(existing.event_key))) throw new Error('NOTIFICATION_TEMPLATE_IS_REWARDS')
      const { error } = await client.rpc('service_admin_update_notification_trigger_v1', {
        p_template_id: templateId,
        p_schedule_mode: text(record.schedule_mode, true)?.toUpperCase() ?? 'IMMEDIATE',
        p_schedule_offset_minutes: integer(record.schedule_offset_minutes),
        p_service_ids: uuidArray(record.service_ids ?? []),
        p_actor_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return json({ id: templateId }, 200)
    }

    const eventKey = (text(record.event_key) as string).toUpperCase()
    const channel = (text(record.channel) as string).toUpperCase()
    const audience = (text(record.audience) as string).toUpperCase()
    const operationScope = text(record.operation_scope, true)?.toUpperCase() ?? null
    const htmlTemplate = typeof record.html_template === 'string' ? record.html_template.trim() || null : null
    if (!events.includes(eventKey)) throw new Error('NOTIFICATION_EVENT_INVALID')
    if (!channels.includes(channel)) throw new Error('NOTIFICATION_CHANNEL_INVALID')
    const existingId = uuid(record.template_id, true)
    if (existingId) {
      const { data: existing, error: existingError } = await client.from('notification_template_configs')
        .select('event_key').eq('id', existingId).maybeSingle()
      if (existingError) throw new Error('NOTIFICATION_TEMPLATE_LOOKUP_FAILED')
      if (existing && isRewardsEvent(String(existing.event_key))) throw new Error('NOTIFICATION_TEMPLATE_IS_REWARDS')
    }
    if (channel === 'WHATSAPP' && record.is_active === true) throw new Error('WHATSAPP_TEMPLATE_DRAFT_ONLY')
    if (!audiences.includes(audience)) throw new Error('NOTIFICATION_AUDIENCE_INVALID')
    if (operationScope !== null && !['SABRINA', 'BLACKSHEEP'].includes(operationScope)) throw new Error('NOTIFICATION_OPERATION_SCOPE_INVALID')
    assertSafeCustomHtml(htmlTemplate)
    const requestedVariables = Array.isArray(record.variable_schema) ? record.variable_schema.map((item) => text(item) as string) : []
    if (requestedVariables.some((item) => !variables.includes(item))) throw new Error('NOTIFICATION_VARIABLE_INVALID')
    if (requestedVariables.some((item) => financialVariables.has(item)) && !(await hasAdminPermission(admin.adminId, 'FINANCE_MANAGE'))) {
      throw new Error('ADMIN_FINANCE_PERMISSION_REQUIRED')
    }

    // Validate the WhatsApp fields before saving anything, so a bad field never
    // leaves a half-saved draft.
    const whatsapp = channel === 'WHATSAPP' && record.whatsapp !== undefined && record.whatsapp !== null
      ? whatsappSettings(record.whatsapp, variables)
      : null
    const scheduleMode = text(record.schedule_mode, true)?.toUpperCase() ?? 'IMMEDIATE'
    const scheduleOffsetMinutes = integer(record.schedule_offset_minutes)
    const { data, error } = await client.rpc('service_admin_upsert_notification_template_v3', {
      p_template_id: uuid(record.template_id, true),
      p_event_key: eventKey,
      p_channel: channel,
      p_audience: audience,
      p_operation_scope: operationScope,
      p_category_id: uuid(record.category_id, true),
      p_title_template: text(record.title_template),
      p_body_template: typeof record.body_template === 'string' ? record.body_template : '',
      p_html_template: htmlTemplate,
      p_is_active: record.is_active === true,
      p_variable_schema: requestedVariables,
      p_reminder_offset_minutes: integer(record.reminder_offset_minutes),
      p_service_ids: uuidArray(record.service_ids ?? []),
      p_actor_admin_id: admin.adminId,
      p_schedule_mode: scheduleMode,
      p_schedule_offset_minutes: scheduleOffsetMinutes,
    })
    if (error) throw new Error(error.message)
    if (whatsapp) {
      // A page opened before a field existed does not send it: keep what is saved
      // instead of wiping it (an old page once removed the confirmation's button).
      const sent = record.whatsapp as Record<string, unknown>
      const stored = (await loadWhatsAppSettings([String(data)])).get(String(data))
      if (stored) {
        const keep = <K extends keyof WhatsAppSettings>(key: K) => {
          if (!(key in sent)) whatsapp[key] = stored[key]
        }
        keep('header_text')
        keep('footer_text')
        keep('ttl_seconds')
        keep('variable_examples')
        if (!('button_text' in sent) && !('button_variable' in sent)) {
          whatsapp.button_text = stored.button_text
          whatsapp.button_variable = stored.button_variable
        }
      }
      const { error: settingsError } = await client.from('notification_whatsapp_settings').upsert({
        template_id: data,
        ...whatsapp,
        updated_by_admin_id: admin.adminId,
        updated_at: new Date().toISOString(),
      }, { onConflict: 'template_id' })
      if (settingsError) throw new Error('WHATSAPP_SETTINGS_SAVE_FAILED')
    }
    return json({ id: data }, req.method === 'POST' ? 201 : 200)
  } catch (error) {
    const code = error instanceof Error ? error.message.split(':')[0] : 'NOTIFICATION_ADMIN_FAILED'
    const status = code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED'
      ? 401
      : code === 'REWARDS_CAMPAIGN_NOT_FOUND'
        ? 404
      : code === 'ADMIN_PERMISSION_DENIED' || code === 'ADMIN_FINANCE_PERMISSION_REQUIRED'
        ? 403
        : code.includes('PROVIDER_') || code.startsWith('EMAIL_')
          ? 502
          : 400
    return json({ error: { code } }, status)
  }
})
