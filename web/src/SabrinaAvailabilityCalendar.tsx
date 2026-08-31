import { useEffect, useMemo, useRef, useState } from 'react'

type DayStatus = 'loading' | 'available' | 'empty' | 'error'

type Props = {
  probeKey: string
  value: string
  onSelectDate: (date: string) => void
  loadDay: (date: string) => Promise<{ length: number }>
  horizonDays?: number
  concurrency?: number
}

const WEEKDAYS = ['D', 'S', 'T', 'Q', 'Q', 'S', 'S']
const pad = (value: number) => String(value).padStart(2, '0')
const isoOf = (date: Date) => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`

function startOfToday(): Date {
  const now = new Date()
  return new Date(now.getFullYear(), now.getMonth(), now.getDate())
}

function monthLabel(year: number, month: number): string {
  const name = new Date(year, month, 1).toLocaleDateString('pt-BR', { month: 'long' })
  return `${name.charAt(0).toUpperCase()}${name.slice(1)} ${year}`
}

export function SabrinaAvailabilityCalendar({
  probeKey,
  value,
  onSelectDate,
  loadDay,
  horizonDays = 120,
  concurrency = 4,
}: Props) {
  const today = useMemo(startOfToday, [])
  const [cursor, setCursor] = useState(() => ({ year: today.getFullYear(), month: today.getMonth() }))
  const [statuses, setStatuses] = useState<Record<string, DayStatus>>({})
  const [probing, setProbing] = useState(false)
  const cacheRef = useRef<Record<string, Record<string, DayStatus>>>({})
  const loadDayRef = useRef(loadDay)
  loadDayRef.current = loadDay

  const horizonEnd = useMemo(() => {
    const end = new Date(today)
    end.setDate(end.getDate() + horizonDays)
    return end
  }, [today, horizonDays])

  const days = useMemo(() => {
    const first = new Date(cursor.year, cursor.month, 1)
    const total = new Date(cursor.year, cursor.month + 1, 0).getDate()
    const cells: Array<Date | null> = Array.from({ length: first.getDay() }, () => null)
    for (let day = 1; day <= total; day += 1) cells.push(new Date(cursor.year, cursor.month, day))
    return cells
  }, [cursor])

  const probeDates = useMemo(
    () => days
      .filter((day): day is Date => Boolean(day) && day! >= today && day! <= horizonEnd)
      .map(isoOf),
    [days, today, horizonEnd],
  )

  useEffect(() => {
    setStatuses({ ...(cacheRef.current[probeKey] ?? {}) })
  }, [probeKey])

  useEffect(() => {
    if (!probeKey || probeDates.length === 0) return

    let cancelled = false
    const cache = (cacheRef.current[probeKey] = cacheRef.current[probeKey] ?? {})
    const pending = probeDates.filter((date) => !cache[date])
    if (pending.length === 0) {
      setStatuses({ ...cache })
      return
    }

    pending.forEach((date) => { cache[date] = 'loading' })
    setStatuses({ ...cache })
    setProbing(true)

    let index = 0
    const worker = async () => {
      while (!cancelled) {
        const date = pending[index]
        index += 1
        if (!date) return
        try {
          const result = await loadDayRef.current(date)
          if (!cancelled) {
            cache[date] = result.length > 0 ? 'available' : 'empty'
            setStatuses({ ...cache })
          }
        } catch {
          if (!cancelled) {
            cache[date] = 'error'
            setStatuses({ ...cache })
          }
        }
      }
    }

    void Promise.all(Array.from({ length: Math.max(1, concurrency) }, worker)).finally(() => {
      if (!cancelled) setProbing(false)
    })

    return () => { cancelled = true }
  }, [probeKey, probeDates, concurrency])

  const canGoBack = cursor.year > today.getFullYear()
    || (cursor.year === today.getFullYear() && cursor.month > today.getMonth())
  const canGoForward = new Date(cursor.year, cursor.month + 1, 1) <= horizonEnd

  function move(delta: number) {
    setCursor((current) => {
      const next = new Date(current.year, current.month + delta, 1)
      return { year: next.getFullYear(), month: next.getMonth() }
    })
  }

  return (
    <section className="sby-calendar" aria-label="Calendário de disponibilidade">
      <header className="sby-calendar-head">
        <button type="button" aria-label="Mês anterior" disabled={!canGoBack} onClick={() => move(-1)}>‹</button>
        <strong>{monthLabel(cursor.year, cursor.month)}</strong>
        <button type="button" aria-label="Próximo mês" disabled={!canGoForward} onClick={() => move(1)}>›</button>
      </header>

      <div className="sby-calendar-weekdays" aria-hidden="true">
        {WEEKDAYS.map((label, index) => <span key={`${label}-${index}`}>{label}</span>)}
      </div>

      <div className="sby-calendar-grid" role="grid">
        {days.map((day, index) => {
          if (!day) return <span key={`empty-${index}`} className="sby-calendar-blank" aria-hidden="true" />
          const iso = isoOf(day)
          const outsideWindow = day < today || day > horizonEnd
          const status = outsideWindow ? 'empty' : statuses[iso]
          const available = status === 'available'
          const selected = available && value === iso
          return (
            <button
              key={iso}
              type="button"
              role="gridcell"
              disabled={!available}
              aria-pressed={selected}
              aria-label={`${day.getDate()} de ${monthLabel(day.getFullYear(), day.getMonth())}: ${available ? 'disponível' : 'indisponível'}`}
              className={`sby-calendar-day ${selected ? 'selected' : ''} ${available ? 'available' : ''}`}
              onClick={() => onSelectDate(iso)}
            >
              {status === 'loading' ? <span className="sby-spinner" aria-label="Verificando" /> : day.getDate()}
            </button>
          )
        })}
      </div>

      <p className="sby-calendar-status" aria-live="polite">
        {probing ? 'Verificando disponibilidade no mês…' : ''}
      </p>
    </section>
  )
}
