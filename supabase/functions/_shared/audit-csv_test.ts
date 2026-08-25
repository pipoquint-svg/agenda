import { appointmentTimelineCsv, auditCsvCell } from './audit-csv.ts'

function assertEquals(actual: unknown, expected: unknown, message: string): void {
  if (actual !== expected) throw new Error(`${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
}

Deno.test('audit CSV neutralizes spreadsheet formula prefixes', () => {
  for (const prefix of ['=', '+', '-', '@', '\t', '\r', '\n']) {
    const value = `${prefix}SUM(1,1)`
    assertEquals(auditCsvCell(value), `"'${value.replaceAll('"', '""')}"`, `prefix ${JSON.stringify(prefix)} was not neutralized`)
  }
})

Deno.test('audit CSV preserves ordinary evidence and escapes quotes', () => {
  assertEquals(auditCsvCell('Mozilla/5.0 "QA"'), '"Mozilla/5.0 ""QA"""', 'ordinary evidence changed')
  assertEquals(auditCsvCell(null), '""', 'null cell changed')
})

Deno.test('timeline CSV neutralizes user-controlled evidence fields without dropping content', () => {
  const csv = appointmentTimelineCsv({
    events: [{
      occurred_at: '2026-08-25T08:00:00.000Z',
      origin: 'CLIENT_TOKEN',
      action: 'VERIFY',
      summary: '=HYPERLINK("https://example.invalid")',
      reason: '+cmd',
      user_agent: '@malicious',
      request_id: 'safe-request',
      before: { note: '-formula-like-json-value' },
    }],
  })
  if (!csv.includes('"\'=HYPERLINK(""https://example.invalid"")"')) throw new Error('summary formula was not neutralized')
  if (!csv.includes('"\'+cmd"')) throw new Error('reason formula was not neutralized')
  if (!csv.includes('"\'@malicious"')) throw new Error('user agent formula was not neutralized')
  if (!csv.includes('"safe-request"')) throw new Error('safe evidence was dropped')
  if (!csv.includes('"{""note"":""-formula-like-json-value""}"')) throw new Error('JSON evidence changed unexpectedly')
})
