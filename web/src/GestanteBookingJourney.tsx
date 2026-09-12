import { useEffect, useMemo, useState } from 'react'
import {
  bindCheckoutCustomer,
  clearCheckoutPackage,
  createBookingHold,
  listBookingSlots,
  listCheckoutPackages,
  loadBookingPage,
  loadCheckoutContext,
  quoteBooking,
  selectCheckoutPackage,
  submitBookingCheckout,
  type AppointmentCheckoutResult,
  type BookingField,
  type BookingPageData,
  type BookingQuote,
  type BookingService,
  type BookingSlot,
  type CheckoutContext,
  type CheckoutHold,
  type CheckoutPackage,
  type ExtraSelection,
  type ServiceAnswer,
} from './bookingApi'
import {
  applyCheckoutCoupon,
  clearCheckoutCoupon,
  loadCheckoutCoupon,
  type CheckoutCouponState,
} from './checkoutCouponApi'
import {
  loadCheckoutPrebookOption,
  submitPreReservationCheckout,
  type CheckoutPrebookOption,
} from './prebookChoiceApi'
import { updateCheckoutSelection } from './checkoutSelectionApi'
import { PaymentPanel } from './PaymentPanel'
import { GestationalDatePicker } from './GestationalDatePicker'
import { gestationalAgeLabel, gestationalAgeOn } from './gestationalRecommendation'
import './sabrinaBookingJourney.css'

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })
const clock = new Intl.DateTimeFormat('pt-BR', { hour: '2-digit', minute: '2-digit', timeZone: 'America/Sao_Paulo' })

type StepKey = 'SERVICE' | 'EXTRAS' | 'DATE' | 'PEOPLE' | 'CUSTOMER' | 'REVIEW' | 'PAYMENT' | 'CONFIRMATION'
type AnswerValue = string | number | boolean | null
type CheckoutMode = 'PAY_NOW' | 'PREBOOK' | ''
type FinalResult = AppointmentCheckoutResult & {
  pre_reservation?: boolean
  pre_reservation_id?: string
  pre_reservation_expires_at?: string | null
  pre_reservation_email_sent?: boolean
}

const STEPS: StepKey[] = ['SERVICE', 'EXTRAS', 'DATE', 'PEOPLE', 'CUSTOMER', 'REVIEW', 'PAYMENT', 'CONFIRMATION']
const STEP_LABELS: Record<StepKey, string> = {
  SERVICE: 'Pacote', EXTRAS: 'Beleza', DATE: 'Data e hora', PEOPLE: 'Pessoas',
  CUSTOMER: 'Dados', REVIEW: 'Revisão', PAYMENT: 'Pagamento', CONFIRMATION: 'Confirmação',
}

