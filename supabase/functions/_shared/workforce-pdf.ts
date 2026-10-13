// Monthly Jornada por Exceção report as a PDF (spec §12). Built only from the
// immutable closure report payload, field by field, so free text, reasons,
// medical detail or internal notes can never reach the document even if a
// future payload carried them. Dependency-free: A4, Helvetica (WinAnsi).

export type WorkforceReportRow = {
  date: string
  weekday: string
  period: string
  type: string
  classification: string | null
  administrative_classification: string | null
  minutes: number | null
  status: string
}

export type WorkforceReportPayload = {
  employer: { legal_name: string; trade_name: string | null; cnpj: string | null }
  competencia: string
  employee: { display_name: string }
  habitual_schedules: Array<{
    effective_from: string
    effective_to: string | null
    days: Array<{ iso_weekday: number; start_time: string; end_time: string }>
  }>
  rows: WorkforceReportRow[]
  totals: {
    extra_weekday_minutes: number
    extra_saturday_minutes: number
    extra_sunday_minutes: number
    extra_holiday_minutes: number
  }
  version?: number
}

const PAGE_WIDTH = 595.28
const PAGE_HEIGHT = 841.89
const MARGIN = 40
const LINE = 14

const CLASSIFICATION_LABELS: Record<string, string> = {
  EXTRA_WEEKDAY: 'Extra dia útil',
  EXTRA_SATURDAY: 'Extra sábado',
  EXTRA_SUNDAY: 'Extra domingo',
  EXTRA_HOLIDAY: 'Extra feriado',
  EARLY_LEAVE: 'Saída antecipada',
  LATE_ARRIVAL: 'Atraso',
  ABSENCE: 'Ausência',
  MEDICAL_LEAVE: 'Afastamento médico',
  OTHER: 'Outra ocorrência',
  AUTHORIZED: 'Autorizada',
  EXCUSED: 'Abonada',
  DEDUCTIBLE: 'Descontável',
  INFORMATIONAL: 'Informativa',
}

const STATUS_LABELS: Record<string, string> = {
  RECORDED: 'Registrado',
  PENDING_REVIEW: 'Em revisão',
  VALIDATED: 'Validado',
  MANAGER_CONTESTED: 'Contestado',
  CORRECTION_REQUESTED: 'Correção pendente',
}

const WEEKDAYS = ['', 'seg', 'ter', 'qua', 'qui', 'sex', 'sáb', 'dom']

// Unicode → WinAnsiEncoding (cp1252). Unsupported characters become "?".
const WIN_ANSI_EXTRA: Record<number, number> = {
  0x20ac: 0x80, 0x201a: 0x82, 0x0192: 0x83, 0x201e: 0x84, 0x2026: 0x85, 0x2020: 0x86, 0x2021: 0x87,
  0x02c6: 0x88, 0x2030: 0x89, 0x0160: 0x8a, 0x2039: 0x8b, 0x0152: 0x8c, 0x017d: 0x8e, 0x2018: 0x91,
  0x2019: 0x92, 0x201c: 0x93, 0x201d: 0x94, 0x2022: 0x95, 0x2013: 0x96, 0x2014: 0x97, 0x02dc: 0x98,
  0x2122: 0x99, 0x0161: 0x9a, 0x203a: 0x9b, 0x0153: 0x9c, 0x017e: 0x9e, 0x0178: 0x9f,
}

function winAnsiBytes(text: string): number[] {
  const bytes: number[] = []
  for (const char of text.normalize('NFC')) {
    const code = char.codePointAt(0) ?? 0x3f
    if (code === 0x0a || code === 0x0d || code === 0x09) bytes.push(0x20)
    else if (code < 0x80 || (code >= 0xa0 && code <= 0xff)) bytes.push(code)
    else bytes.push(WIN_ANSI_EXTRA[code] ?? 0x3f)
  }
  return bytes
}

function pdfString(text: string): string {
  return winAnsiBytes(text)
    .map((byte) => {
      if (byte === 0x28 || byte === 0x29 || byte === 0x5c) return '\\' + String.fromCharCode(byte)
      if (byte < 0x20 || byte > 0x7e) return '\\' + byte.toString(8).padStart(3, '0')
      return String.fromCharCode(byte)
    })
    .join('')
}

