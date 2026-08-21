import { useEffect, useMemo, useState } from 'react'
import {
  createBookingHold,
  listBookingSlots,
  loadBookingPage,
  quoteBooking,
  type BookingPageData,
  type BookingQuote,
  type BookingService,
  type BookingSlot,
  type CheckoutHold,
  type ExtraSelection,
} from './bookingApi'
import './booking.css'

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

function numeric(value: number | string | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function readableError(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'Não foi possível concluir esta etapa.'
  const known: Array<[string, string]> = [
    ['SLOT_NO_LONGER_AVAILABLE', 'Esse horário acabou de ficar indisponível. Escolha outro horário.'],
    ['REQUIRED_EXTRA_MISSING', 'Revise os extras obrigatórios antes de continuar.'],
    ['INVALID_PEOPLE_COUNT', 'A quantidade de pessoas não é válida para este serviço.'],
    ['PUBLIC_SERVICE_NOT_AVAILABLE_ON_PAGE', 'Esse serviço não está disponível nesta página.'],
    ['EMPLOYEE_NOT_AVAILABLE_FOR_SERVICE', 'O profissional selecionado não está disponível para este serviço.'],
    ['INVALID_EXTRA', 'Um dos extras selecionados não está disponível para este serviço.'],
  ]
  return known.find(([key]) => raw.includes(key))?.[1] ?? 'Não foi possível concluir esta etapa. Tente novamente.'
}

function selectedExtras(service: BookingService | null, quantities: Record<string, number>): ExtraSelection[] {
  if (!service) return []
  return service.extras
    .map((extra) => ({ extra_id: extra.id, quantity: quantities[extra.id] ?? 0 }))
    .filter((selection) => selection.quantity > 0)
}

function secondsLabel(total: number): string {
  const safe = Math.max(0, total)
  const min = Math.floor(safe / 60)
  const sec = safe % 60
  return `${String(min).padStart(2, '0')}:${String(sec).padStart(2, '0')}`
}

export function BookingPage({ slug }: { slug: string }) {
  const [page, setPage] = useState<BookingPageData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [serviceId, setServiceId] = useState('')
  const [employeeRelationId, setEmployeeRelationId] = useState('')
  const [extraQuantities, setExtraQuantities] = useState<Record<string, number>>({})
  const [peopleCount, setPeopleCount] = useState(1)
  const [localDate, setLocalDate] = useState('')
  const [quote, setQuote] = useState<BookingQuote | null>(null)
  const [slots, setSlots] = useState<BookingSlot[]>([])
  const [searchingSlots, setSearchingSlots] = useState(false)
  const [creatingHold, setCreatingHold] = useState<string | null>(null)
  const [hold, setHold] = useState<CheckoutHold | null>(null)
  const [remainingSeconds, setRemainingSeconds] = useState(0)
  const [holdExpired, setHoldExpired] = useState(false)

  const service = useMemo(
    () => page?.services.find((item) => item.id === serviceId) ?? null,
    [page, serviceId],
  )

  const extras = useMemo(
    () => selectedExtras(service, extraQuantities),
    [service, extraQuantities],
  )

  useEffect(() => {
    let active = true
    setLoading(true)
    setError(null)
    loadBookingPage(slug)
      .then((data) => {
        if (!active) return
        setPage(data)
        if (!data) setError('Página de agendamento não encontrada.')
      })
      .catch((cause) => {
        if (!active) return
        setError(readableError(cause))
      })
      .finally(() => active && setLoading(false))
    return () => { active = false }
  }, [slug])

  useEffect(() => {
    if (!service || !employeeRelationId) {
      setQuote(null)
      return
    }
    let active = true
    quoteBooking({
      pageSlug: slug,
      serviceId: service.id,
      serviceEmployeeId: employeeRelationId,
      extras,
      peopleCount,
    })
      .then((next) => active && setQuote(next))
      .catch(() => active && setQuote(null))
    return () => { active = false }
  }, [employeeRelationId, extras, peopleCount, service, slug])

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

  function chooseService(nextId: string) {
    const next = page?.services.find((item) => item.id === nextId) ?? null
    setServiceId(nextId)
    setEmployeeRelationId(next?.employees.length === 1 ? next.employees[0].service_employee_id : '')
    setPeopleCount(next?.minimum_people ?? 1)
    setExtraQuantities(Object.fromEntries(
      (next?.extras ?? []).filter((extra) => extra.is_required).map((extra) => [extra.id, 1]),
    ))
    setLocalDate('')
    setSlots([])
    setHold(null)
    setHoldExpired(false)
    setQuote(null)
    setError(null)
  }

  function changeExtra(extraId: string, quantity: number) {
    setExtraQuantities((current) => ({ ...current, [extraId]: quantity }))
    setSlots([])
    setHold(null)
    setHoldExpired(false)
  }

  async function searchSlots() {
    if (!service || !employeeRelationId || !localDate) return
    setSearchingSlots(true)
    setError(null)
    setHoldExpired(false)
    try {
      const result = await listBookingSlots({
        pageSlug: slug,
        serviceId: service.id,
        serviceEmployeeId: employeeRelationId,
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
    if (!service || !employeeRelationId) return
    setCreatingHold(slot.slot_start_at)
    setError(null)
    try {
      const nextHold = await createBookingHold({
        pageSlug: slug,
        serviceId: service.id,
        serviceEmployeeId: employeeRelationId,
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
        expiresAt: nextHold.expires_at,
      }))
    } catch (cause) {
      setError(readableError(cause))
      await searchSlots()
    } finally {
      setCreatingHold(null)
    }
  }

  if (loading) {
    return <main className="booking-shell"><div className="booking-card">Carregando agenda…</div></main>
  }

  if (!page) {
    return <main className="booking-shell"><div className="booking-card"><h1>Agenda indisponível</h1><p>{error}</p></div></main>
  }

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
        {holdExpired ? <div className="form-alert error" role="alert">O tempo de proteção terminou. O horário foi liberado; escolha um horário novamente.</div> : null}

        {page.services.length === 0 ? (
          <div className="booking-empty">
            <h2>Serviços ainda não publicados</h2>
            <p>Esta página já está preparada, mas os serviços ainda precisam ser vinculados no administrativo.</p>
          </div>
        ) : (
          <div className="booking-flow">
            <section className="booking-step">
              <div className="step-title"><span>1</span><div><h2>Escolha o serviço</h2><p>Selecione o atendimento que deseja agendar.</p></div></div>
              <div className="service-grid">
                {page.services.map((item) => (
                  <button
                    type="button"
                    key={item.id}
                    className={`service-option ${serviceId === item.id ? 'selected' : ''}`}
                    onClick={() => chooseService(item.id)}
                  >
                    {item.cover_image_url ? <img src={item.cover_image_url} alt="" /> : null}
                    <strong>{item.name}</strong>
                    {item.short_description ? <small>{item.short_description}</small> : null}
                    <span>A partir de {money.format(numeric(item.base_price))}</span>
                  </button>
                ))}
              </div>
            </section>

            {service ? (
              <>
                {service.employees.length > 1 ? (
                  <section className="booking-step">
                    <div className="step-title"><span>2</span><div><h2>Profissional</h2><p>Escolha quem realizará o atendimento.</p></div></div>
                    <div className="choice-row">
                      {service.employees.map((employee) => (
                        <button
                          type="button"
                          className={`choice-pill ${employeeRelationId === employee.service_employee_id ? 'selected' : ''}`}
                          key={employee.service_employee_id}
                          onClick={() => { setEmployeeRelationId(employee.service_employee_id); setSlots([]) }}
                        >{employee.name}</button>
                      ))}
                    </div>
                  </section>
                ) : null}

                {service.extras.length > 0 ? (
                  <section className="booking-step">
                    <div className="step-title"><span>{service.employees.length > 1 ? '3' : '2'}</span><div><h2>Extras</h2><p>Personalize o atendimento antes de escolher a data.</p></div></div>
                    <div className="extras-list">
                      {service.extras.map((extra) => {
                        const quantity = extraQuantities[extra.id] ?? 0
                        return (
                          <div className="extra-row" key={extra.id}>
                            <div>
                              <strong>{extra.name}{extra.is_required ? ' · obrigatório' : ''}</strong>
                              {extra.description ? <small>{extra.description}</small> : null}
                              <span>+ {money.format(numeric(extra.price))}</span>
                              {extra.schedule_placement === 'PREPEND' && (extra.default_schedule_minutes ?? 0) > 0 ? (
                                <small>Este extra pode antecipar seu horário de chegada.</small>
                              ) : null}
                            </div>
                            {extra.is_required ? (
                              <span className="required-badge">Incluído</span>
                            ) : extra.max_quantity === 1 ? (
                              <label className="toggle-extra">
                                <input
                                  type="checkbox"
                                  checked={quantity > 0}
                                  onChange={(event) => changeExtra(extra.id, event.target.checked ? 1 : 0)}
                                />
                                <span>{quantity > 0 ? 'Selecionado' : 'Adicionar'}</span>
                              </label>
                            ) : (
                              <select value={quantity} onChange={(event) => changeExtra(extra.id, Number(event.target.value))}>
                                {Array.from({ length: extra.max_quantity + 1 }, (_, index) => <option value={index} key={index}>{index}</option>)}
                              </select>
                            )}
                          </div>
                        )
                      })}
                    </div>
                  </section>
                ) : null}

                <section className="booking-step">
                  <div className="step-title"><span>{service.extras.length > 0 ? (service.employees.length > 1 ? '4' : '3') : (service.employees.length > 1 ? '3' : '2')}</span><div><h2>Pessoas</h2><p>A quantidade pode alterar disponibilidade e valor.</p></div></div>
                  {service.minimum_people === service.maximum_people ? (
                    <p className="fixed-people">{service.minimum_people} {service.minimum_people === 1 ? 'pessoa' : 'pessoas'}</p>
                  ) : (
                    <select
                      className="people-select"
                      value={peopleCount}
                      onChange={(event) => { setPeopleCount(Number(event.target.value)); setSlots([]) }}
                    >
                      {Array.from({ length: service.maximum_people - service.minimum_people + 1 }, (_, index) => service.minimum_people + index)
                        .map((value) => <option key={value} value={value}>{value} {value === 1 ? 'pessoa' : 'pessoas'}</option>)}
                    </select>
                  )}
                </section>

                <section className="booking-step">
                  <div className="step-title"><span>{service.extras.length > 0 ? (service.employees.length > 1 ? '5' : '4') : (service.employees.length > 1 ? '4' : '3')}</span><div><h2>Data e horário</h2><p>Os horários exibidos já consideram recursos, extras e bloqueios da agenda.</p></div></div>
                  <div className="date-search">
                    <label>Data
                      <input type="date" min={todayLocal()} value={localDate} onChange={(event) => { setLocalDate(event.target.value); setSlots([]) }} />
                    </label>
                    <button className="primary" type="button" onClick={searchSlots} disabled={!localDate || !employeeRelationId || searchingSlots}>
                      {searchingSlots ? 'Consultando…' : 'Buscar horários'}
                    </button>
                  </div>

                  {slots.length > 0 ? (
                    <div className="slots-grid" aria-label="Horários disponíveis">
                      {slots.map((slot) => {
                        const arrival = time.format(new Date(slot.slot_start_at))
                        const core = time.format(new Date(slot.core_start_at))
                        const differs = slot.slot_start_at !== slot.core_start_at
                        return (
                          <button
                            type="button"
                            className="slot-option"
                            key={slot.slot_start_at}
                            disabled={creatingHold !== null || hold !== null}
                            onClick={() => protectSlot(slot)}
                          >
                            <strong>{arrival}</strong>
                            {differs ? <small>Atendimento principal às {core}</small> : <small>Início do atendimento</small>}
                            <span>{money.format(numeric(slot.commercial_value))}</span>
                            {creatingHold === slot.slot_start_at ? <em>Protegendo…</em> : null}
                          </button>
                        )
                      })}
                    </div>
                  ) : localDate && !searchingSlots ? (
                    <div className="booking-empty compact"><p>Nenhum horário listado ainda para esta busca. Tente outra data.</p></div>
                  ) : null}
                </section>

                {quote ? (
                  <aside className="booking-summary">
                    <div><small>Estimativa atual</small><strong>{money.format(numeric(quote.commercial_value))}</strong></div>
                    <div><small>Duração total</small><strong>{quote.duration_minutes} min</strong></div>
                  </aside>
                ) : null}

                {hold ? (
                  <section className="hold-confirmation" aria-live="polite">
                    <div className="hold-dot" />
                    <div>
                      <small>Horário protegido</small>
                      <h2>{time.format(new Date(hold.slot_start_at))}</h2>
                      {hold.slot_start_at !== hold.core_start_at ? <p>Atendimento principal às {time.format(new Date(hold.core_start_at))}.</p> : null}
                      <p>Preencha a próxima etapa antes do contador terminar. Se expirar, o horário volta a ficar disponível.</p>
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
