import { useEffect, useMemo, useState } from 'react'
import type { BookingService, BookingSlot, ExtraSelection } from './bookingApi'
import {
  gestationalAgeLabel,
  gestationalAgeOn,
  resolveGestationalRecommendationWindow,
  resolveNextAvailableFallbackWindow,
  type GestationalRecommendationWindow,
} from './gestationalRecommendation'
import { listBookingSlotsRange, type BookingSlotInRange } from './recommendedSlotsApi'
import { SabrinaAvailabilityCalendar } from './SabrinaAvailabilityCalendar'

const clock = new Intl.DateTimeFormat('pt-BR', {
  hour: '2-digit',
  minute: '2-digit',
  timeZone: 'America/Sao_Paulo',
})

function formatDate(value: string): string {
  const [year, month, day] = value.split('-')
  return year && month && day ? `${day}/${month}/${year}` : value
}

function saoPauloToday(): string {
  const parts = new Intl.DateTimeFormat('en-US', {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    timeZone: 'America/Sao_Paulo',
  }).formatToParts(new Date())
  const value = Object.fromEntries(parts.map((part) => [part.type, part.value]))
  return `${value.year}-${value.month}-${value.day}`
}

function recommendationCopy(window: GestationalRecommendationWindow | null, fallback: boolean): string {
  if (fallback) return 'Não encontramos horários nessa janela, mas estes são os próximos disponíveis.'
  if (!window) return ''
  if (window.mode === 'NEARBY_AFTER_32') {
    return 'Vamos encontrar uma data mais próxima para você. ❤️ Separamos primeiro os horários disponíveis para esta semana e para a próxima.'
  }
  if (window.currentAge.totalDays < 29 * 7) {
    return 'Uma fase muito bonita para fotografar — separamos alguns horários para quando você estiver entre 29 e 32 semanas.'
  }
  return 'Separamos os próximos horários disponíveis antes de você completar 32 semanas.'
}