function numeric(value: number | string | null | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function digits(value: string): string { return value.replace(/\D/g, '') }
function isEmail(value: string): boolean { return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value.trim()) }
function formatDate(value: string): string {
  const [year, month, day] = value.split('-')
  return year && month && day ? `${day}/${month}/${year}` : value
}
function timeRange(slot: BookingSlot | CheckoutHold): string {
  return `${clock.format(new Date(slot.slot_start_at))} – ${clock.format(new Date(slot.slot_end_at))}`
}
function normalizedLabel(field: BookingField): string {
  return field.label.normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[:.]/g, '').trim().toLowerCase()
}
function isDppField(field: BookingField): boolean {
  return field.field_key === 'pergunta_9' || normalizedLabel(field).includes('data prevista para o parto')
}
function isDuplicateTaxIdField(field: BookingField): boolean {
  return field.field_key === 'pergunta_5' || normalizedLabel(field) === 'cpf'
}
function fieldAnswered(field: BookingField, value: AnswerValue | undefined): boolean {
  if (field.field_type === 'BOOLEAN') return value === true || value === false
  return value !== null && value !== undefined && String(value).trim() !== ''
}
function selectedExtras(service: BookingService | null, quantities: Record<string, number>): ExtraSelection[] {
  if (!service) return []
  return service.extras
    .map((extra) => ({ extra_id: extra.id, quantity: quantities[extra.id] ?? 0 }))
    .filter((selection) => selection.quantity > 0)
}
function fieldOptions(field: BookingField): Array<{ value: string; label: string }> {
  if (!Array.isArray(field.options)) return []
  return field.options.flatMap((item) => {
    if (typeof item === 'string') return [{ value: item, label: item }]
    if (!item || typeof item !== 'object') return []
    const row = item as Record<string, unknown>
    const value = typeof row.value === 'string' ? row.value : ''
    const label = typeof row.label === 'string' ? row.label : value
    return value ? [{ value, label }] : []
  })
}
function readableError(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'BOOKING_FAILED'
  const known: Array<[string, string]> = [
    ['SLOT_NO_LONGER_AVAILABLE', 'Esse horário acabou de ficar indisponível. Escolha outro horário.'],
    ['CHECKOUT_HOLD_NOT_ACTIVE', 'O tempo para concluir a reserva terminou. Escolha o horário novamente.'],
    ['HOLD_EXPIRED', 'O tempo para concluir a reserva terminou. Escolha o horário novamente.'],
    ['HOLD_SELECTION_REQUIRES_NEW_SLOT', 'Não foi possível manter este horário. Escolha outro.'],
    ['INVALID_PEOPLE_COUNT', 'Revise a quantidade de pessoas.'],
    ['CUSTOMER_NAME_INVALID', 'Informe seu nome completo.'],
    ['CUSTOMER_EMAIL_INVALID', 'Informe um e-mail válido.'],
    ['CUSTOMER_PHONE_INVALID', 'Informe um WhatsApp válido.'],
    ['CUSTOMER_TAX_ID_INVALID', 'Informe um CPF válido.'],
    ['REQUIRED_SERVICE_FIELDS_MISSING', 'Preencha todas as informações obrigatórias.'],
    ['TERMS_NOT_ACCEPTED', 'Aceite os termos para continuar.'],
    ['RATE_LIMITED', 'Muitas tentativas em sequência. Tente novamente em alguns minutos.'],
  ]
  return known.find(([key]) => raw.includes(key))?.[1] ?? 'Não foi possível concluir esta etapa. Tente novamente.'
}

function FieldInput({ field, value, onChange }: { field: BookingField; value: AnswerValue | undefined; onChange: (value: AnswerValue) => void }) {
  if (field.field_type === 'BOOLEAN') {
    return <label className="sby-check-row"><input type="checkbox" checked={value === true} onChange={(event) => onChange(event.target.checked)} /><span>{field.label}{field.is_required ? ' *' : ''}</span></label>
  }
  if (field.field_type === 'SELECT') {
    return <label className="sby-field"><span>{field.label}{field.is_required ? ' *' : ''}</span><select value={typeof value === 'string' ? value : ''} onChange={(event) => onChange(event.target.value || null)}><option value="">Selecione</option>{fieldOptions(field).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}</select>{field.help_text ? <small>{field.help_text}</small> : null}</label>
  }
  if (field.field_type === 'TEXTAREA') {
    return <label className="sby-field sby-field-wide"><span>{field.label}{field.is_required ? ' *' : ''}</span><textarea value={typeof value === 'string' ? value : ''} placeholder={field.placeholder ?? undefined} onChange={(event) => onChange(event.target.value)} />{field.help_text ? <small>{field.help_text}</small> : null}</label>
  }
  const type = field.field_type === 'DATE' ? 'date' : field.field_type === 'NUMBER' ? 'number' : 'text'
  return <label className="sby-field"><span>{field.label}{field.is_required ? ' *' : ''}</span><input type={type} value={value == null || typeof value === 'boolean' ? '' : String(value)} placeholder={field.placeholder ?? undefined} onChange={(event) => onChange(field.field_type === 'NUMBER' ? (event.target.value === '' ? null : Number(event.target.value)) : event.target.value)} />{field.help_text ? <small>{field.help_text}</small> : null}</label>
}

