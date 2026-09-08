import { useEffect, useMemo, useState } from 'react'
import type { ExtraSelection } from './bookingApi'
import { BookingCheckoutSession } from './BookingCheckoutSession'
import { createPrivateInviteHold, loadPrivateInviteContext, type PrivateInviteContext } from './privateInviteApi'

const PRIVATE_SESSION_KEY = 'bs_waitlist_private_invite'

type StoredPrivateInviteSession = {
  inviteId: string
  slotId: string
}

type StoredCheckoutHold = {
  expiresAt?: string
}

function money(value: number | string): string {
  return new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' }).format(Number(value ?? 0))
}

function dateTime(value: string): string {
  return new Date(value).toLocaleString('pt-BR', {
    timeZone: 'America/Sao_Paulo',
    weekday: 'long',
    day: '2-digit',
    month: 'long',
    hour: '2-digit',
    minute: '2-digit',
  })
}

function readJson<T>(key: string): T | null {
  try {
    const raw = sessionStorage.getItem(key)
    return raw ? JSON.parse(raw) as T : null
  } catch {
    return null
  }
}

function rememberPrivateInviteSession(inviteId: string, slotId: string): void {
  try {
    sessionStorage.setItem(PRIVATE_SESSION_KEY, JSON.stringify({ inviteId, slotId } satisfies StoredPrivateInviteSession))
  } catch {
    // The checkout can still continue in-memory if storage is unavailable.
  }
}

function hasStoredCheckoutForInvite(inviteId: string): boolean {
  try {
    const privateSession = readJson<StoredPrivateInviteSession>(PRIVATE_SESSION_KEY)
    if (!privateSession || privateSession.inviteId !== inviteId) return false

    const hold = readJson<StoredCheckoutHold>('bs_checkout_hold')
    if (hold?.expiresAt && new Date(hold.expiresAt).getTime() <= Date.now()) {
      sessionStorage.removeItem('bs_checkout_hold')
    }

    const hasHold = Boolean(sessionStorage.getItem('bs_checkout_hold'))
    const hasManage = Boolean(sessionStorage.getItem('bs_appointment_manage'))
    if (!hasHold && !hasManage) sessionStorage.removeItem(PRIVATE_SESSION_KEY)
    return hasHold || hasManage
  } catch {
    return false
  }
}

