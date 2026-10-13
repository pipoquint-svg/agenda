// Delivery cycle of the Jornada por Exceção (spec §13). Pure orchestration
// with injected dependencies so tests run against a fake provider:
//   1. run the SQL cycle (auto-close due competências, claim due sends);
//   2. render each claimed item (report PDF built from the closure payload);
//   3. send through the central provider with the item's idempotency key;
//   4. record SENT/FAILED. A failure never touches the closure.
import { buildWorkforceReportPdf, formatMinutes, type WorkforceReportPayload } from './workforce-pdf.ts'

export type ClaimedDelivery = {
  delivery_id: string
  idempotency_key: string
  recipient_email: string
  recipient_kind: 'ACCOUNTANT' | 'ACCOUNTANT_SECONDARY' | 'EMPLOYEE'
  report_kind: 'ACCOUNTANT_MIRROR' | 'EMPLOYEE_MIRROR'
  version: number
  attempt: number
  report: WorkforceReportPayload
}

export type ClaimedNotification = {
  notification_id: string
  idempotency_key: string
  recipient_email: string
  event_kind: 'RECORD_COMPLETED' | 'OWNER_OCCURRENCE' | 'CORRECTION_REVIEWED' | 'OWNER_CONTESTED'
  attempt: number
  employer_legal_name: string
  employee_display_name: string
  payload: {
    exception_type?: string
    event_date?: string
    all_day?: boolean
    start_local?: string | null
    end_local?: string | null
    status?: string
    decision?: string
  }
}

export type CycleResult = {
  closed_periods: number
  blocked_periods: number
  deliveries: ClaimedDelivery[]
  notifications: ClaimedNotification[]
}

export type OutgoingEmail = {
  to: string
  subject: string
  text: string
  attachments?: Array<{ filename: string; content: string }>
}

export type DeliveryDeps = {
  runCycle: () => Promise<CycleResult>
  recordResult: (kind: 'DELIVERY' | 'NOTIFICATION', id: string, success: boolean, providerMessageId: string | null, errorCode: string | null) => Promise<void>
  send: (email: OutgoingEmail, idempotencyKey: string) => Promise<string | null>
}

const TYPE_LABELS: Record<string, string> = {
  EXTRA_WORK: 'trabalho extraordinário',
  EARLY_LEAVE: 'saída antecipada',
  LATE_ARRIVAL: 'atraso',
  ABSENCE: 'ausência',
  MEDICAL_LEAVE: 'afastamento médico',
  OTHER: 'ocorrência',
}

const RECEIPT_SUBJECTS: Record<ClaimedNotification['event_kind'], string> = {
  RECORD_COMPLETED: 'Comprovante de registro de jornada',
  OWNER_OCCURRENCE: 'Ocorrência registrada na sua jornada',
  CORRECTION_REVIEWED: 'Resultado da sua solicitação de correção',
  OWNER_CONTESTED: 'Registro de jornada contestado',
}

function base64(bytes: Uint8Array): string {
  let binary = ''
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(binary)
}

function shortDate(iso: string | undefined): string {
  if (!iso) return ''
  const [year, month, day] = iso.slice(0, 10).split('-')
  return `${day}/${month}/${year}`
}

export function errorCode(error: unknown): string {
  const message = error instanceof Error ? error.message : ''
  const code = message.split(':')[0].trim()
  return /^[A-Z0-9_]{1,80}$/.test(code) ? code : 'SEND_FAILED'
}

