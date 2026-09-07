import { useEffect, useMemo, useState } from 'react'
import type { ExtraSelection } from './bookingApi'
import { createPrivateInviteHold, loadPrivateInviteContext, type PrivateInviteContext } from './privateInviteApi'

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

function hasStoredCheckout(): boolean {
  try { return Boolean(sessionStorage.getItem('bs_checkout_hold') || sessionStorage.getItem('bs_appointment_manage')) } catch { return false }
}

export function WaitlistPrivateInvitePage({ accessToken }: { accessToken: string }) {
  const [context, setContext] = useState<PrivateInviteContext | null>(null)
  const [serviceId, setServiceId] = useState('')
  const [peopleCount, setPeopleCount] = useState(1)
  const [selectedExtras, setSelectedExtras] = useState<Set<string>>(new Set())
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState('')
  const [checkoutStarted, setCheckoutStarted] = useState(() => hasStoredCheckout())

  async function load() {
    setLoading(true)
    setError('')
    try {
      const next = await loadPrivateInviteContext(accessToken)
      setContext(next)
      if (!serviceId && next.services[0]) {
        setServiceId(next.services[0].id)
        setPeopleCount(next.services[0].minimum_people || 1)
        setSelectedExtras(new Set(next.services[0].extras.filter((extra) => extra.is_required).map((extra) => extra.id)))
      }
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
    setSubmitting(true)
    setError('')
    try {
      const hold = await createPrivateInviteHold({ accessToken, serviceId: service.id, extras: extraSelections, peopleCount })
      sessionStorage.setItem('bs_checkout_hold', JSON.stringify({
        token: hold.checkout_hold_token,
        id: hold.checkout_hold_id,
        pageSlug: hold.booking_page_slug,
        serviceId: service.id,
        serviceName: hold.service_name,
        expiresAt: hold.expires_at,
      }))
      setCheckoutStarted(true)
      setContext((current) => current ? { ...current, availability: 'IN_PROGRESS', slot_status: 'CLAIMED' } : current)
      window.scrollTo({ top: document.body.scrollHeight, behavior: 'smooth' })
    } catch (cause) {
      const code = cause instanceof Error ? cause.message : 'WAITLIST_PRIVATE_INVITE_FAILED'
      if (code === 'WAITLIST_PRIVATE_SLOT_TAKEN') {
        setContext((current) => current ? { ...current, availability: 'CLAIMED', slot_status: 'CLAIMED' } : current)
        setError('Outra família iniciou a reserva desta vaga antes de você. Se ela não concluir dentro do prazo, a vaga poderá voltar a ficar disponível.')
      } else {
        setError('Não foi possível iniciar a reserva. Atualize o convite e tente novamente.')
      }
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <main className="booking-shell" style={{ maxWidth: 780, margin: '0 auto', paddingTop: 28, paddingBottom: 28 }}>
      <section className="booking-card" style={{ display: 'grid', gap: 20 }}>
        <div>
          <small style={{ textTransform: 'uppercase', letterSpacing: '.14em', opacity: .65 }}>Convite privado · Natal 2026</small>
          <h1 style={{ margin: '8px 0 6px' }}>Uma vaga especial foi liberada para você</h1>
          <p style={{ margin: 0, opacity: .78 }}>Este horário não aparece na agenda pública e só pode ser reservado por um convite válido.</p>
        </div>

        {loading ? <p>Carregando seu convite…</p> : null}
        {error ? <div role="alert" style={{ border: '1px solid #e2b8b8', borderRadius: 12, padding: 12, background: '#fff6f6' }}>{error}</div> : null}

        {context ? (
          <>
            <div style={{ borderRadius: 14, padding: 16, background: '#f7f2e8' }}>
              <strong style={{ display: 'block', fontSize: 18 }}>{dateTime(context.start_at)}</strong>
              <span style={{ fontSize: 13, opacity: .7 }}>Convite válido até {dateTime(context.expires_at)}</span>
            </div>

            {context.availability === 'FILLED' ? (
              <div><h2>Esta vaga já foi preenchida</h2><p>Você continua na lista de espera e poderá receber um novo convite se outra oportunidade for liberada.</p></div>
            ) : context.availability === 'UNAVAILABLE' ? (
              <div><h2>Esta vaga não está mais disponível</h2><p>O convite foi encerrado ou o prazo terminou.</p></div>
            ) : context.availability === 'CLAIMED' ? (
              <div>
                <h2>Outra família está finalizando esta vaga</h2>
                <p>Se a reserva não for concluída dentro do prazo, o horário poderá ficar disponível novamente.</p>
                <button type="button" onClick={() => void load()} style={{ minHeight: 42, padding: '0 16px' }}>Verificar novamente</button>
              </div>
            ) : context.availability === 'IN_PROGRESS' || checkoutStarted ? (
              <div style={{ borderRadius: 14, padding: 16, background: '#f2f7f1' }}>
                <strong>Seu horário está reservado temporariamente.</strong>
                <p style={{ marginBottom: 0 }}>Conclua seus dados e o pagamento na etapa abaixo para garantir a vaga.</p>
              </div>
            ) : (
              <>
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
                  <div><small>Total selecionado</small><strong style={{ display: 'block', fontSize: 22 }}>{money(displayedTotal)}</strong></div>
                  <button type="button" disabled={submitting || !service} onClick={() => void startCheckout()} style={{ minHeight: 48, padding: '0 20px', fontWeight: 700 }}>
                    {submitting ? 'Reservando…' : 'Reservar esta vaga'}
                  </button>
                </div>
              </>
            )}
          </>
        ) : null}
      </section>
    </main>
  )
}
