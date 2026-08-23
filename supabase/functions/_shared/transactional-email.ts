export type ConfirmationEmailInput = {
  brandName: string
  customerName: string
  serviceName: string
  startAt: string
  durationMinutes: number
  publicCode: string
  totalValue: number
  paidValue: number
  balanceValue: number
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;')
}

function money(value: number): string {
  return new Intl.NumberFormat('pt-BR', {
    style: 'currency',
    currency: 'BRL',
  }).format(Number.isFinite(value) ? value : 0)
}

function dateTime(value: string): string {
  const parsed = new Date(value)
  if (Number.isNaN(parsed.getTime())) return value
  return new Intl.DateTimeFormat('pt-BR', {
    dateStyle: 'full',
    timeStyle: 'short',
    timeZone: 'America/Sao_Paulo',
  }).format(parsed)
}

export function normalizedEmail(value: string | null | undefined): string {
  return (value ?? '').trim().toLowerCase()
}

export function maskEmail(value: string): string {
  const email = normalizedEmail(value)
  const at = email.lastIndexOf('@')
  if (at <= 0 || at === email.length - 1) return '***'
  const local = email.slice(0, at)
  const domain = email.slice(at + 1)
  return `${local.slice(0, 1)}***@${domain}`
}

export function csvSet(value: string | null | undefined): Set<string> {
  return new Set(
    (value ?? '')
      .split(',')
      .map((item) => item.trim().toLowerCase())
      .filter(Boolean),
  )
}

export function isScopeEnabled(scope: string, configuredScopes: string | null | undefined): boolean {
  return csvSet(configuredScopes).has(scope.trim().toLowerCase())
}

export function isRecipientAllowed(
  recipient: string,
  allowRealRecipients: boolean,
  allowlist: string | null | undefined,
): boolean {
  if (allowRealRecipients) return true
  return csvSet(allowlist).has(normalizedEmail(recipient))
}

export function buildConfirmationEmail(input: ConfirmationEmailInput): {
  subject: string
  text: string
  html: string
} {
  const brandName = input.brandName.trim() || 'Agenda'
  const customerName = input.customerName.trim() || 'Cliente'
  const serviceName = input.serviceName.trim() || 'Reserva'
  const start = dateTime(input.startAt)
  const duration = `${Math.max(0, Math.round(input.durationMinutes || 0))} min`
  const total = money(input.totalValue)
  const paid = money(input.paidValue)
  const balance = money(input.balanceValue)
  const code = input.publicCode.trim()

  const subject = `${brandName} | Reserva confirmada | ${code}`
  const lines = [
    `Olá, ${customerName}.`,
    '',
    'Sua reserva está confirmada.',
    '',
    `Serviço: ${serviceName}`,
    `Data e horário: ${start}`,
    `Duração: ${duration}`,
    `Código da reserva: ${code}`,
    `Valor da reserva: ${total}`,
    `Valor pago: ${paid}`,
    `Saldo: ${balance}`,
    '',
    'Se precisar de ajuda ou alteração, use os canais oficiais de atendimento.',
    '',
    `Equipe ${brandName}`,
  ]

  const htmlRows = [
    ['Serviço', serviceName],
    ['Data e horário', start],
    ['Duração', duration],
    ['Código da reserva', code],
    ['Valor da reserva', total],
    ['Valor pago', paid],
    ['Saldo', balance],
  ].map(([label, value]) => `
    <tr>
      <td style="padding:6px 12px 6px 0;color:#666;vertical-align:top">${escapeHtml(label)}</td>
      <td style="padding:6px 0;font-weight:600">${escapeHtml(value)}</td>
    </tr>`).join('')

  const html = `<!doctype html>
<html lang="pt-BR">
  <body style="margin:0;background:#f5f5f5;font-family:Arial,Helvetica,sans-serif;color:#171717">
    <div style="max-width:620px;margin:0 auto;padding:28px 16px">
      <div style="background:#fff;border-radius:14px;padding:28px">
        <h1 style="font-size:22px;margin:0 0 18px">Reserva confirmada</h1>
        <p style="margin:0 0 18px">Olá, ${escapeHtml(customerName)}.</p>
        <p style="margin:0 0 20px">Sua reserva na ${escapeHtml(brandName)} está confirmada.</p>
        <table role="presentation" style="border-collapse:collapse;width:100%;font-size:15px">${htmlRows}</table>
        <p style="margin:24px 0 0;color:#555;font-size:14px">Se precisar de ajuda ou alteração, use os canais oficiais de atendimento.</p>
        <p style="margin:18px 0 0;font-size:14px">Equipe ${escapeHtml(brandName)}</p>
      </div>
    </div>
  </body>
</html>`

  return { subject, text: lines.join('\n'), html }
}
