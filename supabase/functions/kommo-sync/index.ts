import { adminClient, errorResponse, jsonResponse } from '../_shared/supabase.ts'
import {
  buildContactCustomFields,
  exactContactCandidates,
  kommoJson,
  kommoLeadName,
  normalizePhone,
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
  stage_initial_contact_id: number | null
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

async function searchContactsByPhone(
  baseUrl: string,
  token: string,
  phone: string,
): Promise<KommoContact[]> {
  const normalized = normalizePhone(phone)
  if (!normalized) throw new Error('KOMMO_PHONE_REQUIRED')

  // This search is global in Kommo Contacts. Pipeline/stage is intentionally irrelevant
  // to customer identity: a person can have zero, one or many leads/reservations.
  const byId = new Map<number, KommoContact>()
  const queries = [...new Set([phone.trim(), normalized].filter(Boolean))]
  for (const query of queries) {
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
  const phone = customer.phone?.trim() ?? ''
  if (!normalizePhone(phone)) throw new Error('KOMMO_PHONE_REQUIRED')

  const { data: existingLink, error: existingLinkError } = await client
    .from('kommo_customer_links')
    .select('kommo_contact_id')
    .eq('customer_id', customer.id)
    .maybeSingle()
  if (existingLinkError) throw new Error('KOMMO_CUSTOMER_LINK_LOOKUP_FAILED')

  if (existingLink?.kommo_contact_id) {
    const linkedContact = await kommoJson<KommoContact>(baseUrl, token, `/contacts/${Number(existingLink.kommo_contact_id)}`)
    if (exactContactCandidates([linkedContact], null, phone).length !== 1) {
      throw new Error('KOMMO_LINK_PHONE_MISMATCH')
    }
    return Number(existingLink.kommo_contact_id)
  }

  // Provider-wide contact lookup by phone is mandatory before creating any contact.
  // E-mail is metadata, not an identity key for this integration.
  const candidates = exactContactCandidates(
    await searchContactsByPhone(baseUrl, token, phone),
    null,
    phone,
  )
  if (candidates.length > 1) throw new Error('KOMMO_CONTACT_PHONE_AMBIGUOUS')

  let contactId = candidates[0]?.id ?? null
  if (!contactId) {
    const fieldIds = await contactFieldIds(baseUrl, token)
    if (!Number.isInteger(fieldIds.phone) || Number(fieldIds.phone) <= 0) throw new Error('KOMMO_PHONE_FIELD_UNAVAILABLE')
    const customFields = buildContactCustomFields(
      fieldIds.email,
      fieldIds.phone,
      customer.email ?? null,
      phone,
    )
    const payload = await kommoJson<any>(baseUrl, token, '/contacts', {
      method: 'POST',
      body: JSON.stringify([{
        name: customer.name?.trim() || 'Cliente BlackSheep',
        custom_fields_values: customFields,
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
  return Number(contactId)
}

async function recoverLeadByName(baseUrl: string, token: string, expectedName: string): Promise<number | null> {
  const payload = await kommoJson<any>(baseUrl, token, `/leads?query=${encodeURIComponent(expectedName)}&limit=50`)
  const exact = (payload?._embedded?.leads ?? []).filter((lead: any) => lead?.name === expectedName)
  if (exact.length > 1) throw new Error('KOMMO_LEAD_AMBIGUOUS')
  const id = exact[0]?.id ?? null
  return Number.isInteger(id) && id > 0 ? id : null
}

async function recoverInitialLeadForContact(
  client: ReturnType<typeof adminClient>,
  baseUrl: string,
  token: string,
  contactId: number,
  settings: Settings,
): Promise<number | null> {
  if (!Number.isInteger(settings.pipeline_id) || Number(settings.pipeline_id) <= 0) throw new Error('KOMMO_PIPELINE_NOT_CONFIGURED')
  if (!Number.isInteger(settings.stage_initial_contact_id) || Number(settings.stage_initial_contact_id) <= 0) {
    throw new Error('KOMMO_INITIAL_STAGE_NOT_CONFIGURED')
  }

  // Contact may legitimately have several leads because each reservation is a separate lead.
  // We only reuse an unclaimed pre-booking lead in BlackSheep / CONTATO INICIAL.
  const contact = await kommoJson<any>(baseUrl, token, `/contacts/${contactId}?with=leads`)
  const rawLeadIds: number[] = (contact?._embedded?.leads ?? [])
    .map((lead: any) => Number(lead?.id))
    .filter((id: number) => Number.isInteger(id) && id > 0)
  const leadIds: number[] = [...new Set<number>(rawLeadIds)]
  if (leadIds.length === 0) return null

  const { data: mappedRows, error: mappedError } = await client
    .from('kommo_appointment_links')
    .select('kommo_lead_id')
    .in('kommo_lead_id', leadIds)
  if (mappedError) throw new Error('KOMMO_APPOINTMENT_LINK_LOOKUP_FAILED')

  const claimedLeadIds: number[] = (mappedRows ?? [])
    .map((row: any) => Number(row.kommo_lead_id))
    .filter((id: number) => Number.isInteger(id) && id > 0)
  const alreadyClaimed = new Set<number>(claimedLeadIds)

  const matches: number[] = []
  for (const leadId of leadIds) {
    if (alreadyClaimed.has(leadId)) continue
    const lead = await kommoJson<any>(baseUrl, token, `/leads/${leadId}`)
    if (
      Number(lead?.pipeline_id) === Number(settings.pipeline_id) &&
      Number(lead?.status_id) === Number(settings.stage_initial_contact_id)
    ) {
      matches.push(leadId)
    }
  }

  if (matches.length > 1) throw new Error('KOMMO_INITIAL_LEAD_AMBIGUOUS')
  return matches[0] ?? null
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
    if (!normalizePhone(desired.customer.phone ?? null)) throw new Error('KOMMO_PHONE_REQUIRED')

    const { data: settingsData, error: settingsError } = await client
      .from('kommo_integration_settings')
      .select('enabled, account_subdomain, pipeline_id, stage_initial_contact_id, stage_awaiting_payment_id, stage_confirmed_id, stage_rescheduled_id, stage_cancelled_id, stage_completed_id, stage_no_show_id, stage_expired_id')
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

    // One appointment maps to one lead. Historical/parallel leads for the same contact are valid.
    // Only an unclaimed CONTATO INICIAL lead can be converted into this appointment's lead.
    let leadId = existingLeadLink?.kommo_lead_id ? Number(existingLeadLink.kommo_lead_id) : null
    if (!leadId) leadId = await recoverInitialLeadForContact(client, baseUrl, token, contactId, settings)
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
