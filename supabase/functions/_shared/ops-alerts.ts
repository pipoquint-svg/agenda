export const OPS_ALERT_SLA_MINUTES = 15
export const OPS_ALERT_DEDUP_MINUTES = 60
export const OPS_INTEGRATION_FAILURE_THRESHOLD = 3

const MINUTE_MS = 60_000
const CODE_PATTERN = /^[A-Z][A-Z0-9_]{1,79}$/
const EMAIL_ADDRESS_PATTERN = /^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/

export type OpsIncidentCategory =
  | 'PAYMENT_STUCK'
  | 'EDGE_FAILURE'
  | 'INTEGRATION_FAILURES'
  | 'SCHEDULE_DIVERGENCE'
  | 'EMAIL_FAILURE'

export type OpsIncident = {
  fingerprint: string
  category: OpsIncidentCategory
  source: string
  code: string
  count: number
  first_detected_at: string
}

export type OpsSnapshot = {
  pendingPayments: Array<{ status: string; created_at: string }>
  edgeFailures: Array<{ function_name: string; error_code: string; http_status: number; occurred_at: string }>
  integrationFailures: Array<{ job_type: string; status: string; created_at: string }>
  openScheduleDivergences: Array<{ source: string; reason: string; status: string; detected_at: string }>
  emailFailures: Array<{ event_key: string; status: string; last_error_code: string | null; updated_at: string }>
}

export type OpsAlertState = {
  fingerprint: string
  category?: string
  source?: string
  code?: string
  occurrence_count?: number
  first_detected_at?: string
  last_notified_at: string | null
  notification_count?: number
  resolved_at?: string | null
}

export type OpsAlertEmail = { subject: string; text: string; html: string }

export type OpsAlertRecipientSources = {
  dedicatedRecipient?: string | null
  replyTo?: string | null
  sender?: string | null
}

type QueryResult<T> = PromiseLike<{ data: T | null; error: { message?: string; code?: string } | null }>
type OpsClient = {
  from(table: string): any
  rpc(name: string, args: Record<string, unknown>): QueryResult<unknown>
}

function validDate(value: string): number {
  const parsed = Date.parse(value)
  return Number.isFinite(parsed) ? parsed : Number.POSITIVE_INFINITY
}

function safeSegment(value: unknown, fallback: string): string {
  const normalized = String(value ?? '').trim().toUpperCase()
  return CODE_PATTERN.test(normalized) ? normalized : fallback
}

function minimumIso(values: string[], fallback: Date): string {
  const timestamps = values.map(validDate).filter(Number.isFinite)
  return new Date(timestamps.length > 0 ? Math.min(...timestamps) : fallback.getTime()).toISOString()
}

function incident(
  category: OpsIncidentCategory,
  source: string,
  code: string,
  count: number,
  firstDetectedAt: string,
): OpsIncident {
  const safeSource = safeSegment(source, 'UNKNOWN_SOURCE')
  const safeCode = sanitizeOpsCode(code)
  return {
    fingerprint: `${category}:${safeSource}:${safeCode}`,
    category,
    source: safeSource,
    code: safeCode,
    count,
    first_detected_at: firstDetectedAt,
  }
}

export function sanitizeOpsCode(value: unknown): string {
  const raw = typeof value === 'string' ? value.trim() : ''
  const prefix = raw.includes(':') ? raw.slice(0, raw.indexOf(':')).trim() : raw
  return CODE_PATTERN.test(prefix) ? prefix : 'UNCLASSIFIED_ERROR'
}

function extractEmailAddress(value: string | null | undefined): string | null {
  const raw = value?.trim() ?? ''
  if (!raw || raw.includes('\r') || raw.includes('\n')) return null
  const namedAddress = raw.match(/^[^<>]*<([^<>]+)>$/)?.[1]?.trim()
  const candidate = namedAddress ?? raw
  return EMAIL_ADDRESS_PATTERN.test(candidate) ? candidate : null
}

export function resolveOpsAlertRecipient(sources: OpsAlertRecipientSources): string {
  for (const value of [sources.dedicatedRecipient, sources.replyTo, sources.sender]) {
    const address = extractEmailAddress(value)
    if (address) return address
  }
  throw new Error('OPS_ALERT_RECIPIENT_MISSING')
}

