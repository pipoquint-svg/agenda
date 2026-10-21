/** Duração em horas para mensagens: 120 → "2h", 90 → "1h30", 45 → "45 min". */
export function durationLabel(minutes: unknown): string {
  const total = Math.max(0, Math.round(Number(minutes) || 0))
  if (total < 60) return `${total} min`
  const hours = Math.floor(total / 60)
  const rest = total % 60
  return rest ? `${hours}h${String(rest).padStart(2, '0')}` : `${hours}h`
}
