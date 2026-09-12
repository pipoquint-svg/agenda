export type GestationalRecommendationMode = 'GESTATIONAL_29_32' | 'NEARBY_AFTER_32'

export type GestationalAge = {
  totalDays: number
  weeks: number
  days: number
}

export type GestationalRecommendationWindow = {
  mode: GestationalRecommendationMode
  startDate: string
  endDate: string
  currentAge: GestationalAge
}

const DAY_MS = 24 * 60 * 60 * 1000
const FULL_TERM_DAYS = 40 * 7
const WEEK_29_DAYS = 29 * 7
const WEEK_32_DAYS = 32 * 7
const MAX_SUPPORTED_GESTATIONAL_DAYS = 42 * 7

function parseLocalDate(value: string): Date {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) throw new Error('DATE_INVALID')
  const date = new Date(`${value}T00:00:00.000Z`)
  if (Number.isNaN(date.getTime()) || formatLocalDate(date) !== value) throw new Error('DATE_INVALID')
  return date
}

function formatLocalDate(date: Date): string {
  return date.toISOString().slice(0, 10)
}

function differenceInDays(later: Date, earlier: Date): number {
  return Math.round((later.getTime() - earlier.getTime()) / DAY_MS)
}

function addDays(value: string, days: number): string {
  const date = parseLocalDate(value)
  date.setUTCDate(date.getUTCDate() + days)
  return formatLocalDate(date)
}

function maxDate(left: string, right: string): string {
  return left >= right ? left : right
}

export function gestationalAgeOn(dpp: string, localDate: string): GestationalAge {
  const dppDate = parseLocalDate(dpp)
  const targetDate = parseLocalDate(localDate)
  const totalDays = FULL_TERM_DAYS - differenceInDays(dppDate, targetDate)
  return {
    totalDays,
    weeks: Math.floor(totalDays / 7),
    days: ((totalDays % 7) + 7) % 7,
  }
}

export function resolveGestationalRecommendationWindow(
  dpp: string,
  today: string,
): GestationalRecommendationWindow {
  const currentAge = gestationalAgeOn(dpp, today)
  if (currentAge.totalDays < 0 || currentAge.totalDays > MAX_SUPPORTED_GESTATIONAL_DAYS) {
    throw new Error('DPP_OUT_OF_RANGE')
  }

  if (currentAge.totalDays < WEEK_32_DAYS) {
    const week29Start = addDays(dpp, -(FULL_TERM_DAYS - WEEK_29_DAYS))
    const week31End = addDays(dpp, -(FULL_TERM_DAYS - (WEEK_32_DAYS - 1)))
    return {
      mode: 'GESTATIONAL_29_32',
      startDate: maxDate(today, week29Start),
      endDate: week31End,
      currentAge,
    }
  }

  const todayDate = parseLocalDate(today)
  const weekday = todayDate.getUTCDay()
  const daysSinceMonday = (weekday + 6) % 7
  const monday = addDays(today, -daysSinceMonday)

  return {
    mode: 'NEARBY_AFTER_32',
    startDate: today,
    endDate: addDays(monday, 13),
    currentAge,
  }
}

export function gestationalAgeLabel(age: GestationalAge): string {
  return age.days === 0
    ? `${age.weeks} semanas`
    : `${age.weeks} semanas + ${age.days} ${age.days === 1 ? 'dia' : 'dias'}`
}

export function resolveNextAvailableFallbackWindow(today: string): { startDate: string; endDate: string } {
  parseLocalDate(today)
  return { startDate: today, endDate: addDays(today, 62) }
}
