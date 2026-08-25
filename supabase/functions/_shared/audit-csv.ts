const formulaPrefix = /^[=+\-@\t\r\n]/

function spreadsheetSafeText(value: unknown): string {
  if (value === null || value === undefined) return ''
  const text = typeof value === 'string' ? value : JSON.stringify(value)
  // Quoting is not sufficient to stop spreadsheet formula execution. Prefix a
  // literal apostrophe when a cell starts with a formula/control marker; Excel,
  // Sheets and compatible viewers then treat the value as text while preserving
  // the original evidence for a human reader.
  return formulaPrefix.test(text) ? `'${text}` : text
}

export function auditCsvCell(value: unknown): string {
  const text = spreadsheetSafeText(value)
  return `"${text.replaceAll('"', '""')}"`
}

export function appointmentTimelineCsv(payload: unknown): string {
  const root = payload && typeof payload === 'object' ? payload as Record<string, unknown> : {}
  const events = Array.isArray(root.events) ? root.events as Array<Record<string, unknown>> : []
  const columns = [
    'occurred_at', 'origin', 'action', 'summary', 'actor_name', 'actor_role', 'actor_permissions',
    'reason', 'ip_address', 'user_agent', 'request_id', 'token_scope', 'destination_masked', 'provider',
    'before', 'after',
  ]
  return [
    columns.join(','),
    ...events.map((event) => columns.map((column) => auditCsvCell(event[column])).join(',')),
  ].join('\n')
}