export function GestanteBookingJourney({ slug }: { slug: 'sabrina-essencial' | 'sabrina-signature' }) {
  const [page, setPage] = useState<BookingPageData | null>(null)
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [step, setStep] = useState<StepKey>('SERVICE')
  const [serviceId, setServiceId] = useState('')
  const [employeeRelationId, setEmployeeRelationId] = useState('')
  const [extraQuantities, setExtraQuantities] = useState<Record<string, number>>({})
  const [peopleCount, setPeopleCount] = useState(1)
  const [quote, setQuote] = useState<BookingQuote | null>(null)
  const [dpp, setDpp] = useState('')
  const [date, setDate] = useState('')
  const [slots, setSlots] = useState<BookingSlot[]>([])
  const [selectedSlot, setSelectedSlot] = useState<BookingSlot | null>(null)
  const [loadingSlots, setLoadingSlots] = useState(false)
  const [hold, setHold] = useState<CheckoutHold | null>(null)
  const [remainingSeconds, setRemainingSeconds] = useState(0)
  const [context, setContext] = useState<CheckoutContext | null>(null)
  const [coupon, setCoupon] = useState<CheckoutCouponState | null>(null)
  const [couponCode, setCouponCode] = useState('')
  const [couponBusy, setCouponBusy] = useState(false)
  const [customer, setCustomer] = useState({ name: '', email: '', emailConfirm: '', phone: '', taxId: '' })
  const [answers, setAnswers] = useState<Record<string, AnswerValue>>({})
  const [packages, setPackages] = useState<CheckoutPackage[]>([])
  const [packageId, setPackageId] = useState('')
  const [prebookOption, setPrebookOption] = useState<CheckoutPrebookOption | null>(null)
  const [checkoutMode, setCheckoutMode] = useState<CheckoutMode>('PAY_NOW')
  const [acceptedTerms, setAcceptedTerms] = useState<Record<string, boolean>>({})
  const [result, setResult] = useState<FinalResult | null>(null)

  const service = useMemo(() => page?.services.find((item) => item.id === serviceId) ?? null, [page, serviceId])
  const extras = useMemo(() => selectedExtras(service, extraQuantities), [service, extraQuantities])
  const stepIndex = STEPS.indexOf(step)
  const selectedPackage = useMemo(() => packages.find((item) => item.hour_package_id === packageId) ?? null, [packages, packageId])
  const probeKey = useMemo(() => service && employeeRelationId ? JSON.stringify({ service: service.id, employee: employeeRelationId, extras: [...extras].sort((a, b) => a.extra_id.localeCompare(b.extra_id)) }) : '', [service, employeeRelationId, extras])

  useEffect(() => {
    let active = true
    setLoading(true)
    loadBookingPage(slug).then((data) => { if (active) { setPage(data); if (!data) setError('Agenda indisponível no momento.') } }).catch((cause) => active && setError(readableError(cause))).finally(() => active && setLoading(false))
    return () => { active = false }
  }, [slug])

  useEffect(() => {
    if (!service || !employeeRelationId) { setQuote(null); return }
    let active = true
    quoteBooking({ pageSlug: slug, serviceId: service.id, serviceEmployeeId: employeeRelationId, extras, peopleCount }).then((next) => active && setQuote(next)).catch(() => active && setQuote(null))
    return () => { active = false }
  }, [service, employeeRelationId, extras, peopleCount, slug])

  useEffect(() => {
    if (!hold || !['PEOPLE', 'CUSTOMER', 'REVIEW'].includes(step)) { setRemainingSeconds(0); return }
    const tick = () => {
      const seconds = Math.max(0, Math.ceil((new Date(hold.expires_at).getTime() - Date.now()) / 1000))
      setRemainingSeconds(seconds)
      if (seconds === 0) {
        sessionStorage.removeItem('bs_checkout_hold')
        setHold(null); setContext(null); setSelectedSlot(null); setError('O tempo para concluir a reserva terminou. Escolha o horário novamente.'); setStep('DATE')
      }
    }
    tick()
    const timer = window.setInterval(tick, 1000)
    return () => window.clearInterval(timer)
  }, [hold, step])

  function resetAfterPackage() {
    setDate(''); setSlots([]); setSelectedSlot(null); setHold(null); setContext(null); setCoupon(null); setPackages([]); setPackageId(''); setPrebookOption(null); setAcceptedTerms({}); setResult(null)
    sessionStorage.removeItem('bs_checkout_hold')
  }

  function chooseService(nextId: string) {
    const next = page?.services.find((item) => item.id === nextId) ?? null
    setServiceId(nextId)
    setEmployeeRelationId(next?.employees.length === 1 ? next.employees[0].service_employee_id : '')
    setExtraQuantities(Object.fromEntries((next?.extras ?? []).filter((extra) => extra.is_required).map((extra) => [extra.id, 1])))
    setPeopleCount(next?.minimum_people ?? 1)
    resetAfterPackage(); setError('')
  }

  function changeExtra(extraId: string, quantity: number) {
    setExtraQuantities((current) => ({ ...current, [extraId]: quantity }))
    setDate(''); setSlots([]); setSelectedSlot(null); setHold(null); setContext(null); sessionStorage.removeItem('bs_checkout_hold'); setError('')
  }

  async function loadDay(day: string): Promise<{ length: number }> {
    if (!service || !employeeRelationId) return { length: 0 }
    const found = await listBookingSlots({ pageSlug: slug, serviceId: service.id, serviceEmployeeId: employeeRelationId, extras, peopleCount: service.minimum_people, localDate: day })
    return { length: found.length }
  }

  async function chooseDate(nextDate: string) {
    if (!service || !employeeRelationId) return
    setDate(nextDate); setSelectedSlot(null); setSlots([]); setLoadingSlots(true); setError('')
    try {
      const found = await listBookingSlots({ pageSlug: slug, serviceId: service.id, serviceEmployeeId: employeeRelationId, extras, peopleCount: service.minimum_people, localDate: nextDate })
      setSlots(found)
      if (!found.length) setError('Esse dia acabou de ficar sem horários disponíveis. Escolha outra data.')
    } catch (cause) { setError(readableError(cause)) } finally { setLoadingSlots(false) }
  }

  async function protectSlot(slot: BookingSlot, localDate: string) {
    if (!service || !employeeRelationId || hold) return
    setBusy(true); setDate(localDate); setSelectedSlot(slot); setError('')
    try {
      const nextHold = await createBookingHold({ pageSlug: slug, serviceId: service.id, serviceEmployeeId: employeeRelationId, extras, peopleCount: service.minimum_people, requestedStartAt: slot.slot_start_at })
      setHold(nextHold)
      sessionStorage.setItem('bs_checkout_hold', JSON.stringify({ token: nextHold.checkout_hold_token, id: nextHold.checkout_hold_id, pageSlug: slug, serviceId: service.id, serviceName: service.name, expiresAt: nextHold.expires_at }))
      setStep('PEOPLE')
    } catch (cause) {
      setSelectedSlot(null); setError(readableError(cause))
      if (cause instanceof Error && cause.message.includes('SLOT_NO_LONGER_AVAILABLE')) await chooseDate(localDate)
    } finally { setBusy(false) }
  }

  async function confirmPeople() {
    if (!hold) return
    setBusy(true); setError('')
    try {
      await updateCheckoutSelection({ token: hold.checkout_hold_token, extras, peopleCount })
      const [nextContext, nextCoupon] = await Promise.all([loadCheckoutContext(hold.checkout_hold_token), loadCheckoutCoupon(hold.checkout_hold_token)])
      const seeded: Record<string, AnswerValue> = { ...answers }
      for (const field of nextContext.fields) {
        if (isDppField(field) && dpp) seeded[field.id] = dpp
        if (isDuplicateTaxIdField(field) && customer.taxId) seeded[field.id] = customer.taxId
      }
      setAnswers(seeded); setContext(nextContext); setCoupon(nextCoupon); setCouponCode(nextCoupon.coupon_code ?? ''); setStep('CUSTOMER')
    } catch (cause) { setError(readableError(cause)) } finally { setBusy(false) }
  }

  async function saveCustomer() {
    if (!hold || !context) return
    setError('')
    if (customer.name.trim().length < 3) return setError('Informe seu nome completo.')
    if (!isEmail(customer.email)) return setError('Informe um e-mail válido.')
    if (customer.email.trim().toLowerCase() !== customer.emailConfirm.trim().toLowerCase()) return setError('Os e-mails informados não são iguais.')
    if (digits(customer.phone).length < 10) return setError('Informe um WhatsApp válido.')
    if (context.require_tax_id && digits(customer.taxId).length !== 11) return setError('Informe um CPF válido.')
    const effective = { ...answers }
    for (const field of context.fields) {
      if (isDppField(field) && dpp) effective[field.id] = dpp
      if (isDuplicateTaxIdField(field)) effective[field.id] = customer.taxId
    }
    setAnswers(effective)
    const missing = context.fields.find((field) => field.is_required && !fieldAnswered(field, effective[field.id]))
    if (missing) return setError(`Preencha o campo “${missing.label}”.`)
    setBusy(true)
    try {
      await bindCheckoutCustomer({ token: hold.checkout_hold_token, name: customer.name, email: customer.email, phone: customer.phone, taxId: customer.taxId })
      const [nextPackages, nextPrebook] = await Promise.all([listCheckoutPackages(hold.checkout_hold_token).catch(() => [] as CheckoutPackage[]), loadCheckoutPrebookOption(hold.checkout_hold_token).catch(() => null)])
      setPackages(nextPackages); setPrebookOption(nextPrebook); setCheckoutMode(nextPrebook?.eligible ? '' : 'PAY_NOW'); setStep('REVIEW')
    } catch (cause) { setError(readableError(cause)) } finally { setBusy(false) }
  }

  async function applyCoupon() {
    if (!hold) return
    setCouponBusy(true); setError('')
    try { const next = await applyCheckoutCoupon(hold.checkout_hold_token, couponCode); setCoupon(next); setCouponCode(next.coupon_code ?? couponCode) } catch (cause) { setError(readableError(cause)) } finally { setCouponBusy(false) }
  }
  async function removeCoupon() {
    if (!hold) return
    setCouponBusy(true); setError('')
    try { const next = await clearCheckoutCoupon(hold.checkout_hold_token); setCoupon(next); setCouponCode('') } catch (cause) { setError(readableError(cause)) } finally { setCouponBusy(false) }
  }
  async function choosePackage(nextId: string) {
    if (!hold) return
    setBusy(true); setError('')
    try { if (nextId) await selectCheckoutPackage(hold.checkout_hold_token, nextId); else await clearCheckoutPackage(hold.checkout_hold_token); setPackageId(nextId) } catch (cause) { setError(readableError(cause)) } finally { setBusy(false) }
  }

  async function submitReview() {
    if (!hold || !context) return
    const termsReady = !context.service.requires_terms || (context.terms.length > 0 && context.terms.every((term) => acceptedTerms[term.id]))
    if (!termsReady) return setError('Aceite todos os termos para continuar.')
    if (!checkoutMode) return setError('Escolha se deseja pagar agora ou fazer uma pré-reserva.')
    const payloadAnswers: ServiceAnswer[] = context.fields.filter((field) => fieldAnswered(field, answers[field.id])).map((field) => ({ service_field_id: field.id, value: answers[field.id] ?? null }))
    const termVersionIds = context.terms.filter((term) => acceptedTerms[term.id]).map((term) => term.id)
    setBusy(true); setError('')
    try {
      const appointment = (checkoutMode === 'PREBOOK' ? await submitPreReservationCheckout({ token: hold.checkout_hold_token, termVersionIds, answers: payloadAnswers }) : await submitBookingCheckout({ token: hold.checkout_hold_token, termVersionIds, answers: payloadAnswers })) as FinalResult
      setResult(appointment); sessionStorage.removeItem('bs_checkout_hold')
      if (appointment.pre_reservation || appointment.status === 'CONFIRMED') { sessionStorage.removeItem('bs_appointment_manage'); setStep('CONFIRMATION') }
      else { sessionStorage.setItem('bs_appointment_manage', JSON.stringify({ appointmentId: appointment.appointment_id, publicCode: appointment.public_code, accessToken: appointment.access_token, status: appointment.status })); setStep('PAYMENT') }
    } catch (cause) { setError(readableError(cause)) } finally { setBusy(false) }
  }

  const displayedTotal = selectedPackage ? numeric(selectedPackage.cash_due) : numeric(coupon?.commercial_value ?? context?.summary.commercial_value ?? quote?.commercial_value)
  const confirmationAge = useMemo(() => {
    if (!dpp || !date) return ''
    try { return gestationalAgeLabel(gestationalAgeOn(dpp, date)) } catch { return '' }
  }, [dpp, date])

  if (loading) return <div className="sby-shell"><div className="sby-card sby-loading">Carregando agenda…</div></div>
  if (!page) return <div className="sby-shell"><div className="sby-card sby-loading">{error || 'Agenda indisponível.'}</div></div>

  return <main className="sby-shell" style={{ '--sby-accent': page.accent_color ?? '#22201f' } as React.CSSProperties}><section className="sby-card">
    <header className="sby-head"><span>{page.display_name}</span><h1>{page.title}</h1>{page.subtitle ? <p>{page.subtitle}</p> : null}</header>
    <nav className="sby-stepper" aria-label="Etapas do agendamento">{STEPS.map((item, index) => { const current = item === step; const completed = index < stepIndex; const canReturn = !hold && completed && index <= 2; return <button type="button" key={item} className={`${current ? 'current' : ''} ${completed ? 'completed' : ''}`} disabled={!canReturn} onClick={() => canReturn && setStep(item)}><span>{completed ? '✓' : index + 1}</span><small>{STEP_LABELS[item]}</small></button> })}</nav>
    {error ? <div className="sby-alert" role="alert">{error}</div> : null}
    {hold && ['PEOPLE', 'CUSTOMER', 'REVIEW'].includes(step) && remainingSeconds > 0 ? <div className="sby-hold-strip"><span>Horário protegido</span><strong>{String(Math.floor(remainingSeconds / 60)).padStart(2, '0')}:{String(remainingSeconds % 60).padStart(2, '0')}</strong></div> : null}
    <div className="sby-stage">
      {step === 'SERVICE' ? <><div className="sby-stage-title"><small>Etapa 1</small><h2>Escolha seu pacote</h2><p>{slug === 'sabrina-signature' ? 'Gestante Signature · com Sabrina Pierri' : 'Gestante Essencial · com Fê'}</p></div><div className="sby-service-grid">{page.services.map((item) => <button type="button" key={item.id} className={`sby-service ${serviceId === item.id ? 'selected' : ''}`} onClick={() => chooseService(item.id)}><div><strong>{item.name}</strong>{item.short_description ? <small>{item.short_description}</small> : null}</div><span>{money.format(numeric(item.base_price))}</span></button>)}</div>{service && service.employees.length > 1 ? <div className="sby-inline-choice"><strong>Profissional</strong><div>{service.employees.map((employee) => <button type="button" key={employee.service_employee_id} className={employeeRelationId === employee.service_employee_id ? 'selected' : ''} onClick={() => { setEmployeeRelationId(employee.service_employee_id); resetAfterPackage() }}>{employee.name}</button>)}</div></div> : null}<div className="sby-actions end"><button className="sby-primary" type="button" disabled={!service || !employeeRelationId} onClick={() => setStep('EXTRAS')}>Continuar</button></div></> : null}

      {step === 'EXTRAS' && service ? <><div className="sby-stage-title"><small>Etapa 2</small><h2>Produção para o ensaio</h2><p>Escolha aqui porque maquiagem e cabelo também ocupam tempo na agenda e mudam os horários disponíveis.</p></div>{service.extras.length ? <div className="sby-extras">{service.extras.map((extra) => { const quantity = extraQuantities[extra.id] ?? 0; return <div className={`sby-extra ${quantity > 0 ? 'selected' : ''}`} key={extra.id}><div><strong>{extra.name}{extra.is_required ? ' · obrigatório' : ''}</strong>{extra.description ? <small className="sby-extra-description">{extra.description}</small> : null}<span>+ {money.format(numeric(extra.price))}</span>{(extra.default_schedule_minutes ?? 0) > 0 ? <em>Acrescenta {extra.default_schedule_minutes} min à ocupação da agenda.</em> : null}</div>{extra.is_required ? <b>Incluído</b> : extra.max_quantity === 1 ? <button type="button" onClick={() => changeExtra(extra.id, quantity ? 0 : 1)}>{quantity ? 'Remover' : 'Adicionar'}</button> : <select value={quantity} onChange={(event) => changeExtra(extra.id, Number(event.target.value))}>{Array.from({ length: extra.max_quantity + 1 }, (_, index) => <option key={index} value={index}>{index}</option>)}</select>}</div> })}</div> : <div className="sby-empty">Este pacote não possui produção adicional.</div>}{quote ? <div className="sby-mini-summary"><span>Valor atual</span><strong>{money.format(numeric(quote.commercial_value))}</strong></div> : null}<div className="sby-actions"><button className="sby-secondary" type="button" onClick={() => setStep('SERVICE')}>Voltar</button><button className="sby-primary" type="button" onClick={() => setStep('DATE')}>Ver horários</button></div></> : null}

      {step === 'DATE' && service ? <><div className="sby-stage-title"><small>Etapa 3</small><h2>Escolha a data e o horário</h2><p>Primeiro mostramos horários recomendados para a sua fase da gestação. Todas as outras datas continuam disponíveis.</p></div><GestationalDatePicker pageSlug={slug} service={service} serviceEmployeeId={employeeRelationId} extras={extras} probeKey={probeKey} dpp={dpp} date={date} slots={slots} loadingSlots={loadingSlots} busy={busy} selectedSlot={selectedSlot} loadDay={loadDay} onSelectDate={(day) => void chooseDate(day)} onSelectSlot={(slot, localDate) => void protectSlot(slot, localDate)} onDppChange={setDpp} /><div className="sby-actions"><button className="sby-secondary" type="button" disabled={busy} onClick={() => setStep('EXTRAS')}>Voltar</button></div></> : null}

      {step === 'PEOPLE' && service && selectedSlot && hold ? <><div className="sby-stage-title"><small>Etapa 4</small><h2>Quem participa do ensaio?</h2><p>Seu horário já está protegido.</p></div><div className="sby-selected-time"><span>{formatDate(date)}</span><strong>{timeRange(selectedSlot)}</strong></div>{service.minimum_people === service.maximum_people ? <div className="sby-people-fixed">{service.minimum_people} {service.minimum_people === 1 ? 'pessoa' : 'pessoas'}</div> : <div className="sby-people-grid">{Array.from({ length: service.maximum_people - service.minimum_people + 1 }, (_, index) => service.minimum_people + index).map((value) => <button type="button" key={value} className={peopleCount === value ? 'selected' : ''} onClick={() => setPeopleCount(value)}>{value}<small>{value === 1 ? 'pessoa' : 'pessoas'}</small></button>)}</div>}<div className="sby-actions end"><button className="sby-primary" type="button" disabled={busy} onClick={() => void confirmPeople()}>{busy ? 'Salvando…' : 'Continuar'}</button></div></> : null}

      {step === 'CUSTOMER' && context ? <><div className="sby-stage-title"><small>Etapa 5</small><h2>Complete seus dados</h2><p>{dpp ? 'A DPP que você informou já foi preenchida e não será perguntada novamente.' : 'Complete as informações que ainda faltam para o ensaio.'}</p></div><div className="sby-form-grid"><label className="sby-field"><span>Nome completo *</span><input autoComplete="name" value={customer.name} onChange={(event) => setCustomer((current) => ({ ...current, name: event.target.value }))} /></label><label className="sby-field"><span>WhatsApp *</span><input autoComplete="tel" value={customer.phone} onChange={(event) => setCustomer((current) => ({ ...current, phone: event.target.value }))} /></label><label className="sby-field"><span>E-mail *</span><input type="email" autoComplete="email" value={customer.email} onChange={(event) => setCustomer((current) => ({ ...current, email: event.target.value }))} /></label><label className="sby-field"><span>Confirme o e-mail *</span><input type="email" value={customer.emailConfirm} onChange={(event) => setCustomer((current) => ({ ...current, emailConfirm: event.target.value }))} /></label><label className="sby-field"><span>CPF *</span><input inputMode="numeric" value={customer.taxId} onChange={(event) => setCustomer((current) => ({ ...current, taxId: event.target.value }))} /></label>{context.fields.filter((field) => !(isDppField(field) && dpp) && !isDuplicateTaxIdField(field)).map((field) => <FieldInput key={field.id} field={field} value={answers[field.id]} onChange={(value) => { setAnswers((current) => ({ ...current, [field.id]: value })); if (isDppField(field) && typeof value === 'string') setDpp(value) }} />)}</div><div className="sby-actions end"><button className="sby-primary" type="button" disabled={busy} onClick={() => void saveCustomer()}>{busy ? 'Salvando…' : 'Continuar para revisão'}</button></div></> : null}

      {step === 'REVIEW' && context && hold && service ? <><div className="sby-stage-title"><small>Etapa 6</small><h2>Revise seu ensaio</h2><p>Confira as informações antes de confirmar.</p></div><div className="sby-review"><div><span>Pacote</span><strong>{service.name}</strong></div><div><span>Data e hora</span><strong>{formatDate(date)} · {timeRange(hold)}</strong></div>{confirmationAge ? <div><span>Gestação no dia</span><strong>{confirmationAge}</strong></div> : null}<div><span>Pessoas</span><strong>{peopleCount}</strong></div><div><span>Produção</span><strong>{extras.length ? service.extras.filter((extra) => (extraQuantities[extra.id] ?? 0) > 0).map((extra) => extra.name).join(', ') : 'Nenhuma'}</strong></div></div><div className="sby-review-block"><label className="sby-field"><span>Cupom de desconto</span><input value={couponCode} onChange={(event) => setCouponCode(event.target.value.toUpperCase())} disabled={couponBusy} /></label><div className="sby-inline-actions">{coupon?.coupon_code ? <button type="button" onClick={() => void removeCoupon()} disabled={couponBusy}>Remover cupom</button> : <button type="button" onClick={() => void applyCoupon()} disabled={couponBusy || couponCode.trim().length < 3}>Aplicar cupom</button>}</div></div>{packages.length ? <div className="sby-review-block"><strong>Usar pacote/crédito disponível</strong><div className="sby-package-list"><label className={!packageId ? 'selected' : ''}><input type="radio" name="package" checked={!packageId} onChange={() => void choosePackage('')} /><span>Não usar pacote</span></label>{packages.map((item) => <label key={item.hour_package_id} className={packageId === item.hour_package_id ? 'selected' : ''}><input type="radio" name="package" checked={packageId === item.hour_package_id} disabled={!item.usable} onChange={() => void choosePackage(item.hour_package_id)} /><span>{item.name}<small>{item.usable ? `Saldo a pagar: ${money.format(numeric(item.cash_due))}` : 'Saldo insuficiente'}</small></span></label>)}</div></div> : null}{prebookOption?.eligible ? <div className="sby-review-block"><strong>Como deseja reservar?</strong><div className="sby-mode-grid"><label className={checkoutMode === 'PAY_NOW' ? 'selected' : ''}><input type="radio" name="mode" checked={checkoutMode === 'PAY_NOW'} onChange={() => setCheckoutMode('PAY_NOW')} /><span>Pagar agora</span></label><label className={checkoutMode === 'PREBOOK' ? 'selected' : ''}><input type="radio" name="mode" checked={checkoutMode === 'PREBOOK'} onChange={() => setCheckoutMode('PREBOOK')} /><span>Pré-reservar<small>Proteja o horário por {prebookOption.hold_minutes} minutos.</small></span></label></div></div> : null}{context.terms.length ? <div className="sby-review-block"><strong>Termos</strong>{context.terms.map((term) => <label className="sby-term" key={term.id}><input type="checkbox" checked={acceptedTerms[term.id] ?? false} onChange={(event) => setAcceptedTerms((current) => ({ ...current, [term.id]: event.target.checked }))} /><span>Li e aceito {term.name}</span></label>)}</div> : null}<div className="sby-total"><span>Valor da reserva</span><strong>{money.format(displayedTotal)}</strong></div><div className="sby-actions end"><button className="sby-primary" type="button" disabled={busy} onClick={() => void submitReview()}>{busy ? 'Gerando reserva…' : checkoutMode === 'PREBOOK' ? 'Criar pré-reserva' : 'Confirmar e ir ao pagamento'}</button></div></> : null}

      {step === 'PAYMENT' && result?.access_token ? <><div className="sby-stage-title"><small>Etapa 7</small><h2>Pagamento</h2><p>Finalize para confirmar seu ensaio.</p></div><PaymentPanel accessToken={result.access_token} onConfirmed={() => setStep('CONFIRMATION')} /></> : null}
      {step === 'CONFIRMATION' && result ? <div className="sby-confirmation" aria-live="polite"><span>✓</span><small>{result.pre_reservation ? 'Pré-reserva criada' : 'Ensaio confirmado'}</small><h2>{result.pre_reservation ? 'Seu horário está protegido temporariamente.' : 'Está marcado. ❤️'}</h2><p><strong>{formatDate(date)} · {selectedSlot ? timeRange(selectedSlot) : ''}</strong></p>{confirmationAge ? <p>No dia do ensaio, você estará com aproximadamente <strong>{confirmationAge}</strong>.</p> : null}<p>Código da reserva: <strong>{result.public_code}</strong></p>{result.pre_reservation ? <p>Enviamos por e-mail o link seguro para concluir o pagamento dentro do prazo.</p> : <p>Por enquanto você não precisa fazer mais nada. Próximo ao ensaio, enviaremos as orientações de preparação.</p>}</div> : null}
    </div>
  </section></main>
}
