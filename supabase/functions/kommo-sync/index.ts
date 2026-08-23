import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import {
  buildContactCustomFields,
  exactContactCandidates,
  kommoJson,
  kommoLeadName,
  stageIdForAppointment,
  type KommoContact,
} from '../_shared/kommo.ts'

function requireInternal(req: Request): void {
  const expected = Deno.env.get('INTEGRATION_INTERNAL_SECRET')
  const supplied = req.headers.get('x-internal-secret')
  if (!expected || supplied !== expected) throw new Error('INTERNAL_AUTH_REQUIRED')
}

type DesiredState = {
  appointment_id: string
  public_code?: string | null
  version: number
  eligible: boolean
  reason?: string | null
  operation_scope?: string | null
  appointment_status?: string | null
  financial_status?: string | null
  service?: { id?: string; name?: string | null } | null
  schedule?: { start_at?: string | null; end_at?: string | null } | null
  commercial_value?: number | null
  customer?: { id?: string; name?: string | null; email?: string | null; phone?: string | null } | null
}

type Settings = {
  enabled: boolean
  account_subdomain: string | null
  pipeline_id: number | null
  stage_awaiting_payment_id: number | null
  stage_confirmed_id: number | null
  stage_rescheduled_id: number | null
  stage_cancelled_id: number | null
  stage_completed_id: number | null
  stage_no_show_id: number | null
  stage_expired_id: number | null
}

async function contactFieldIds(baseUrl: string, token: string): Promise<{ email: number | null; phone: number | null }> {
  const payload = await kommoJson<any>(baseUrl, token, '/contacts/custom_fields?limit=250')
  const fields = payload?._embedded?.custom_fields ?? []
  const email = fields.find((field: any) => field.code === 'EMAIL')?.id ?? null
  const phone = fields.find((field: any) => field.code === 'PHONE')?.id ?? null
  return { email: Number.isInteger(email) ? email : null, phone: Number.isInteger(phone) ? phone : null }
}

async function searchContacts(
  baseUrl: string,
  token: string,
  email: string | null,
  phone: string | null,
): Promise<KommoContact[]> {
  const byId = new Map<number, KommoContact>()
  for (const query of [email, phone].filter((value): value is string => Boolean(value?.trim()))) {
    const payload = await kommoJson<any>(baseUrl, token, `/contacts?query=${encodeURIComponent(query)}&limit=50`)
    for (const contact of payload?._embedded?.contacts ?? []) {
      if (Number.isInteger(contact?.id)) byId.set(contact.id, contact)
    }
  }
  return [...byId.values()]
}

async function ensureContact(
  client: ReturnType<typeof adminClient>,
  baseUrl: string,
  token: string,
  customer: NonNullable<DesiredState['customer']>,
): Promise<number> {
  if (!customer.id) throw new Error('KOMMO_CUSTOMER_ID_REQUIRED')

  const { data: existingLink, error: existingLinkError } = await client
    .from('kommo_customer_links')
    .select('kommo_contact_id')
    .eq('customer_id', customer.id)
    .maybeSingle()
  if (existingLinkError) throw new Error('KOMMO_CUSTOMER_LINK_LOOKUP_FAILED')
  if (existingLink?.kommo_contact_id) return Number(existingLink.kommo_contact_id)

  const candidates = exactContactCandidates(
    await searchContacts(baseUrl, token, customer.email ?? null, customer.phone ?? null),
    customer.email ?? null,
    customer.phone ?? null,
  )
  if (candidates.length > 1) throw new Error('KOMMO_CONTACT_AMBIGUOUS')

  let contactId = candidates[0]?.id ?? null
  if (!contactId) {
    const fieldIds = await contactFieldIds(baseUrl, token)
    const customFields = buildContactCustomFields(
      fieldIds.email,
      fieldIds.phone,
      customer.email ?? null,
      customer.phone ?? null,
    )
    const payload = await kommoJson<any>(baseUrl, token, '/contacts', {
      method: 'POST',
      body: JSON.stringify([{
        name: customer.name?.trim() || 'Cliente BlackSheep',
        custom_fields_values: customFields.length ? customFields : undefined,
      }]),
    })
    contactId = payload?._embedded?.contacts?.[0]?.id ?? null
    if (!Number.isInteger(contactId) || contactId <= 0) throw new Error('KOMMO_CONTACT_CREATE_INVALID_RESPONSE')
  }

  const { error: linkError } = await client.from('kommo_customer_links').upsert({
    customer_id: customer.id,
    kommo_contact_id: contactId,
    last_synced_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  }, { onConflict: 'customer_id' })
  if (linkError) throw new Error('KOMMO_CUSTOMER_LINK_SAVE_FAILED')
  return contactId
}

