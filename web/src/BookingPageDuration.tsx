import { useEffect, useMemo, useState } from 'react'
import type { BookingQuote, BookingSlot, CheckoutHold, ExtraSelection } from './bookingApi'
import {
  contractedMinutes,
  createDurationBookingHold,
  durationBasePrice,
  durationUnitPrice,
  initialDurationBlocks,
  listDurationBookingSlots,
  loadDurationBookingPage,
  quoteDurationBooking,
  startingPrice,
  type DurationBookingPageData,
  type DurationBookingService,
} from './bookingDurationApi'
import './booking.css'
import './durationRecommendations.css'

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })
const time = new Intl.DateTimeFormat('pt-BR', {
  hour: '2-digit',
  minute: '2-digit',
  timeZone: 'America/Sao_Paulo',
})

function todayLocal(): string {
  const now = new Date()
  const y = now.getFullYear()
  const m = String(now.getMonth() + 1).padStart(2, '0')
  const d = String(now.getDate()).padStart(2, '0')
  return `${y}-${m}-${d}`
}

function numeric(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function durationLabel(minutes: number): string {
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  if (hours === 0) return `${rest} min`
  if (rest === 0) return `${hours}h`
  return `${hours}h${String(rest).padStart(2, '0')}`
}

function timeRange(startAt: string, endAt: string): string {
  return `${time.format(new Date(startAt))} às ${time.format(new Date(endAt))}`
}

function secondsLabel(total: number): string {
  const safe = Math.max(0, total)
  return `${String(Math.floor(safe / 60)).padStart(2, '0')}:${String(safe % 60).padStart(2, '0')}`
}

function readableError(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'Não foi possível concluir esta etapa.'
  const known: Array<[string, string]> = [
    ['INVALID_CONTRACTED_MINUTES', 'Escolha uma duração válida para a locação.'],
    ['INVALID_DURATION_BLOCKS', 'Escolha uma duração válida para a locação.'],
    ['AMBIGUOUS_DURATION_CONTRACT', 'Esta página foi atualizada. Recarregue e escolha o horário novamente.'],
    ['DURATION_BLOCKS_NOT_ALLOWED', 'Este serviço possui duração fixa.'],
    ['SLOT_NO_LONGER_AVAILABLE', 'Este horário acabou de ser reservado por outra pessoa. Escolha outro horário.'],
    ['REQUIRED_EXTRA_MISSING', 'Revise os adicionais obrigatórios antes de continuar.'],
    ['INVALID_PEOPLE_COUNT', 'A quantidade de pessoas não é válida para este serviço.'],
    ['PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE', 'Este serviço não está disponível nesta página.'],
    ['EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE', 'O profissional selecionado não está disponível para este serviço.'],
    ['INVALID_EXTRA', 'Um dos adicionais selecionados não está disponível para este serviço.'],
  ]
  return known.find(([key]) => raw.includes(key))?.[1] ?? 'Não foi possível concluir esta etapa. Tente novamente.'
}

function selectedExtras(service: DurationBookingService | null, quantities: Record<string, number>): ExtraSelection[] {
  if (!service) return []
  return service.extras
    .map((extra) => ({ extra_id: extra.id, quantity: quantities[extra.id] ?? 0 }))
    .filter((selection) => selection.quantity > 0)
}

function hourlyBasePrice(service: DurationBookingService, blocks: number): number {
  const blockMinutes = service.booking_block_minutes ?? 30
  if (blockMinutes <= 0) return 0
  return durationUnitPrice(service, blocks) * (60 / blockMinutes)
}

export function BookingPageDuration({ slug }: { slug: string }) {
  const [page, setPage] = useState<DurationBookingPageData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [serviceId, setServiceId] = useState('')
  const [employeeRelationId, setEmployeeRelationId] = useState('')
  const [durationBlocks, setDurationBlocks] = useState<number | null>(null)
  const [extraQuantities, setExtraQuantities] = useState<Record<string, number>>({})
  const [peopleCount, setPeopleCount] = useState(1)
  const [localDate, setLocalDate] = useState('')
  const [quote, setQuote] = useState<BookingQuote | null>(null)
  const [slots, setSlots] = useState<BookingSlot[]>([])
  const [searchingSlots, setSearchingSlots] = useState(false)
  const [creatingHold, setCreatingHold] = useState<string | null>(null)
  const [hold, setHold] = useState<(CheckoutHold & { contracted_minutes?: number }) | null>(null)
  const [remainingSeconds, setRemainingSeconds] = useState(0)
  const [holdExpired, setHoldExpired] = useState(false)

  const service = useMemo(
    () => page?.services.find((item) => item.id === serviceId) ?? null,
    [page, serviceId],
  )
  const extras = useMemo(() => selectedExtras(service, extraQuantities), [service, extraQuantities])
  const selectedContractedMinutes = useMemo(
    () => service ? contractedMinutes(service, durationBlocks) : 0,
    [service, durationBlocks],
  )

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    loadDurationBookingPage(slug)
      .then((data) => {
        if (!active) return
        setPage(data)
        if (!data) setError('Esta página de reservas não está disponível.')
      })
      .catch((cause) => active && setError(readableError(cause)))
      .finally(() => active && setLoading(false))
    return () => { active = false }
  }, [slug])

  useEffect(() => {
    if (!service || !employeeRelationId || selectedContractedMinutes <= 0) {
      setQuote(null)
      return
    }
    let active = true
    quoteDurationBooking({
      pageSlug: slug,
      service,
      serviceEmployeeId: employeeRelationId,
      contractedMinutes: selectedContractedMinutes,
      extras,
      peopleCount,
    })
      .then((next) => active && setQuote(next))
      .catch(() => active && setQuote(null))
    return () => { active = false }
  }, [selectedContractedMinutes, employeeRelationId, extras, peopleCount, service, slug])

  useEffect(() => {
    if (!hold) {
      setRemainingSeconds(0)
      return
    }
    const tick = () => {
      const seconds = Math.max(0, Math.ceil((new Date(hold.expires_at).getTime() - Date.now()) / 1000))
      setRemainingSeconds(seconds)
      if (seconds === 0) {
        sessionStorage.removeItem('bs_checkout_hold')
        setHold(null)
        setHoldExpired(true)
      }
    }
    tick()
    const timer = window.setInterval(tick, 1000)
    return () => window.clearInterval(timer)
  }, [hold])

  function resetAvailability() {
    setLocalDate('')
    setSlots([])
    setHold(null)
    setHoldExpired(false)
  }

  function chooseService(nextId: string) {
    const next = page?.services.find((item) => item.id === nextId) ?? null
    setServiceId(nextId)
    setEmployeeRelationId(next?.employees.length === 1 ? next.employees[0].service_employee_id : '')
    setDurationBlocks(initialDurationBlocks(next))
    setPeopleCount(next?.minimum_people ?? 1)
    setExtraQuantities(Object.fromEntries(
      (next?.extras ?? []).filter((extra) => extra.is_required).map((extra) => [extra.id, 1]),
    ))
    resetAvailability()
    setQuote(null)
    setError(null)
  }

  function changeDuration(next: number) {
    setDurationBlocks(next)
    resetAvailability()
  }

  function changeExtra(extraId: string, quantity: number) {
    setExtraQuantities((current) => ({ ...current, [extraId]: quantity }))
    resetAvailability()
  }

  async function searchSlots() {
    if (!service || !employeeRelationId || !localDate || selectedContractedMinutes <= 0) return
    setSearchingSlots(true)
    setError(null)
    setHoldExpired(false)
    try {
      const result = await listDurationBookingSlots({
        pageSlug: slug,
        service,
        serviceEmployeeId: employeeRelationId,
        contractedMinutes: selectedContractedMinutes,
        extras,
        peopleCount,
        localDate,
      })
      setSlots(result)
    } catch (cause) {
      setSlots([])
      setError(readableError(cause))
    } finally {
      setSearchingSlots(false)
    }
  }

  async function protectSlot(slot: BookingSlot) {
    if (!service || !employeeRelationId || selectedContractedMinutes <= 0) return
    setCreatingHold(slot.slot_start_at)
    setError(null)
    try {
      const nextHold = await createDurationBookingHold({
        pageSlug: slug,
        service,
        serviceEmployeeId: employeeRelationId,
        contractedMinutes: selectedContractedMinutes,
        extras,
        peopleCount,
        requestedStartAt: slot.slot_start_at,
      })
      setHold(nextHold)
      setHoldExpired(false)
      sessionStorage.setItem('bs_checkout_hold', JSON.stringify({
        token: nextHold.checkout_hold_token,
        id: nextHold.checkout_hold_id,
        pageSlug: slug,
        serviceId: service.id,
        serviceName: service.name,
        contractedMinutes: nextHold.contracted_minutes ?? selectedContractedMinutes,
        expiresAt: nextHold.expires_at,
      }))
    } catch (cause) {
      setError(readableError(cause))
      await searchSlots()
    } finally {
      setCreatingHold(null)
    }
  }

  if (loading) return <main className="booking-shell"><div className="booking-card">Carregando horários…</div></main>
  if (!page) return <main className="booking-shell"><div className="booking-card"><h1>Agenda indisponível</h1><p>{error}</p></div></main>

  return (
    <main className={`booking-shell booking-${page.brand_key.toLowerCase()}`} style={{ '--booking-accent': page.accent_color ?? '#171717' } as React.CSSProperties}>
      <section className="booking-card">
        <header className="booking-header">
          {page.logo_url ? <img className="booking-logo" src={page.logo_url} alt={page.display_name} /> : null}
          <span className="booking-brand">{page.display_name}</span>
          <h1>{page.title}</h1>
          {page.subtitle ? <p>{page.subtitle}</p> : null}
        </header>

        {error ? <div className="form-alert error" role="alert">{error}</div> : null}
        {holdExpired ? <div className="form-alert error" role="alert">O tempo para concluir a reserva terminou e este horário voltou a ficar disponível. Escolha um novo horário.</div> : null}

        {page.services.length === 0 ? (
          <div className="booking-empty"><h2>Nenhum atendimento disponível no momento</h2></div>
        ) : (
          <div className="booking-flow">
            <section className="booking-step">
              <div className="step-title"><span>1</span><div><h2>O que você deseja reservar?</h2><p>Selecione o atendimento que deseja agendar.</p></div></div>
              <div className="service-grid">
                {page.services.map((item) => (
                  <button type="button" key={item.id} className={`service-option ${serviceId === item.id ? 'selected' : ''}`} onClick={() => chooseService(item.id)}>
                    {item.cover_image_url ? <img src={item.cover_image_url} alt="" /> : null}
                    <strong>{item.name}</strong>
                    {item.short_description ? <small>{item.short_description}</small> : null}
                    <span>A partir de {money.format(startingPrice(item))}</span>
                  </button>
                ))}
              </div>
            </section>

            {service ? (
              <>
                {service.duration_mode === 'BLOCKS' ? (
                  <section className="booking-step">
                    <div className="step-title"><span>2</span><div><h2>Quanto tempo você precisa?</h2><p>Escolha a duração da locação em intervalos de {service.booking_block_minutes ?? 30} minutos. Quanto maior o período, menor pode ficar o valor por hora.</p></div></div>

                    {service.duration_presets?.length > 0 ? (
                      <div className="duration-preset-grid" aria-label="Tempos recomendados">
                        {service.duration_presets.map((preset) => {
                          const minutes = contractedMinutes(service, preset.block_count)
                          const selected = durationBlocks === preset.block_count
                          return (
                            <button
                              type="button"
                              key={preset.id}
                              className={`duration-preset-card ${selected ? 'selected' : ''} ${preset.is_featured ? 'featured' : ''}`}
                              onClick={() => changeDuration(preset.block_count)}
                            >
                              <div className="duration-preset-topline">
                                <strong>{durationLabel(minutes)}</strong>
                                {preset.badge ? <span>{preset.badge}</span> : null}
                              </div>
                              <h3>{preset.title}</h3>
                              {preset.description ? <p>{preset.description}</p> : null}
                              <div className="duration-preset-price">
                                <strong>{money.format(durationBasePrice(service, preset.block_count))}</strong>
                                <small>{money.format(hourlyBasePrice(service, preset.block_count))}/h</small>
                              </div>
                            </button>
                          )
                        })}
                      </div>
                    ) : null}

                    <div className="duration-custom-row">
                      <label>
                        <span>Duração</span>
                        <select className="people-select" value={durationBlocks ?? ''} onChange={(event) => changeDuration(Number(event.target.value))}>
                          {Array.from({ length: (service.maximum_booking_blocks ?? 1) - (service.minimum_booking_blocks ?? 1) + 1 }, (_, index) => (service.minimum_booking_blocks ?? 1) + index)
                            .map((blocks) => {
                              const minutes = (service.booking_block_minutes ?? 30) * blocks
                              return <option key={blocks} value={blocks}>{durationLabel(minutes)}</option>
                            })}
                        </select>
                      </label>
                      {durationBlocks ? (
                        <div className="duration-live-price" aria-live="polite">
                          <small>Locação de {durationLabel(selectedContractedMinutes)}</small>
                          <strong>{money.format(durationBasePrice(service, durationBlocks))}</strong>
                          <span>{money.format(hourlyBasePrice(service, durationBlocks))}/h</span>
                        </div>
                      ) : null}
                    </div>
                  </section>
                ) : null}

                {service.employees.length > 1 ? (
                  <section className="booking-step">
                    <div className="step-title"><span>•</span><div><h2>Escolha o profissional</h2><p>Escolha quem realizará o atendimento.</p></div></div>
                    <div className="choice-row">
                      {service.employees.map((employee) => (
                        <button type="button" className={`choice-pill ${employeeRelationId === employee.service_employee_id ? 'selected' : ''}`} key={employee.service_employee_id} onClick={() => { setEmployeeRelationId(employee.service_employee_id); resetAvailability() }}>{employee.name}</button>
                      ))}
                    </div>
                  </section>
                ) : null}

                {service.extras.length > 0 ? (
                  <section className="booking-step">
                    <div className="step-title"><span>•</span><div><h2>Adicionais</h2><p>Personalize o atendimento antes de escolher a data.</p></div></div>
                    <div className="extras-list">
                      {service.extras.map((extra) => {
                        const quantity = extraQuantities[extra.id] ?? 0
                        return (
                          <div className="extra-row" key={extra.id}>
                            <div>
                              <strong>{extra.name}{extra.is_required ? ' · incluído na reserva' : ''}</strong>
                              {extra.description ? <small>{extra.description}</small> : null}
                              <span>+ {money.format(numeric(extra.price))}</span>
                              {extra.schedule_placement === 'PREPEND' && (extra.default_schedule_minutes ?? 0) > 0 ? <small>Com este adicional, seu atendimento começa mais cedo. O horário mostrado já considera sua chegada.</small> : null}
                            </div>
                            {extra.is_required ? <span className="required-badge">Incluído</span> : extra.max_quantity === 1 ? (
                              <label className="toggle-extra"><input type="checkbox" checked={quantity > 0} onChange={(event) => changeExtra(extra.id, event.target.checked ? 1 : 0)} /><span>{quantity > 0 ? 'Selecionado' : 'Adicionar'}</span></label>
                            ) : (
                              <select value={quantity} onChange={(event) => changeExtra(extra.id, Number(event.target.value))}>{Array.from({ length: extra.max_quantity + 1 }, (_, index) => <option value={index} key={index}>{index}</option>)}</select>
                            )}
                          </div>
                        )
                      })}
                    </div>
                  </section>
                ) : null}

                <section className="booking-step">
                  <div className="step-title"><span>•</span><div><h2>Quantas pessoas participarão?</h2><p>A quantidade pode alterar disponibilidade e valor.</p></div></div>
                  {service.minimum_people === service.maximum_people ? <p className="fixed-people">{service.minimum_people} {service.minimum_people === 1 ? 'pessoa' : 'pessoas'}</p> : (
                    <select className="people-select" value={peopleCount} onChange={(event) => { setPeopleCount(Number(event.target.value)); resetAvailability() }}>
                      {Array.from({ length: service.maximum_people - service.minimum_people + 1 }, (_, index) => service.minimum_people + index).map((value) => <option key={value} value={value}>{value} {value === 1 ? 'pessoa' : 'pessoas'}</option>)}
                    </select>
                  )}
                </section>

                <section className="booking-step">
                  <div className="step-title"><span>•</span><div><h2>Data e horário</h2><p>Mostramos somente os horários realmente disponíveis para sua reserva.</p></div></div>
                  <div className="date-search">
                    <label>Data<input type="date" min={todayLocal()} value={localDate} onChange={(event) => { setLocalDate(event.target.value); setSlots([]) }} /></label>
                    <button className="primary" type="button" onClick={searchSlots} disabled={!localDate || !employeeRelationId || searchingSlots}>{searchingSlots ? 'Buscando horários…' : 'Buscar horários'}</button>
                  </div>

                  {slots.length > 0 ? (
                    <div className="slots-grid" aria-label="Horários disponíveis">
                      {slots.map((slot) => {
                        const hasEarlierArrival = slot.slot_start_at !== slot.core_start_at
                        return (
                          <button type="button" className="slot-option" key={slot.slot_start_at} disabled={creatingHold !== null || hold !== null} onClick={() => protectSlot(slot)}>
                            <strong>{hasEarlierArrival ? `Chegada ${time.format(new Date(slot.slot_start_at))}` : timeRange(slot.core_start_at, slot.core_end_at)}</strong>
                            {hasEarlierArrival ? <small>Atendimento contratado {timeRange(slot.core_start_at, slot.core_end_at)}</small> : <small>Período contratado</small>}
                            <span>{money.format(numeric(slot.commercial_value))}</span>
                            {creatingHold === slot.slot_start_at ? <em>Reservando horário…</em> : null}
                          </button>
                        )
                      })}
                    </div>
                  ) : localDate && !searchingSlots ? <div className="booking-empty compact"><p>Nenhum horário disponível para esta busca. Tente outra data.</p></div> : null}
                </section>

                {quote ? (
                  <aside className="booking-summary">
                    <div><small>Valor estimado</small><strong>{money.format(numeric(quote.commercial_value))}</strong></div>
                    <div><small>Duração contratada</small><strong>{durationLabel(selectedContractedMinutes)}</strong></div>
                  </aside>
                ) : null}

                {hold ? (
                  <section className="hold-confirmation" aria-live="polite">
                    <div className="hold-dot" />
                    <div>
                      <small>Seu horário está reservado</small>
                      <h2>{hold.slot_start_at !== hold.core_start_at ? `Chegada ${time.format(new Date(hold.slot_start_at))}` : timeRange(hold.core_start_at, hold.core_end_at)}</h2>
                      {hold.slot_start_at !== hold.core_start_at ? <p>Atendimento contratado {timeRange(hold.core_start_at, hold.core_end_at)}.</p> : null}
                      <p>Conclua sua reserva antes do tempo indicado para manter este horário.</p>
                    </div>
                    <strong className="hold-timer">{secondsLabel(remainingSeconds)}</strong>
                  </section>
                ) : null}
              </>
            ) : null}
          </div>
        )}
      </section>
    </main>
  )
}