export function buildOpsIncidents(snapshot: OpsSnapshot, now = new Date()): OpsIncident[] {
  const incidents: OpsIncident[] = []
  const staleCutoff = now.getTime() - OPS_ALERT_SLA_MINUTES * MINUTE_MS
  const recentCutoff = staleCutoff

  const stuckPayments = snapshot.pendingPayments.filter((row) => row.status === 'PENDING' && validDate(row.created_at) <= staleCutoff)
  if (stuckPayments.length > 0) {
    incidents.push(incident('PAYMENT_STUCK', 'PAYMENT_TRANSACTIONS', 'PENDING_BEYOND_SLA', stuckPayments.length, minimumIso(stuckPayments.map((row) => row.created_at), now)))
  }

  const edgeGroups = new Map<string, typeof snapshot.edgeFailures>()
  for (const row of snapshot.edgeFailures) {
    if (validDate(row.occurred_at) < recentCutoff || validDate(row.occurred_at) > now.getTime()) continue
    const source = safeSegment(row.function_name.replaceAll('-', '_'), 'UNKNOWN_EDGE')
    const code = sanitizeOpsCode(row.error_code)
    const key = `${source}:${code}`
    edgeGroups.set(key, [...(edgeGroups.get(key) ?? []), row])
  }
  for (const [key, rows] of edgeGroups) {
    const [source, code] = key.split(':')
    incidents.push(incident('EDGE_FAILURE', source, code, rows.length, minimumIso(rows.map((row) => row.occurred_at), now)))
  }

  const integrationGroups = new Map<string, typeof snapshot.integrationFailures>()
  for (const row of snapshot.integrationFailures) {
    if (row.status !== 'FAILED' || validDate(row.created_at) < recentCutoff || validDate(row.created_at) > now.getTime()) continue
    const source = safeSegment(row.job_type, 'UNKNOWN_JOB')
    integrationGroups.set(source, [...(integrationGroups.get(source) ?? []), row])
  }
  for (const [source, rows] of integrationGroups) {
    if (rows.length < OPS_INTEGRATION_FAILURE_THRESHOLD) continue
    incidents.push(incident('INTEGRATION_FAILURES', source, 'FAILED_THRESHOLD', rows.length, minimumIso(rows.map((row) => row.created_at), now)))
  }

  const divergenceGroups = new Map<string, typeof snapshot.openScheduleDivergences>()
  for (const row of snapshot.openScheduleDivergences) {
    if (row.status !== 'OPEN' || validDate(row.detected_at) > staleCutoff) continue
    const source = safeSegment(row.source, 'SCHEDULE')
    const code = sanitizeOpsCode(row.reason)
    const key = `${source}:${code}`
    divergenceGroups.set(key, [...(divergenceGroups.get(key) ?? []), row])
  }
  for (const [key, rows] of divergenceGroups) {
    const [source, code] = key.split(':')
    incidents.push(incident('SCHEDULE_DIVERGENCE', source, code, rows.length, minimumIso(rows.map((row) => row.detected_at), now)))
  }

  const emailGroups = new Map<string, typeof snapshot.emailFailures>()
  for (const row of snapshot.emailFailures) {
    if (row.status !== 'FAILED' || validDate(row.updated_at) < recentCutoff || validDate(row.updated_at) > now.getTime()) continue
    const source = safeSegment(row.event_key, 'TRANSACTIONAL_EMAIL')
    const code = sanitizeOpsCode(row.last_error_code)
    const key = `${source}:${code}`
    emailGroups.set(key, [...(emailGroups.get(key) ?? []), row])
  }
  for (const [key, rows] of emailGroups) {
    const [source, code] = key.split(':')
    incidents.push(incident('EMAIL_FAILURE', source, code, rows.length, minimumIso(rows.map((row) => row.updated_at), now)))
  }

  return incidents.sort((a, b) => a.fingerprint.localeCompare(b.fingerprint))
}

export function selectDueOpsIncidents(incidents: OpsIncident[], states: OpsAlertState[], now = new Date()): OpsIncident[] {
  const stateByFingerprint = new Map(states.map((state) => [state.fingerprint, state]))
  const cutoff = now.getTime() - OPS_ALERT_DEDUP_MINUTES * MINUTE_MS
  return incidents.filter((item) => {
    const last = stateByFingerprint.get(item.fingerprint)?.last_notified_at
    return !last || validDate(last) <= cutoff
  })
}

function escapeHtml(value: string): string {
  return value.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#039;')
}

export function renderOpsAlertEmail(incidents: OpsIncident[], now = new Date()): OpsAlertEmail {
  const lines = incidents.map((item) => `- ${item.category} | origem=${item.source} | código=${item.code} | ocorrências=${item.count} | desde=${item.first_detected_at}`)
  const subject = `[BlackSheep] ${incidents.length} alerta(s) operacional(is)`
  const text = [
    'Alerta operacional BlackSheep',
    `Detectado em: ${now.toISOString()}`,
    '',
    ...lines,
    '',
    'Sem dados pessoais, tokens, valores de cartão ou credenciais.',
  ].join('\n')
  const htmlItems = lines.map((line) => `<li>${escapeHtml(line.slice(2))}</li>`).join('')
  return {
    subject,
    text,
    html: `<h1>Alerta operacional BlackSheep</h1><p>Detectado em: ${escapeHtml(now.toISOString())}</p><ul>${htmlItems}</ul><p>Sem dados pessoais, tokens, valores de cartão ou credenciais.</p>`,
  }
}

