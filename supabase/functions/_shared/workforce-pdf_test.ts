import { assert, assertEquals } from 'jsr:@std/assert@1'
import { buildWorkforceReportPdf, formatCnpj, formatMinutes, type WorkforceReportPayload } from './workforce-pdf.ts'

const decoder = new TextDecoder('latin1')

function payload(rows = 3): WorkforceReportPayload {
  return {
    employer: { legal_name: 'Pierri Quint Produções', trade_name: 'BlackSheep Estúdio Criativo', cnpj: '11222333000181' },
    competencia: '2026-10',
    employee: { display_name: 'Jheneffe' },
    habitual_schedules: [{
      effective_from: '2026-01-01',
      effective_to: null,
      days: [1, 2, 3, 4, 5].map((day) => ({ iso_weekday: day, start_time: '13:15', end_time: '19:15' })),
    }],
    rows: Array.from({ length: rows }, (_, index) => ({
      date: '2026-10-06',
      weekday: 'terça-feira',
      period: '18:00–20:00',
      type: 'EXTRA_WORK',
      classification: 'EXTRA_WEEKDAY',
      administrative_classification: index === 0 ? 'AUTHORIZED' : null,
      minutes: 45,
      status: 'VALIDATED',
    })),
    totals: { extra_weekday_minutes: 45, extra_saturday_minutes: 240, extra_sunday_minutes: 240, extra_holiday_minutes: 180 },
    version: 2,
  }
}

Deno.test('produces a well-formed PDF with header, razão social and CNPJ', () => {
  const pdf = decoder.decode(buildWorkforceReportPdf(payload()))
  assert(pdf.startsWith('%PDF-1.4'))
  assert(pdf.trimEnd().endsWith('%%EOF'))
  assert(pdf.includes('Pierri Quint Produ\\347\\365es'), 'razão social with WinAnsi accents')
  assert(pdf.includes('11.222.333/0001-81'))
  assert(pdf.includes('outubro/2026'))
  assert(pdf.includes('Extra dia \\372til'))
  assert(pdf.includes('0h45'))
  assert(pdf.includes('3h00'), 'holiday total 180 min')
  // xref offsets point at the objects they claim.
  const bytes = buildWorkforceReportPdf(payload())
  const text = decoder.decode(bytes)
  const xref = Number(text.slice(text.lastIndexOf('startxref') + 10).trim().split('\n')[0])
  assertEquals(text.slice(xref, xref + 4), 'xref')
  const firstOffset = Number(text.slice(xref).split('\n')[3].slice(0, 10))
  assertEquals(text.slice(firstOffset, firstOffset + 7), '1 0 obj')
})

Deno.test('never renders free text, reasons or internal notes', () => {
  const unsafe = payload() as WorkforceReportPayload & Record<string, unknown>
  const rows = unsafe.rows as Array<Record<string, unknown>>
  rows[0].employee_note = 'NOTA-SECRETA buscar filho'
  rows[0].reason = 'CID J11 gripe'
  rows[0].manager_note = 'NOTA-INTERNA'
  unsafe.reopen_reason = 'MOTIVO-REABERTURA'
  const pdf = decoder.decode(buildWorkforceReportPdf(unsafe))
  for (const forbidden of ['NOTA-SECRETA', 'buscar filho', 'CID', 'gripe', 'NOTA-INTERNA', 'MOTIVO-REABERTURA']) {
    assert(!pdf.includes(forbidden), forbidden)
  }
})

Deno.test('paginates long months', () => {
  const pdf = decoder.decode(buildWorkforceReportPdf(payload(120)))
  const pages = pdf.match(/\/Type \/Page /g) ?? []
  assert(pages.length >= 3)
  assert(pdf.includes('P\\341gina 1 de'))
})

Deno.test('formats minutes and CNPJ', () => {
  assertEquals(formatMinutes(45), '0h45')
  assertEquals(formatMinutes(240), '4h00')
  assertEquals(formatMinutes(null), '—')
  assertEquals(formatCnpj(null), 'não informado')
  assertEquals(formatCnpj('12ABC34501DE35'), '12.ABC.345/01DE-35')
})
