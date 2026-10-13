/**
 * Recuperação do hold tardio após refresh/restauração da aba.
 *
 * O hold só existe depois que o cliente entra na etapa de dados. Guardamos no
 * sessionStorage (escopo da aba) apenas o token opaco, o `expires_at` do
 * servidor e a seleção protegida - nunca dados pessoais. Ao restaurar, o token é
 * revalidado no backend e o prazo original é mantido (nunca renovado).
 */

function storage(): Storage | null {
  try {
    return typeof window !== 'undefined' ? window.sessionStorage : null
  } catch {
    return null
  }
}

export function readHoldSession<T extends { v: number }>(key: string, version: number): T | null {
  let raw: string | null = null
  try {
    raw = storage()?.getItem(key) ?? null
  } catch {
    return null
  }
  if (!raw) return null
  try {
    const parsed = JSON.parse(raw) as T
    if (!parsed || typeof parsed !== 'object' || parsed.v !== version) throw new Error('invalid')
    return parsed
  } catch {
    clearHoldSession(key)
    return null
  }
}

export function writeHoldSession(key: string, value: unknown): void {
  try {
    storage()?.setItem(key, JSON.stringify(value))
  } catch {
    /* Armazenamento indisponível: o hold continua válido no backend. */
  }
}

export function clearHoldSession(key: string): void {
  try {
    storage()?.removeItem(key)
  } catch {
    /* noop */
  }
}

/** O relógio local só decide apresentação; o backend revalida o token. */
export function holdLocallyExpired(expiresAt: string | null | undefined, now = Date.now()): boolean {
  if (!expiresAt) return true
  const value = new Date(expiresAt).getTime()
  return !Number.isFinite(value) || value <= now
}

export function isSlotTakenError(cause: unknown): boolean {
  const message = cause instanceof Error ? cause.message : ''
  return /SLOT_NO_LONGER_AVAILABLE|SLOT_NOT_AVAILABLE|RESOURCE_NOT_AVAILABLE|HOLD_SELECTION_REQUIRES_NEW_SLOT/.test(message)
}

export function isHoldGoneError(cause: unknown): boolean {
  const message = cause instanceof Error ? cause.message : ''
  return /CHECKOUT_HOLD_NOT_ACTIVE|HOLD_EXPIRED|CHECKOUT_HOLD_NOT_FOUND|HOLD_NOT_FOUND/.test(message)
}

export const SLOT_TAKEN_MESSAGE = 'Este horário acabou de ser reservado por outra pessoa. Escolha outro horário para continuar.'
export const HOLD_EXPIRED_DATA_MESSAGE = 'O prazo de 10 minutos terminou e o horário deixou de estar reservado. Seus dados foram mantidos. Continue para confirmar a disponibilidade novamente.'