async function recoverLeadByName(baseUrl: string, token: string, expectedName: string): Promise<number | null> {
  const payload = await kommoJson<any>(baseUrl, token, `/leads?query=${encodeURIComponent(expectedName)}&limit=50`)
  const exact = (payload?._embedded?.leads ?? []).filter((lead: any) => lead?.name === expectedName)
  if (exact.length > 1) throw new Error('KOMMO_LEAD_AMBIGUOUS')
  const id = exact[0]?.id ?? null
  return Number.isInteger(id) && id > 0 ? id : null
}

async function ensureLeadContactLink(baseUrl: string, token: string, leadId: number, contactId: number): Promise<void> {
  const filter = `filter[to_entity_id]=${contactId}&filter[to_entity_type]=contacts`
  const payload = await kommoJson<any>(baseUrl, token, `/leads/${leadId}/links?${filter}`)
  const links = payload?._embedded?.links ?? []
  const alreadyLinked = links.some((link: any) =>
    Number(link?.to_entity_id) === contactId && String(link?.to_entity_type ?? '') === 'contacts'
  )
  if (alreadyLinked) return

  await kommoJson(baseUrl, token, `/leads/${leadId}/link`, {
    method: 'POST',
    body: JSON.stringify([{
      to_entity_id: contactId,
      to_entity_type: 'contacts',
      metadata: { main_contact: true },
    }]),
  })
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return errorResponse(new Error('METHOD_NOT_ALLOWED'), 405)

  try {
    requireInternal(req)
    const body = await req.json()
    const appointmentId = String(body.appointment_id ?? '')
    const entityVersion = Number(body.entity_version)
    const eventKind = String(body.event_kind ?? 'UPDATED').trim().toUpperCase()
    if (!appointmentId) throw new Error('APPOINTMENT_ID_REQUIRED')
    if (!Number.isInteger(entityVersion) || entityVersion < 1) throw new Error('ENTITY_VERSION_REQUIRED')

    const token = Deno.env.get('KOMMO_ACCESS_TOKEN')
    if (!token) throw new Error('MISSING_ENV:KOMMO_ACCESS_TOKEN')

    const client = adminClient()
    const { data: desiredData, error: desiredError } = await client.rpc('get_kommo_appointment_desired_state', {
      p_appointment_id: appointmentId,
    })
    if (desiredError) throw new Error(desiredError.message)
    const desired = desiredData as DesiredState

    if (entityVersion < desired.version) {
      return jsonResponse({ stale: true, current_version: desired.version, appointment_id: appointmentId })
    }
    if (entityVersion > desired.version) throw new Error('ENTITY_VERSION_AHEAD_OF_APPOINTMENT')
    if (!desired.eligible) return jsonResponse({ stale: false, skipped: true, reason: desired.reason ?? 'KOMMO_NOT_ELIGIBLE' })
    if (desired.operation_scope !== 'BLACKSHEEP') throw new Error('KOMMO_OPERATION_SCOPE_DENIED')
    if (!desired.customer?.id) throw new Error('KOMMO_CUSTOMER_REQUIRED')

    const { data: settingsData, error: settingsError } = await client
      .from('kommo_integration_settings')
      .select('enabled, account_subdomain, pipeline_id, stage_awaiting_payment_id, stage_confirmed_id, stage_rescheduled_id, stage_cancelled_id, stage_completed_id, stage_no_show_id, stage_expired_id')
      .eq('id', 1)
      .maybeSingle()
    if (settingsError || !settingsData) throw new Error('KOMMO_SETTINGS_UNAVAILABLE')
    const settings = settingsData as Settings
    if (!settings.enabled) return jsonResponse({ stale: false, skipped: true, reason: 'KOMMO_DISABLED' })
    if (!settings.account_subdomain) throw new Error('KOMMO_ACCOUNT_SUBDOMAIN_REQUIRED')
    if (!Number.isInteger(settings.pipeline_id) || Number(settings.pipeline_id) <= 0) throw new Error('KOMMO_PIPELINE_NOT_CONFIGURED')

    const baseUrl = `https://${settings.account_subdomain}.kommo.com/api/v4`
    const stageId = stageIdForAppointment(settings, desired.appointment_status ?? 'CREATED', eventKind)
    const contactId = await ensureContact(client, baseUrl, token, desired.customer)
    const leadName = kommoLeadName(desired.service?.name, desired.public_code)

    const { data: existingLeadLink, error: existingLeadLinkError } = await client
      .from('kommo_appointment_links')
      .select('kommo_lead_id, last_synced_version')
      .eq('appointment_id', appointmentId)
      .maybeSingle()
    if (existingLeadLinkError) throw new Error('KOMMO_APPOINTMENT_LINK_LOOKUP_FAILED')

    let leadId = existingLeadLink?.kommo_lead_id ? Number(existingLeadLink.kommo_lead_id) : null
    if (!leadId) leadId = await recoverLeadByName(baseUrl, token, leadName)

    const leadBody = {
      name: leadName,
      pipeline_id: Number(settings.pipeline_id),
      status_id: stageId,
    }

    if (leadId) {
      await kommoJson(baseUrl, token, `/leads/${leadId}`, {
        method: 'PATCH',
        body: JSON.stringify(leadBody),
      })
    } else {
      const created = await kommoJson<any>(baseUrl, token, '/leads', {
        method: 'POST',
        body: JSON.stringify([leadBody]),
      })
      leadId = created?._embedded?.leads?.[0]?.id ?? null
      if (!Number.isInteger(leadId) || Number(leadId) <= 0) throw new Error('KOMMO_LEAD_CREATE_INVALID_RESPONSE')
    }

    await ensureLeadContactLink(baseUrl, token, Number(leadId), contactId)

    const now = new Date().toISOString()
    const { error: appointmentLinkError } = await client.from('kommo_appointment_links').upsert({
      appointment_id: appointmentId,
      kommo_lead_id: leadId,
      kommo_contact_id: contactId,
      last_synced_version: desired.version,
      last_synced_status: desired.appointment_status ?? null,
      last_synced_at: now,
      updated_at: now,
    }, { onConflict: 'appointment_id' })
    if (appointmentLinkError) throw new Error('KOMMO_APPOINTMENT_LINK_SAVE_FAILED')

    await client.from('kommo_customer_links').update({ last_synced_at: now, updated_at: now }).eq('customer_id', desired.customer.id)

    return jsonResponse({
      stale: false,
      skipped: false,
      appointment_id: appointmentId,
      version: desired.version,
      kommo_contact_id: contactId,
      kommo_lead_id: leadId,
      stage_id: stageId,
    })
  } catch (error) {
    const code = error instanceof Error ? error.message : 'KOMMO_SYNC_FAILED'
    return errorResponse(error, code === 'INTERNAL_AUTH_REQUIRED' ? 401 : 400)
  }
})
