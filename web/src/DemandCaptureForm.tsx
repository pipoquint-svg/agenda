import { FormEvent, useEffect, useMemo, useState } from 'react'
import { ApiError, getDemandConfig, submitDemand, type DemandConfig } from './api'

type Props = {
  brand: string
  campaign: string | null
}

type Fields = {
  name: string
  whatsapp: string
  email: string
  service_id: string
  desired_date: string
  desired_period: string
  notes: string
  consent_contact: boolean
}

type FieldErrors = Partial<Record<keyof Fields | 'form', string>>

const initialFields: Fields = {
  name: '',
  whatsapp: '',
  email: '',
  service_id: '',
  desired_date: '',
  desired_period: '',
  notes: '',
  consent_contact: false,
}

function maskWhatsapp(value: string): string {
  let digits = value.replace(/\D/g, '')
  if (digits.startsWith('55') && digits.length > 11) digits = digits.slice(2)
  digits = digits.slice(0, 11)
  if (digits.length <= 2) return digits ? `(${digits}` : ''
  const ddd = digits.slice(0, 2)
  const rest = digits.slice(2)
  if (rest.length <= 4) return `(${ddd}) ${rest}`
  if (rest.length <= 8) return `(${ddd}) ${rest.slice(0, 4)}-${rest.slice(4)}`
  return `(${ddd}) ${rest.slice(0, 5)}-${rest.slice(5)}`
}

function todaySaoPaulo(): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'America/Sao_Paulo',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date())
  const pick = (type: string) => parts.find((part) => part.type === type)?.value ?? ''
  return `${pick('year')}-${pick('month')}-${pick('day')}`
}

function messageForError(code: string): { field: keyof Fields | 'form'; message: string } {
  switch (code) {
    case 'NAME_INVALID': return { field: 'name', message: 'Informe seu nome.' }
    case 'WHATSAPP_INVALID': return { field: 'whatsapp', message: 'Informe um WhatsApp brasileiro válido, com DDD.' }
    case 'EMAIL_INVALID': return { field: 'email', message: 'Informe um e-mail válido.' }
    case 'SERVICE_INVALID': return { field: 'service_id', message: 'Selecione um serviço válido.' }
    case 'DESIRED_DATE_INVALID':
    case 'DESIRED_DATE_IN_PAST': return { field: 'desired_date', message: 'Escolha uma data de hoje em diante.' }
    case 'DESIRED_PERIOD_INVALID': return { field: 'desired_period', message: 'Selecione um período válido.' }
    case 'CONSENT_REQUIRED':
    case 'CONSENT_VERSION_REQUIRED': return { field: 'consent_contact', message: 'Autorize o contato para registrar seu interesse.' }
    case 'CONSENT_VERSION_STALE': return { field: 'consent_contact', message: 'O texto de autorização foi atualizado. Leia novamente e marque a caixa para continuar.' }
    case 'RATE_LIMITED': return { field: 'form', message: 'Muitas tentativas foram feitas. Tente novamente mais tarde.' }
    case 'BRAND_INVALID': return { field: 'form', message: 'Este formulário não está disponível para esta marca.' }
    default: return { field: 'form', message: 'Não foi possível registrar seu interesse. Tente novamente.' }
  }
}