// Approximate Helvetica width (average glyph 0.5em) to truncate long cells.
function fit(text: string, size: number, width: number): string {
  const max = Math.max(1, Math.floor(width / (size * 0.5)))
  return text.length <= max ? text : text.slice(0, Math.max(1, max - 1)) + '…'
}

export function formatMinutes(minutes: number | null): string {
  if (minutes === null || !Number.isFinite(minutes)) return '—'
  const sign = minutes < 0 ? '-' : ''
  const value = Math.abs(Math.trunc(minutes))
  return `${sign}${Math.floor(value / 60)}h${String(value % 60).padStart(2, '0')}`
}

export function formatCnpj(cnpj: string | null): string {
  if (!cnpj) return 'não informado'
  if (!/^[0-9A-Z]{12}[0-9]{2}$/.test(cnpj)) return cnpj
  return `${cnpj.slice(0, 2)}.${cnpj.slice(2, 5)}.${cnpj.slice(5, 8)}/${cnpj.slice(8, 12)}-${cnpj.slice(12)}`
}

function formatDate(iso: string): string {
  const [year, month, day] = iso.slice(0, 10).split('-')
  return `${day}/${month}/${year}`
}

function competenciaLabel(competencia: string): string {
  const months = ['janeiro', 'fevereiro', 'março', 'abril', 'maio', 'junho', 'julho', 'agosto', 'setembro', 'outubro', 'novembro', 'dezembro']
  const [year, month] = competencia.split('-')
  return `${months[Number(month) - 1] ?? month}/${year}`
}

function scheduleLines(payload: WorkforceReportPayload): string[] {
  return payload.habitual_schedules.map((schedule) => {
    const days = schedule.days.length === 0
      ? 'sem jornada habitual'
      : schedule.days.map((day) => `${WEEKDAYS[day.iso_weekday] ?? day.iso_weekday} ${day.start_time}–${day.end_time}`).join(', ')
    const validity = schedule.effective_to
      ? `de ${formatDate(schedule.effective_from)} até ${formatDate(schedule.effective_to)} (exclusive)`
      : `a partir de ${formatDate(schedule.effective_from)}`
    return `${days} — ${validity}`
  })
}

type TextOp = { x: number; y: number; size: number; bold: boolean; text: string }

const COLUMNS = [
  { title: 'Data', width: 62 },
  { title: 'Dia', width: 70 },
  { title: 'Período', width: 82 },
  { title: 'Classificação', width: 160 },
  { title: 'Duração', width: 58 },
  { title: 'Status', width: 83 },
]

export function buildWorkforceReportPdf(payload: WorkforceReportPayload): Uint8Array {
  const pages: TextOp[][] = []
  let ops: TextOp[] = []
  let y = PAGE_HEIGHT - MARGIN

  const newPage = () => {
    ops = []
    pages.push(ops)
    y = PAGE_HEIGHT - MARGIN
  }
  const text = (x: number, size: number, bold: boolean, value: string) => ops.push({ x, y, size, bold, text: value })
  const ensure = (lines: number) => {
    if (y - lines * LINE < MARGIN + LINE) {
      newPage()
      tableHeader()
    }
  }
  const tableHeader = () => {
    let x = MARGIN
    for (const column of COLUMNS) {
      text(x, 9, true, column.title)
      x += column.width
    }
    y -= LINE
  }

  newPage()
  text(MARGIN, 14, true, 'Espelho de Jornada por Exceção')
  y -= LINE * 1.6
  text(MARGIN, 10, true, payload.employer.legal_name)
  y -= LINE
  text(MARGIN, 10, false, `CNPJ: ${formatCnpj(payload.employer.cnpj)}`)
  y -= LINE
  text(MARGIN, 10, false, `Competência: ${competenciaLabel(payload.competencia)}${payload.version ? ` · versão ${payload.version}` : ''}`)
  y -= LINE
  text(MARGIN, 10, false, `Funcionária(o): ${payload.employee.display_name}`)
  y -= LINE
  text(MARGIN, 10, false, 'Jornada habitual:')
  y -= LINE
  for (const line of scheduleLines(payload)) {
    text(MARGIN + 12, 9, false, fit(line, 9, PAGE_WIDTH - 2 * MARGIN - 12))
    y -= LINE
  }
  y -= LINE * 0.6
  tableHeader()

  if (payload.rows.length === 0) {
    text(MARGIN, 9, false, 'Nenhuma exceção registrada na competência: considera-se cumprida a jornada habitual.')
    y -= LINE
  }
  for (const row of payload.rows) {
    ensure(1)
    const classification = [row.classification, row.administrative_classification]
      .filter((value): value is string => Boolean(value))
      .map((value) => CLASSIFICATION_LABELS[value] ?? value)
      .filter((value, index, all) => all.indexOf(value) === index)
      .join(' · ')
    const cells = [
      formatDate(row.date),
      row.weekday,
      row.period,
      classification,
      formatMinutes(row.minutes),
      STATUS_LABELS[row.status] ?? row.status,
    ]
    let x = MARGIN
    cells.forEach((cell, index) => {
      text(x, 9, false, fit(cell, 9, COLUMNS[index].width - 4))
      x += COLUMNS[index].width
    })
    y -= LINE
  }

  ensure(6)
  y -= LINE * 0.6
  text(MARGIN, 10, true, 'Totais apurados (sem valores monetários)')
  y -= LINE
  const totals: Array<[string, number]> = [
    ['Extra em dia útil', payload.totals.extra_weekday_minutes],
    ['Extra em sábado', payload.totals.extra_saturday_minutes],
    ['Extra em domingo', payload.totals.extra_sunday_minutes],
    ['Extra em feriado', payload.totals.extra_holiday_minutes],
  ]
  for (const [label, minutes] of totals) {
    text(MARGIN + 12, 10, false, `${label}: ${formatMinutes(minutes)}`)
    y -= LINE
  }

  return serialize(pages)
}