async function queryOpsSnapshot(client: OpsClient, now: Date): Promise<OpsSnapshot> {
  const recent = new Date(now.getTime() - OPS_ALERT_SLA_MINUTES * MINUTE_MS).toISOString()
  const stale = recent
  const [payments, edges, integrations, divergences, emails] = await Promise.all([
    client.from('payment_transactions').select('status,created_at').eq('status', 'PENDING').lte('created_at', stale),
    client.from('ops_edge_failure_events').select('function_name,error_code,http_status,occurred_at').gte('occurred_at', recent).lte('occurred_at', now.toISOString()),
    client.from('integration_jobs').select('job_type,status,created_at').eq('status', 'FAILED').gte('created_at', recent).lte('created_at', now.toISOString()),
    client.from('schedule_divergences').select('source,reason,status,detected_at').eq('status', 'OPEN').lte('detected_at', stale),
    client.from('notification_delivery_logs').select('event_key,status,last_error_code,updated_at').eq('channel', 'EMAIL').eq('status', 'FAILED').gte('updated_at', recent).lte('updated_at', now.toISOString()),
  ])
  const results = [payments, edges, integrations, divergences, emails]
  if (results.some((result) => result.error)) throw new Error('OPS_ALERT_QUERY_FAILED')
  return {
    pendingPayments: payments.data ?? [],
    edgeFailures: edges.data ?? [],
    integrationFailures: integrations.data ?? [],
    openScheduleDivergences: divergences.data ?? [],
    emailFailures: emails.data ?? [],
  }
}

export async function runOpsAlertCycle(
  client: OpsClient,
  options: {
    now?: Date
    send: (email: OpsAlertEmail, incidents: OpsIncident[]) => Promise<string | null>
  },
): Promise<{ incident_count: number; notified_count: number; categories: OpsIncidentCategory[] }> {
  const now = options.now ?? new Date()
  const snapshot = await queryOpsSnapshot(client, now)
  const incidents = buildOpsIncidents(snapshot, now)
  const { data: existingData, error: stateError } = await client.from('ops_alert_states').select('fingerprint,category,source,code,occurrence_count,first_detected_at,last_notified_at,notification_count,resolved_at')
  if (stateError) throw new Error('OPS_ALERT_STATE_QUERY_FAILED')
  const states = (existingData ?? []) as OpsAlertState[]
  const byFingerprint = new Map(states.map((state) => [state.fingerprint, state]))

  if (incidents.length > 0) {
    const observed = incidents.map((item) => {
      const existing = byFingerprint.get(item.fingerprint)
      return {
        fingerprint: item.fingerprint,
        category: item.category,
        source: item.source,
        code: item.code,
        occurrence_count: item.count,
        first_detected_at: existing?.first_detected_at ?? item.first_detected_at,
        last_seen_at: now.toISOString(),
        last_notified_at: existing?.last_notified_at ?? null,
        notification_count: existing?.notification_count ?? 0,
        resolved_at: null,
      }
    })
    const { error } = await client.from('ops_alert_states').upsert(observed, { onConflict: 'fingerprint' })
    if (error) throw new Error('OPS_ALERT_STATE_WRITE_FAILED')
  }

  const active = new Set(incidents.map((item) => item.fingerprint))
  for (const state of states) {
    if (!state.resolved_at && !active.has(state.fingerprint)) {
      const { error } = await client.from('ops_alert_states').update({ resolved_at: now.toISOString() }).eq('fingerprint', state.fingerprint)
      if (error) throw new Error('OPS_ALERT_STATE_RESOLVE_FAILED')
    }
  }

  const due = selectDueOpsIncidents(incidents, states, now)
  if (due.length > 0) {
    await options.send(renderOpsAlertEmail(due, now), due)
    for (const item of due) {
      const state = byFingerprint.get(item.fingerprint)
      const { error } = await client.from('ops_alert_states').update({
        last_notified_at: now.toISOString(),
        notification_count: (state?.notification_count ?? 0) + 1,
      }).eq('fingerprint', item.fingerprint)
      if (error) throw new Error('OPS_ALERT_NOTIFY_STATE_FAILED')
    }
  }

  return {
    incident_count: incidents.length,
    notified_count: due.length,
    categories: [...new Set(incidents.map((item) => item.category))],
  }
}

export async function recordOpsEdgeFailure(
  clientFactory: () => OpsClient,
  functionName: string,
  errorCode: unknown,
  httpStatus: number,
  force = false,
): Promise<void> {
  if (httpStatus < 500 && !force) return
  try {
    const { error } = await clientFactory().rpc('service_record_ops_edge_failure', {
      p_function_name: functionName,
      p_error_code: sanitizeOpsCode(errorCode),
      p_http_status: httpStatus,
    })
    if (error) throw new Error('OPS_EDGE_TELEMETRY_RPC_FAILED')
  } catch {
    console.error('[OPERATION_ALERT] OPS_EDGE_TELEMETRY_WRITE_FAILED', { function_name: functionName })
  }
}