export function GestationalDatePicker({
  pageSlug,
  service,
  serviceEmployeeId,
  extras,
  probeKey,
  dpp,
  date,
  slots,
  loadingSlots,
  busy,
  selectedSlot,
  loadDay,
  onSelectDate,
  onSelectSlot,
  onDppChange,
}: {
  pageSlug: string
  service: BookingService
  serviceEmployeeId: string
  extras: ExtraSelection[]
  probeKey: string
  dpp: string
  date: string
  slots: BookingSlot[]
  loadingSlots: boolean
  busy: boolean
  selectedSlot: BookingSlot | null
  loadDay: (day: string) => Promise<{ length: number }>
  onSelectDate: (day: string) => void
  onSelectSlot: (slot: BookingSlot, localDate: string) => void
  onDppChange: (dpp: string) => void
}) {
  const today = useMemo(() => saoPauloToday(), [])
  const extrasKey = useMemo(
    () => JSON.stringify([...extras].sort((a, b) => a.extra_id.localeCompare(b.extra_id))),
    [extras],
  )
  const [recommendationWindow, setRecommendationWindow] = useState<GestationalRecommendationWindow | null>(null)
  const [recommendedSlots, setRecommendedSlots] = useState<BookingSlotInRange[]>([])
  const [loadingRecommended, setLoadingRecommended] = useState(false)
  const [recommendationFallback, setRecommendationFallback] = useState(false)
  const [recommendationError, setRecommendationError] = useState('')
  const [showCalendar, setShowCalendar] = useState(false)

  useEffect(() => {
    if (!dpp || !serviceEmployeeId) {
      setRecommendationWindow(null)
      setRecommendedSlots([])
      setRecommendationFallback(false)
      setRecommendationError('')
      return
    }

    let active = true
    let window: GestationalRecommendationWindow
    try {
      window = resolveGestationalRecommendationWindow(dpp, today)
    } catch {
      setRecommendationWindow(null)
      setRecommendedSlots([])
      setRecommendationFallback(false)
      setRecommendationError('Confira a data prevista para o parto ou veja todas as datas disponíveis.')
      return
    }

    setRecommendationWindow(window)
    setRecommendationFallback(false)
    setRecommendationError('')
    setLoadingRecommended(true)

    const query = async () => {
      const primary = await listBookingSlotsRange({
        pageSlug,
        serviceId: service.id,
        serviceEmployeeId,
        startDate: window.startDate,
        endDate: window.endDate,
        extras,
        peopleCount: service.minimum_people,
        limit: 5,
      })
      if (primary.length > 0) return { slots: primary, fallback: false }

      const fallbackWindow = resolveNextAvailableFallbackWindow(today)
      const fallbackSlots = await listBookingSlotsRange({
        pageSlug,
        serviceId: service.id,
        serviceEmployeeId,
        startDate: fallbackWindow.startDate,
        endDate: fallbackWindow.endDate,
        extras,
        peopleCount: service.minimum_people,
        limit: 5,
      })
      return { slots: fallbackSlots, fallback: true }
    }

    void query()
      .then((result) => {
        if (!active) return
        setRecommendedSlots(result.slots)
        setRecommendationFallback(result.fallback)
        if (result.slots.length === 0) setShowCalendar(true)
      })
      .catch(() => {
        if (!active) return
        setRecommendedSlots([])
        setRecommendationError('Não conseguimos carregar as sugestões agora. Você ainda pode escolher pelo calendário.')
        setShowCalendar(true)
      })
      .finally(() => {
        if (active) setLoadingRecommended(false)
      })

    return () => { active = false }
  }, [dpp, today, pageSlug, service.id, service.minimum_people, serviceEmployeeId, extrasKey])

  function changeDpp(value: string) {
    setShowCalendar(false)
    onDppChange(value)
  }

  return (
    <>
      <div className="sby-form-grid">
        <label className="sby-field sby-field-wide">
          <span>Data prevista para o parto</span>
          <input type="date" value={dpp} onChange={(event) => changeDpp(event.target.value)} />
          <small>Usamos esta data para sugerir os melhores períodos. Você continua podendo escolher qualquer outra data disponível.</small>
        </label>
      </div>

      {loadingRecommended ? <div className="sby-empty">Buscando os melhores horários para você…</div> : null}
      {recommendationError ? <div className="sby-empty">{recommendationError}</div> : null}

      {recommendedSlots.length > 0 ? (
        <div className="sby-time-section">
          <div className="sby-time-head">
            <strong>Próximos horários recomendados</strong>
            <small>{recommendationCopy(recommendationWindow, recommendationFallback)}</small>
          </div>
          <div className="sby-time-grid">
            {recommendedSlots.map((slot) => {
              const age = gestationalAgeOn(dpp, slot.local_date)
              const selected = selectedSlot?.slot_start_at === slot.slot_start_at
              return (
                <button
                  type="button"
                  key={slot.slot_start_at}
                  disabled={busy}
                  className={selected ? 'selected' : ''}
                  onClick={() => onSelectSlot(slot, slot.local_date)}
                >
                  <strong>{formatDate(slot.local_date)} · {clock.format(new Date(slot.slot_start_at))}</strong>
                  <small>{gestationalAgeLabel(age)} · até {clock.format(new Date(slot.slot_end_at))}</small>
                </button>
              )
            })}
          </div>
        </div>
      ) : null}

      <div className="sby-actions end">
        <button type="button" className="sby-secondary" onClick={() => setShowCalendar((current) => !current)}>
          {showCalendar ? 'Ocultar calendário' : 'Ver todas as datas disponíveis'}
        </button>
      </div>

      {showCalendar ? (
        <>
          <SabrinaAvailabilityCalendar
            probeKey={probeKey}
            value={date}
            onSelectDate={onSelectDate}
            loadDay={loadDay}
          />
          {date ? (
            <div className="sby-time-section">
              <div className="sby-time-head">
                <strong>{formatDate(date)}</strong>
                <small>{loadingSlots ? 'Buscando horários…' : `${slots.length} horário${slots.length === 1 ? '' : 's'} ${slots.length === 1 ? 'disponível' : 'disponíveis'}`}</small>
              </div>
              <div className="sby-time-grid">
                {slots.map((slot) => (
                  <button
                    type="button"
                    key={slot.slot_start_at}
                    disabled={busy}
                    className={selectedSlot?.slot_start_at === slot.slot_start_at ? 'selected' : ''}
                    onClick={() => onSelectSlot(slot, date)}
                  >
                    <strong>{clock.format(new Date(slot.slot_start_at))}</strong>
                    <small>{busy && selectedSlot?.slot_start_at === slot.slot_start_at ? 'protegendo…' : `até ${clock.format(new Date(slot.slot_end_at))}`}</small>
                  </button>
                ))}
              </div>
            </div>
          ) : null}
        </>
      ) : null}
    </>
  )
}
