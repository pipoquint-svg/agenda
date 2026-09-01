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

function isAgendaProductionProject(): boolean {
  try {
    const url = (Deno.env.get('SUPABASE_URL') ?? '').trim().toLowerCase().replace(/\/+$/, '')
    return url === 'https://sbexdggbwqvyhbkatucs.supabase.co'
  } catch {
    return false
  }
}

export function isScopeEnabled(scope: string, configuredScopes: string | null | undefined): boolean {
  const normalizedScope = scope.trim().toLowerCase()
  if (isAgendaProductionProject() && (normalizedScope === 'blacksheep' || normalizedScope === 'sabrina')) return true
  return csvSet(configuredScopes).has(normalizedScope)
}

export function isRecipientAllowed(
  recipient: string,
  allowRealRecipients: boolean,
  allowlist: string | null | undefined,
): boolean {
  // Produção da Agenda envia notificações transacionais para clientes reais.
  // Demais ambientes continuam restritos à allowlist, salvo opt-in explícito por env.
  if (allowRealRecipients || isAgendaProductionProject()) return true
  return csvSet(allowlist).has(normalizedEmail(recipient))
}