function serialize(pages: TextOp[][]): Uint8Array {
  const objects: string[] = []
  const add = (body: string) => {
    objects.push(body)
    return objects.length
  }
  const catalogId = add('')
  const pagesId = add('')
  const regularId = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>')
  const boldId = add('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>')
  const pageIds: number[] = []

  pages.forEach((ops, index) => {
    const footer = `Página ${index + 1} de ${pages.length}`
    const lines = ops.map((op) =>
      `BT /${op.bold ? 'F2' : 'F1'} ${op.size} Tf ${op.x.toFixed(2)} ${op.y.toFixed(2)} Td (${pdfString(op.text)}) Tj ET`
    )
    lines.push(`BT /F1 8 Tf ${MARGIN} ${(MARGIN / 2).toFixed(2)} Td (${pdfString(footer)}) Tj ET`)
    const stream = lines.join('\n')
    const contentId = add(`<< /Length ${stream.length} >>\nstream\n${stream}\nendstream`)
    pageIds.push(add(
      `<< /Type /Page /Parent ${pagesId} 0 R /MediaBox [0 0 ${PAGE_WIDTH} ${PAGE_HEIGHT}] ` +
        `/Resources << /Font << /F1 ${regularId} 0 R /F2 ${boldId} 0 R >> >> /Contents ${contentId} 0 R >>`,
    ))
  })
  objects[catalogId - 1] = `<< /Type /Catalog /Pages ${pagesId} 0 R >>`
  objects[pagesId - 1] = `<< /Type /Pages /Kids [${pageIds.map((id) => `${id} 0 R`).join(' ')}] /Count ${pageIds.length} >>`

  // Every content character is ASCII (non-ASCII bytes are octal escapes), so
  // string length equals byte length and offsets are exact.
  let output = '%PDF-1.4\n%âãÏÓ\n'
  const offsets: number[] = []
  objects.forEach((body, index) => {
    offsets.push(latin1Length(output))
    output += `${index + 1} 0 obj\n${body}\nendobj\n`
  })
  const xrefOffset = latin1Length(output)
  output += `xref\n0 ${objects.length + 1}\n0000000000 65535 f \n`
  output += offsets.map((offset) => `${String(offset).padStart(10, '0')} 00000 n \n`).join('')
  output += `trailer\n<< /Size ${objects.length + 1} /Root ${catalogId} 0 R >>\nstartxref\n${xrefOffset}\n%%EOF\n`

  const bytes = new Uint8Array(output.length)
  for (let i = 0; i < output.length; i++) bytes[i] = output.charCodeAt(i) & 0xff
  return bytes
}

function latin1Length(value: string): number {
  return value.length
}
