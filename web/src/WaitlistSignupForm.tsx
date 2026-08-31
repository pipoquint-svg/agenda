import { FormEvent, useState } from 'react'
import { submitWaitlist, WaitlistApiError } from './waitlistApi'
import './waitlist.css'

type Props = {
  bookingPageSlug: string
  serviceId: string
  serviceName: string
}

function digits(value: string): string {
  return value.replace(/\D/g, '')
}

function errorMessage(error: unknown): string {
  if (error instanceof WaitlistApiError) {
    if (error.code === 'WAITLIST_ALREADY_REGISTERED') return 'Você já está na lista de espera para este serviço.'
    if (error.code === 'WAITLIST_EMAIL_INVALID') return 'Informe um e-mail válido.'
    if (error.code === 'WAITLIST_WHATSAPP_INVALID') return 'Informe um WhatsApp válido com DDD.'
    if (error.code === 'WAITLIST_NAME_INVALID') return 'Informe seu nome.'
    if (error.code === 'RATE_LIMITED') return 'Foram feitas muitas tentativas agora. Aguarde alguns minutos e tente novamente.'
  }
  return 'Não foi possível concluir sua inscrição agora. Tente novamente.'
}

export function WaitlistSignupForm({ bookingPageSlug, serviceId, serviceName }: Props) {
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [whatsapp, setWhatsapp] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)

  async function submit(event: FormEvent) {
    event.preventDefault()
    const cleanName = name.trim()
    const cleanEmail = email.trim().toLowerCase()
    const phoneDigits = digits(whatsapp)
    if (cleanName.length < 2) { setError('Informe seu nome.'); return }
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(cleanEmail)) { setError('Informe um e-mail válido.'); return }
    if (phoneDigits.length < 10 || phoneDigits.length > 15) { setError('Informe um WhatsApp válido com DDD.'); return }

    setSaving(true)
    setError('')
    try {
      await submitWaitlist({ bookingPageSlug, serviceId, name: cleanName, email: cleanEmail, whatsapp: whatsapp.trim() })
      setDone(true)
    } catch (cause) {
      setError(errorMessage(cause))
    } finally {
      setSaving(false)
    }
  }

  if (done) {
    return (
      <div className="waitlist-success" role="status">
        <strong>Inscrição recebida.</strong>
        <p>Nossa equipe vai acompanhar a lista de espera de <b>{serviceName}</b> e entrará em contato diretamente com você.</p>
      </div>
    )
  }

  return (
    <form className="waitlist-form" onSubmit={submit} noValidate>
      <div className="waitlist-heading">
        <strong>Quer entrar na lista de espera deste serviço?</strong>
        <p>A lista é para <b>{serviceName}</b>, sem vincular sua inscrição a uma data específica. O contato é feito manualmente pela nossa equipe.</p>
      </div>
      <div className="waitlist-fields">
        <label>Nome<input value={name} onChange={(event) => setName(event.target.value)} autoComplete="name" maxLength={160} /></label>
        <label>E-mail<input type="email" value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="email" maxLength={320} /></label>
        <label>WhatsApp<input inputMode="tel" value={whatsapp} onChange={(event) => setWhatsapp(event.target.value)} autoComplete="tel" maxLength={40} placeholder="(48) 99999-9999" /></label>
      </div>
      {error ? <div className="waitlist-error" role="alert">{error}</div> : null}
      <button className="primary waitlist-submit" type="submit" disabled={saving}>{saving ? 'Enviando…' : 'Entrar na lista de espera'}</button>
    </form>
  )
}