// Only whitelisted, non-sensitive fields reach the e-mail body.
export function renderDelivery(item: ClaimedDelivery): OutgoingEmail {
  const report = item.report
  const [year, month] = report.competencia.split('-')
  const label = `${month}/${year}`
  const pdf = buildWorkforceReportPdf({ ...report, version: item.version })
  const accountant = item.report_kind === 'ACCOUNTANT_MIRROR'
  const rectification = item.version > 1 ? ` (retificação — versão ${item.version})` : ''
  const lines = accountant
    ? [
      'Olá,',
      '',
      `Segue o espelho de jornada por exceção da competência ${label}${rectification}.`,
      `Empregadora: ${report.employer.legal_name}`,
      `Funcionária(o): ${report.employee.display_name}`,
      '',
      `Extra em dia útil: ${formatMinutes(report.totals.extra_weekday_minutes)}`,
      `Extra em sábado: ${formatMinutes(report.totals.extra_saturday_minutes)}`,
      `Extra em domingo: ${formatMinutes(report.totals.extra_sunday_minutes)}`,
      `Extra em feriado: ${formatMinutes(report.totals.extra_holiday_minutes)}`,
      '',
      'Os valores não incluem cálculos de folha, adicionais ou reflexos.',
    ]
    : [
      `Olá, ${report.employee.display_name}.`,
      '',
      `A competência ${label} da sua jornada foi fechada${rectification}.`,
      'O espelho mensal segue em anexo e também está disponível em Minha Jornada.',
    ]
  return {
    to: item.recipient_email,
    subject: `${accountant ? 'Espelho de jornada' : 'Seu espelho de jornada'} ${label} — ${report.employer.legal_name}${rectification}`,
    text: lines.join('\n'),
    attachments: [{ filename: `jornada-${report.competencia}-v${item.version}.pdf`, content: base64(pdf) }],
  }
}

export function renderNotification(item: ClaimedNotification): OutgoingEmail {
  const payload = item.payload
  const what = TYPE_LABELS[payload.exception_type ?? ''] ?? 'registro'
  const when = payload.all_day
    ? shortDate(payload.event_date)
    : `${shortDate(payload.start_local ?? undefined)} ${payload.start_local?.slice(11, 16) ?? ''}–${payload.end_local?.slice(11, 16) ?? ''}`.trim()
  const decision = payload.decision === 'APPROVED' ? 'aprovada' : payload.decision === 'REJECTED' ? 'rejeitada' : ''
  const body: Record<ClaimedNotification['event_kind'], string> = {
    RECORD_COMPLETED: `Recebemos o seu registro de ${what}: ${when}.`,
    OWNER_OCCURRENCE: `Foi registrada uma ocorrência de ${what} na sua jornada: ${when}. Você pode dar ciência ou contestar em Minha Jornada.`,
    CORRECTION_REVIEWED: `Sua solicitação de correção do registro de ${what} (${when}) foi ${decision}.`,
    OWNER_CONTESTED: `O registro de ${what} (${when}) foi contestado. Veja os detalhes e responda em Minha Jornada.`,
  }
  return {
    to: item.recipient_email,
    subject: `${RECEIPT_SUBJECTS[item.event_kind]} — ${item.employer_legal_name}`,
    text: [`Olá, ${item.employee_display_name}.`, '', body[item.event_kind]].join('\n'),
  }
}

export async function runWorkforceDeliveryCycle(deps: DeliveryDeps) {
  const cycle = await deps.runCycle()
  const summary = {
    closed_periods: cycle.closed_periods,
    blocked_periods: cycle.blocked_periods,
    deliveries_sent: 0,
    deliveries_failed: 0,
    notifications_sent: 0,
    notifications_failed: 0,
  }
  for (const item of cycle.deliveries) {
    try {
      const providerId = await deps.send(renderDelivery(item), item.idempotency_key)
      await deps.recordResult('DELIVERY', item.delivery_id, true, providerId, null)
      summary.deliveries_sent++
    } catch (error) {
      await deps.recordResult('DELIVERY', item.delivery_id, false, null, errorCode(error))
      summary.deliveries_failed++
    }
  }
  for (const item of cycle.notifications) {
    try {
      const providerId = await deps.send(renderNotification(item), item.idempotency_key)
      await deps.recordResult('NOTIFICATION', item.notification_id, true, providerId, null)
      summary.notifications_sent++
    } catch (error) {
      await deps.recordResult('NOTIFICATION', item.notification_id, false, null, errorCode(error))
      summary.notifications_failed++
    }
  }
  return summary
}
