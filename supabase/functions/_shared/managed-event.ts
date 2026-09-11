export type ManagedAppointmentDesiredState = {
  appointment_id: string
  public_code?: string
  version: number
  appointment_status: string
  desired_action: 'PRESENT' | 'ABSENT'
  calendar_configured: boolean
  time_scope?: 'FULL_APPOINTMENT' | 'CORE_ONLY'
  start_at?: string
  end_at?: string
  google_calendar_id?: string
  remote_calendar_id?: string
  calendar_timezone?: string
  google_connection_id?: string
  summary?: string
  description?: string
}

export type ManagedCustomField = {
  field_key?: string | null
  label?: string | null
  value: unknown
  sort_order?: number | null
  sequence?: number
}

export function renderManagedNotificationTemplate(
  source: string,
  allowedVariables: Iterable<string>,
  values: Record<string, string>,
): string {
  const allowed = new Set(allowedVariables)
  return source.replace(/\{\{\s*([^}]+?)\s*\}\}/g, (_match, rawKey) => {
    const key = String(rawKey).trim()
    if (!allowed.has(key)) throw new Error(`NOTIFICATION_TEMPLATE_VARIABLE_NOT_ALLOWED:${key}`)
    return values[key] ?? ''
  })
}

function publicCustomFieldKey(value: string | null | undefined): boolean {
  const key = String(value ?? '').trim().toLowerCase()
  if (!key) return true
  return !(
    key.startsWith('_')
    || key.startsWith('internal_')
    || key.startsWith('internal.')
    || key.startsWith('system_')
    || key.startsWith('system.')
    || key.startsWith('bs_')
    || key.startsWith('bs.')
  )
}

export function renderManagedCustomFieldValue(value: unknown): string {
  if (value === null || value === undefined) return ''
  if (typeof value === 'string') return value.trim()
  if (typeof value === 'boolean') return value ? 'Sim' : 'Não'
  if (typeof value === 'number' || typeof value === 'bigint') return String(value)
  if (Array.isArray(value)) {
    return value
      .map((item) => renderManagedCustomFieldValue(item))
      .filter(Boolean)
      .join(', ')
  }
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>
    if ('label' in record) {
      const label = renderManagedCustomFieldValue(record.label)
      if (label) return label
    }
    if ('value' in record) {
      const nestedValue = renderManagedCustomFieldValue(record.value)
      if (nestedValue) return nestedValue
    }
    return Object.entries(record)
      .map(([key, nested]) => {
        const rendered = renderManagedCustomFieldValue(nested)
        return rendered ? `${key}: ${rendered}` : ''
      })
      .filter(Boolean)
      .join(', ')
  }
  return ''
}

function normalizedLabel(value: string): string {
  return value.trim().replace(/\s+/g, ' ').toLocaleLowerCase('pt-BR')
}

export function appendManagedCustomFields(
  description: string | null | undefined,
  fields: ManagedCustomField[],
): string {
  const base = String(description ?? '').trim()
  const occupiedLabels = new Set(
    base
      .split(/\r?\n/)
      .map((line) => line.match(/^\s*([^:]{1,200})\s*:/)?.[1] ?? '')
      .map(normalizedLabel)
      .filter(Boolean),
  )

  const lines = [...fields]
    .sort((left, right) => {
      const leftOrder = Number.isFinite(left.sort_order) ? Number(left.sort_order) : Number.MAX_SAFE_INTEGER
      const rightOrder = Number.isFinite(right.sort_order) ? Number(right.sort_order) : Number.MAX_SAFE_INTEGER
      if (leftOrder !== rightOrder) return leftOrder - rightOrder
      return Number(left.sequence ?? 0) - Number(right.sequence ?? 0)
    })
    .map((field) => {
      if (!publicCustomFieldKey(field.field_key)) return ''
      const label = String(field.label ?? '').trim()
      const value = renderManagedCustomFieldValue(field.value)
      if (!label || !value) return ''
      const normalized = normalizedLabel(label)
      if (occupiedLabels.has(normalized)) return ''
      occupiedLabels.add(normalized)
      return `${label}: ${value}`
    })
    .filter(Boolean)

  if (!lines.length) return base
  return [base, lines.join('\n')].filter(Boolean).join('\n\n')
}

export function deterministicAgendaGoogleEventId(appointmentId: string): string {
  const normalized = appointmentId.toLowerCase().replaceAll('-', '')
  if (!/^[0-9a-v]+$/.test(normalized)) throw new Error('APPOINTMENT_ID_NOT_GOOGLE_EVENT_ID_COMPATIBLE')
  return `bs${normalized}`
}

export function buildManagedGoogleEvent(desired: ManagedAppointmentDesiredState): Record<string, unknown> {
  if (!desired.start_at || !desired.end_at || !desired.calendar_timezone) {
    throw new Error('GOOGLE_APPOINTMENT_TIME_MISSING')
  }

  return {
    summary: desired.summary ?? 'Reserva BlackSheep Agenda',
    description: desired.description ?? `BlackSheep Agenda • Reserva ${desired.public_code ?? ''}`.trim(),
    start: {
      dateTime: desired.start_at,
      timeZone: desired.calendar_timezone,
    },
    end: {
      dateTime: desired.end_at,
      timeZone: desired.calendar_timezone,
    },
    extendedProperties: {
      private: {
        bs_source: 'blacksheep_agenda',
        bs_appointment_id: desired.appointment_id,
        bs_appointment_version: String(desired.version),
      },
    },
  }
}

export function sameInstant(left?: string | null, right?: string | null): boolean {
  if (!left || !right) return false
  const l = Date.parse(left)
  const r = Date.parse(right)
  return Number.isFinite(l) && Number.isFinite(r) && l === r
}

export function managedEventNeedsRepair(
  event: { status?: string | null; start_at?: string | null; end_at?: string | null },
  desired: ManagedAppointmentDesiredState,
): boolean {
  if (desired.desired_action !== 'PRESENT') return false
  if (event.status === 'cancelled') return true
  return !sameInstant(event.start_at, desired.start_at) || !sameInstant(event.end_at, desired.end_at)
}