export function DemandCaptureForm({ brand, campaign }: Props) {
  const [config, setConfig] = useState<DemandConfig | null>(null)
  const [fields, setFields] = useState<Fields>(initialFields)
  const [errors, setErrors] = useState<FieldErrors>({})
  const [loading, setLoading] = useState(true)
  const [submitting, setSubmitting] = useState(false)
  const [success, setSuccess] = useState(false)

  useEffect(() => {
    let active = true
    getDemandConfig()
      .then((value) => {
        if (!active) return
        setConfig(value)
        if (!brand || !value.brands.includes(brand)) {
          setErrors({ form: 'Este formulário não está disponível.' })
        }
      })
      .catch(() => active && setErrors({ form: 'Não foi possível carregar este formulário.' }))
      .finally(() => active && setLoading(false))
    return () => { active = false }
  }, [brand])

  const canSubmit = useMemo(
    () => Boolean(config && brand && config.brands.includes(brand) && !submitting),
    [config, brand, submitting],
  )

  function setField<K extends keyof Fields>(key: K, value: Fields[K]) {
    setFields((current) => ({ ...current, [key]: value }))
    setErrors((current) => ({ ...current, [key]: undefined, form: undefined }))
    setSuccess(false)
  }

  function validateClient(): FieldErrors {
    const next: FieldErrors = {}
    if (fields.name.trim().length < 2) next.name = 'Informe seu nome.'
    if (!fields.whatsapp.trim()) next.whatsapp = 'Informe seu WhatsApp.'
    if (!fields.email.trim()) next.email = 'Informe seu e-mail.'
    if (!fields.service_id) next.service_id = 'Selecione o serviço pretendido.'
    if (fields.desired_date && fields.desired_date < todaySaoPaulo()) next.desired_date = 'Escolha uma data de hoje em diante.'
    if (!fields.consent_contact) next.consent_contact = 'Autorize o contato para registrar seu interesse.'
    return next
  }

  async function onSubmit(event: FormEvent) {
    event.preventDefault()
    if (!canSubmit || !config) return
    const clientErrors = validateClient()
    if (Object.keys(clientErrors).length > 0) {
      setErrors(clientErrors)
      return
    }

    setSubmitting(true)
    setErrors({})
    try {
      await submitDemand({
        ...fields,
        desired_date: fields.desired_date || null,
        desired_period: fields.desired_period || null,
        notes: fields.notes.trim() || null,
        brand,
        campaign,
        consent_text_version: config.consent.version,
      })
      setFields(initialFields)
      setSuccess(true)
    } catch (error) {
      const code = error instanceof ApiError ? error.code : 'REQUEST_FAILED'
      if (code === 'CONSENT_VERSION_STALE') {
        try {
          const latest = await getDemandConfig()
          setConfig(latest)
          setFields((current) => ({ ...current, consent_contact: false }))
        } catch {
          setErrors({ form: 'Não foi possível atualizar o texto de autorização. Tente novamente.' })
          return
        }
      }
      const result = messageForError(code)
      setErrors({ [result.field]: result.message })
    } finally {
      setSubmitting(false)
    }
  }

  if (loading) return <main className="public-shell"><p role="status">Carregando formulário.</p></main>

  return (
    <main className="public-shell">
      <section className="demand-card" aria-labelledby="demand-title">
        <header className="demand-header">
          <h1 id="demand-title">Não encontrou o horário que procurava?</h1>
          <p>Registre seu interesse para que possamos entender quais datas e períodos têm maior procura.</p>
        </header>

        {errors.form && <div className="form-alert error" role="alert">{errors.form}</div>}
        {success && (
          <div className="form-alert success" role="status">
            Interesse registrado com sucesso. Este registro não garante disponibilidade ou reserva de horário.
          </div>
        )}

        {config && brand && config.brands.includes(brand) && (
          <form className="demand-form" onSubmit={onSubmit} noValidate>
            <label>
              <span>Nome</span>
              <input autoComplete="name" value={fields.name} onChange={(e) => setField('name', e.target.value)} aria-invalid={Boolean(errors.name)} />
              {errors.name && <small className="field-error">{errors.name}</small>}
            </label>

            <label>
              <span>WhatsApp</span>
              <input type="tel" inputMode="tel" autoComplete="tel" value={fields.whatsapp} onChange={(e) => setField('whatsapp', maskWhatsapp(e.target.value))} aria-invalid={Boolean(errors.whatsapp)} />
              {errors.whatsapp && <small className="field-error">{errors.whatsapp}</small>}
            </label>

            <label>
              <span>E-mail</span>
              <input type="email" autoComplete="email" value={fields.email} onChange={(e) => setField('email', e.target.value)} aria-invalid={Boolean(errors.email)} />
              {errors.email && <small className="field-error">{errors.email}</small>}
            </label>

            <label>
              <span>Serviço pretendido</span>
              <select value={fields.service_id} onChange={(e) => setField('service_id', e.target.value)} aria-invalid={Boolean(errors.service_id)}>
                <option value="">Selecione</option>
                {config.services.map((service) => <option key={service.id} value={service.id}>{service.name}</option>)}
              </select>
              {errors.service_id && <small className="field-error">{errors.service_id}</small>}
            </label>

            <label>
              <span>Data pretendida, opcional</span>
              <input type="date" min={todaySaoPaulo()} value={fields.desired_date} onChange={(e) => setField('desired_date', e.target.value)} aria-invalid={Boolean(errors.desired_date)} />
              {errors.desired_date && <small className="field-error">{errors.desired_date}</small>}
            </label>

            <label>
              <span>Período preferido, opcional</span>
              <select value={fields.desired_period} onChange={(e) => setField('desired_period', e.target.value)} aria-invalid={Boolean(errors.desired_period)}>
                <option value="">Sem preferência informada</option>
                <option value="MANHA">Manhã</option>
                <option value="TARDE">Tarde</option>
                <option value="NOITE">Noite</option>
                <option value="INDIFERENTE">Indiferente</option>
              </select>
              {errors.desired_period && <small className="field-error">{errors.desired_period}</small>}
            </label>

            <label className="wide">
              <span>Observação, opcional</span>
              <textarea rows={2} maxLength={300} value={fields.notes} onChange={(e) => setField('notes', e.target.value)} />
              <small className="counter">{fields.notes.length}/300</small>
            </label>

            <label className="consent wide">
              <input type="checkbox" checked={fields.consent_contact} onChange={(e) => setField('consent_contact', e.target.checked)} aria-invalid={Boolean(errors.consent_contact)} />
              <span>{config.consent.text}</span>
            </label>
            {errors.consent_contact && <small className="field-error wide">{errors.consent_contact}</small>}

            <button className="primary wide" type="submit" disabled={!canSubmit}>
              {submitting ? 'Registrando...' : 'Registrar interesse'}
            </button>
          </form>
        )}
      </section>
    </main>
  )
}