export function WaitlistPrivateInvitePage({ accessToken }: { accessToken: string }) {
  const [context, setContext] = useState<PrivateInviteContext | null>(null)
  const [serviceId, setServiceId] = useState('')
  const [selectedSlotId, setSelectedSlotId] = useState('')
  const [peopleCount, setPeopleCount] = useState(1)
  const [selectedExtras, setSelectedExtras] = useState<Set<string>>(new Set())
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  const [checkoutStarted, setCheckoutStarted] = useState(false)

  async function load() {
    setLoading(true)
    setError('')
    try {
      const next = await loadPrivateInviteContext(accessToken)
      setContext(next)
      const hasStoredCheckout = hasStoredCheckoutForInvite(next.invite_id)
      setCheckoutStarted(next.availability === 'IN_PROGRESS' && hasStoredCheckout)

      if (next.mode === 'ROUND') {
        const openSlots = (next.slots ?? []).filter((slot) => slot.availability === 'OPEN')
        setSelectedSlotId((current) => {
          if (next.active_slot_id) return next.active_slot_id
          if (current && openSlots.some((slot) => slot.id === current)) return current
          return openSlots[0]?.id ?? ''
        })
      } else {
        setSelectedSlotId(next.slot_id ?? '')
      }

      setServiceId((current) => {
        if (current && next.services.some((item) => item.id === current)) return current
        const first = next.services[0]
        if (first) {
          setPeopleCount(first.minimum_people || 1)
          setSelectedExtras(new Set(first.extras.filter((extra) => extra.is_required).map((extra) => extra.id)))
          return first.id
        }
        return ''
      })
    } catch (cause) {
      const code = cause instanceof Error ? cause.message : 'WAITLIST_PRIVATE_INVITE_FAILED'
      setError(code === 'WAITLIST_PRIVATE_TOKEN_EXPIRED'
        ? 'Este convite privado expirou.'
        : code === 'WAITLIST_PRIVATE_TOKEN_INVALID'
          ? 'Este convite privado não é válido ou foi revogado.'
          : 'Não foi possível abrir este convite agora.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => { void load() }, [accessToken])

  const service = useMemo(() => context?.services.find((item) => item.id === serviceId) ?? null, [context, serviceId])
  const extraSelections: ExtraSelection[] = useMemo(() => service?.extras
    .filter((extra) => selectedExtras.has(extra.id))
    .map((extra) => ({ extra_id: extra.id, quantity: 1 })) ?? [], [service, selectedExtras])
  const displayedTotal = Number(service?.base_price ?? 0) + (service?.extras
    .filter((extra) => selectedExtras.has(extra.id))
    .reduce((sum, extra) => sum + Number(extra.price ?? 0), 0) ?? 0)
  const openRoundSlots = useMemo(() => context?.mode === 'ROUND'
    ? (context.slots ?? []).filter((slot) => slot.availability === 'OPEN')
    : [], [context])
  const selectedRoundSlot = useMemo(() => context?.mode === 'ROUND'
    ? (context.slots ?? []).find((slot) => slot.id === selectedSlotId) ?? null
    : null, [context, selectedSlotId])

  function chooseService(id: string) {
    const next = context?.services.find((item) => item.id === id)
    setServiceId(id)
    if (next) {
      setPeopleCount(next.minimum_people || 1)
      setSelectedExtras(new Set(next.extras.filter((extra) => extra.is_required).map((extra) => extra.id)))
    }
  }

  async function startCheckout() {
    if (!context || !service || context.availability !== 'OPEN') return
    if (context.mode === 'ROUND' && !selectedSlotId) return
    setSubmitting(true)
    setError('')
    try {
      const hold = await createPrivateInviteHold({
        accessToken,
        slotId: context.mode === 'ROUND' ? selectedSlotId : undefined,
        serviceId: service.id,
        extras: extraSelections,
        peopleCount,
      })
      sessionStorage.removeItem('bs_appointment_manage')
      sessionStorage.setItem('bs_checkout_hold', JSON.stringify({
        token: hold.checkout_hold_token,
        id: hold.checkout_hold_id,
        pageSlug: hold.booking_page_slug,
        serviceId: service.id,
        serviceName: hold.service_name,
        expiresAt: hold.expires_at,
      }))
      const claimedSlotId = hold.selected_slot_id ?? context.slot_id ?? selectedSlotId
      rememberPrivateInviteSession(context.invite_id, claimedSlotId)
      setCheckoutStarted(true)
      setContext((current) => current ? {
        ...current,
        availability: 'IN_PROGRESS',
        active_slot_id: claimedSlotId,
        slot_status: current.mode === 'SINGLE' ? 'CLAIMED' : current.slot_status,
      } : current)
      window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' })
    } catch (cause) {
      const code = cause instanceof Error ? cause.message : 'WAITLIST_PRIVATE_INVITE_FAILED'
      if (code === 'WAITLIST_PRIVATE_SLOT_TAKEN') {
        setError('Outra família iniciou a reserva desse horário antes de você. Os demais horários continuam disponíveis.')
        await load()
      } else if (code === 'WAITLIST_PRIVATE_INVITE_IN_PROGRESS' || code === 'WAITLIST_PRIVATE_INVITE_ALREADY_USED') {
        setError('Este convite já está ligado a uma reserva. Atualize a página para continuar.')
        await load()
      } else {
        setError('Não foi possível iniciar a reserva. Atualize o convite e tente novamente.')
      }
    } finally {
      setSubmitting(false)
    }
  }

  const canChoose = context?.availability === 'OPEN'
  const ownSlot = context?.mode === 'ROUND'
    ? (context.slots ?? []).find((slot) => slot.id === context.active_slot_id)
    : null

  return (
    <>
      <main className="booking-shell" style={{ maxWidth: 780, margin: '0 auto', paddingTop: 28, paddingBottom: 28 }}>
        <section className="booking-card" style={{ display: 'grid', gap: 20 }}>
          <div>
            <small style={{ textTransform: 'uppercase', letterSpacing: '.14em', opacity: .65 }}>Convite privado · Natal 2026</small>
            <h1 style={{ margin: '8px 0 6px' }}>{context?.mode === 'ROUND' ? 'Escolha uma das vagas liberadas para você' : 'Uma vaga especial foi liberada para você'}</h1>
            <p style={{ margin: 0, opacity: .78 }}>{context?.mode === 'ROUND'
              ? 'Estes horários não aparecem na agenda pública. Você pode escolher qualquer um que ainda esteja disponível.'
              : 'Este horário não aparece na agenda pública e só pode ser reservado por um convite válido.'}</p>
          </div>

          {loading ? <p>Carregando seu convite…</p> : null}
          {error ? <div role="alert" style={{ border: '1px solid #e2b8b8', borderRadius: 12, padding: 12, background: '#fff6f6' }}>{error}</div> : null}

          {context ? (
            <>
              {context.mode === 'SINGLE' && context.start_at ? (
                <div style={{ borderRadius: 14, padding: 16, background: '#f7f2e8' }}>
                  <strong style={{ display: 'block', fontSize: 18 }}>{dateTime(context.start_at)}</strong>
                  <span style={{ fontSize: 13, opacity: .7 }}>Convite válido até {dateTime(context.expires_at)}</span>
                </div>
              ) : (
                <div style={{ borderRadius: 14, padding: 16, background: '#f7f2e8' }}>
                  <strong style={{ display: 'block', fontSize: 18 }}>{openRoundSlots.length} {openRoundSlots.length === 1 ? 'horário disponível' : 'horários disponíveis'} agora</strong>
                  <span style={{ fontSize: 13, opacity: .7 }}>Convite válido até {dateTime(context.expires_at)}</span>
                </div>
              )}

              {context.availability === 'BOOKED' ? (
                <div><h2>Sua reserva já foi garantida</h2><p>{ownSlot ? `Horário escolhido: ${dateTime(ownSlot.start_at)}.` : 'Este convite já foi utilizado em uma reserva.'}</p></div>
              ) : context.availability === 'FILLED' ? (
                <div><h2>Esta vaga já foi preenchida</h2><p>Você continua na lista de espera e poderá receber um novo convite se outra oportunidade for liberada.</p></div>
              ) : context.availability === 'UNAVAILABLE' ? (
                <div><h2>Este convite não está mais disponível</h2><p>A rodada foi encerrada ou o prazo terminou.</p></div>
              ) : context.availability === 'NO_AVAILABLE' ? (
                <div>
                  <h2>Nenhum horário livre neste momento</h2>
                  <p>Alguma família pode estar finalizando uma reserva. Se o checkout não for concluído, o horário volta automaticamente.</p>
                  <button type="button" onClick={() => void load()} style={{ minHeight: 42, padding: '0 16px' }}>Verificar novamente</button>
                </div>
              ) : context.availability === 'CLAIMED' ? (
                <div>
                  <h2>Outra família está finalizando esta vaga</h2>
                  <p>Se a reserva não for concluída dentro do prazo, o horário poderá ficar disponível novamente.</p>
                  <button type="button" onClick={() => void load()} style={{ minHeight: 42, padding: '0 16px' }}>Verificar novamente</button>
                </div>
              ) : context.availability === 'IN_PROGRESS' && !checkoutStarted ? (
                <div>
                  <h2>Esta reserva já foi iniciada por este convite</h2>
                  <p>{ownSlot ? `Horário escolhido: ${dateTime(ownSlot.start_at)}. ` : ''}Por segurança, continue na mesma aba do navegador em que você iniciou a reserva. Se o prazo do checkout terminar sem conclusão, a vaga poderá voltar a ficar disponível.</p>
                  <button type="button" onClick={() => void load()} style={{ minHeight: 42, padding: '0 16px' }}>Verificar novamente</button>
                </div>
              ) : context.availability === 'IN_PROGRESS' || checkoutStarted ? (
                <div style={{ borderRadius: 14, padding: 16, background: '#f2f7f1' }}>
                  <strong>Seu horário está reservado temporariamente.</strong>
                  <p style={{ marginBottom: 0 }}>{ownSlot ? `${dateTime(ownSlot.start_at)} · ` : ''}Conclua seus dados e o pagamento na etapa abaixo para garantir a vaga.</p>
                </div>
              ) : canChoose ? (
                <>
                  {context.mode === 'ROUND' ? (
                    <div>
                      <div style={{ display: 'flex', flexWrap: 'wrap', justifyContent: 'space-between', gap: 10, alignItems: 'center' }}>
                        <h2 style={{ marginBottom: 10 }}>Escolha seu horário</h2>
                        <button type="button" onClick={() => void load()} style={{ minHeight: 36, padding: '0 12px' }}>Atualizar horários</button>
                      </div>
                      <div style={{ display: 'grid', gap: 10, gridTemplateColumns: 'repeat(auto-fit, minmax(210px, 1fr))' }}>
                        {openRoundSlots.map((slot) => (
                          <label key={slot.id} style={{ display: 'flex', gap: 10, alignItems: 'center', border: selectedSlotId === slot.id ? '2px solid #191919' : '1px solid #ddd', borderRadius: 14, padding: 14, cursor: 'pointer' }}>
                            <input type="radio" name="private-slot" checked={selectedSlotId === slot.id} onChange={() => setSelectedSlotId(slot.id)} />
                            <strong>{dateTime(slot.start_at)}</strong>
                          </label>
                        ))}
                      </div>
                    </div>
                  ) : null}

                  <div>
                    <h2 style={{ marginBottom: 10 }}>Escolha seu pacote</h2>
                    <div style={{ display: 'grid', gap: 10 }}>
                      {context.services.map((item) => (
                        <label key={item.id} style={{ display: 'flex', gap: 12, alignItems: 'center', border: serviceId === item.id ? '2px solid #191919' : '1px solid #ddd', borderRadius: 14, padding: 14, cursor: 'pointer' }}>
                          <input type="radio" name="private-service" checked={serviceId === item.id} onChange={() => chooseService(item.id)} />
                          <span style={{ flex: 1 }}><strong>{item.name}</strong></span>
                          <strong>{money(item.base_price)}</strong>
                        </label>
                      ))}
                    </div>
                  </div>

                  {service?.extras.length ? (
                    <div>
                      <h2 style={{ marginBottom: 10 }}>Adicionais</h2>
                      {service.extras.map((extra) => (
                        <label key={extra.id} style={{ display: 'flex', gap: 12, alignItems: 'flex-start', border: '1px solid #ddd', borderRadius: 14, padding: 14 }}>
                          <input type="checkbox" checked={selectedExtras.has(extra.id)} disabled={extra.is_required} onChange={(event) => setSelectedExtras((current) => {
                            const next = new Set(current)
                            if (event.target.checked) next.add(extra.id); else next.delete(extra.id)
                            return next
                          })} />
                          <span style={{ flex: 1 }}>
                            <strong>{extra.name}</strong>
                            {extra.description ? <small style={{ display: 'block', marginTop: 4, opacity: .7 }}>{extra.description}</small> : null}
                          </span>
                          <strong>+ {money(extra.price)}</strong>
                        </label>
                      ))}
                    </div>
                  ) : null}

                  {service ? (
                    <label style={{ display: 'grid', gap: 6, maxWidth: 220 }}>
                      <span>Número de pessoas</span>
                      <input type="number" min={service.minimum_people} max={service.maximum_people} value={peopleCount} onChange={(event) => setPeopleCount(Math.min(service.maximum_people, Math.max(service.minimum_people, Number(event.target.value) || service.minimum_people)))} style={{ minHeight: 42, padding: '0 10px' }} />
                    </label>
                  ) : null}

                  <div style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', justifyContent: 'space-between', gap: 14, borderTop: '1px solid #eee', paddingTop: 16 }}>
                    <div>
                      <small>Total selecionado</small>
                      <strong style={{ display: 'block', fontSize: 22 }}>{money(displayedTotal)}</strong>
                      {selectedRoundSlot ? <small style={{ display: 'block', marginTop: 4, opacity: .7 }}>{dateTime(selectedRoundSlot.start_at)}</small> : null}
                    </div>
                    <button type="button" disabled={submitting || !service || (context.mode === 'ROUND' && !selectedSlotId)} onClick={() => void startCheckout()} style={{ minHeight: 48, padding: '0 20px', fontWeight: 700 }}>
                      {submitting ? 'Reservando…' : context.mode === 'ROUND' ? 'Reservar horário escolhido' : 'Reservar esta vaga'}
                    </button>
                  </div>
                </>
              ) : null}
            </>
          ) : null}
        </section>
      </main>
      {checkoutStarted ? <BookingCheckoutSession /> : null}
    </>
  )
}
