import { useEffect, useMemo, useState } from 'react'
import {
  bindCheckoutCustomer,
  clearCheckoutPackage,
  listCheckoutPackages,
  loadCheckoutContext,
  selectCheckoutPackage,
  setBookingRecoveryContact,
  submitBookingCheckout,
  type AppointmentCheckoutResult,
  type BookingField,
  type CheckoutContext,
  type CheckoutHold,
  type CheckoutPackage,
  type ServiceAnswer,
} from './bookingApi'

const money = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' })

function numeric(value: number | string | undefined): number {
  const parsed = Number(value ?? 0)
  return Number.isFinite(parsed) ? parsed : 0
}

function digits(value: string): string {
  return value.replace(/\D/g, '')
}

function readableError(error: unknown): string {
  const raw = error instanceof Error ? error.message : 'CHECKOUT_FAILED'
  const known: Array<[string, string]> = [
    ['CHECKOUT_HOLD_NOT_ACTIVE', 'O tempo de proteção terminou. Escolha o horário novamente.'],
    ['CUSTOMER_NAME_INVALID', 'Informe seu nome completo.'],
    ['CUSTOMER_EMAIL_INVALID', 'Informe um e-mail válido.'],
    ['CUSTOMER_PHONE_INVALID', 'Informe um WhatsApp válido.'],
    ['CUSTOMER_TAX_ID_INVALID', 'Informe um CPF ou CNPJ válido.'],
    ['CUSTOMER_IDENTITY_AMBIGUOUS', 'Encontramos mais de um cadastro com estes dados. Fale com a equipe para continuar.'],
    ['CUSTOMER_IDENTITY_CONFLICT', 'Os dados informados não correspondem ao cadastro já vinculado.'],
    ['REQUIRED_SERVICE_FIELDS_MISSING', 'Preencha todos os campos obrigatórios do serviço.'],
    ['INVALID_SERVICE_ANSWER_VALUE', 'Revise as informações específicas do serviço.'],
    ['TERMS_NOT_ACCEPTED', 'Aceite todos os termos para continuar.'],
    ['TERMS_CONFIGURATION_MISSING', 'Os termos deste serviço ainda não estão configurados.'],
    ['HOUR_PACKAGE_INSUFFICIENT_BALANCE', 'Este pacote não possui saldo suficiente para a reserva.'],
    ['RATE_LIMITED', 'Muitas tentativas em sequência. Tente novamente em alguns minutos.'],
  ]
  return known.find(([key]) => raw.includes(key))?.[1] ?? 'Não foi possível concluir esta etapa. Revise os dados e tente novamente.'
}

function selectOptions(field: BookingField): Array<{ value: string; label: string }> {
  if (!Array.isArray(field.options)) return []
  return field.options.flatMap((item) => {
    if (typeof item === 'string') return [{ value: item, label: item }]
    if (item && typeof item === 'object') {
      const row = item as Record<string, unknown>
      const value = typeof row.value === 'string' ? row.value : ''
      const label = typeof row.label === 'string' ? row.label : value
      return value ? [{ value, label }] : []
    }
    return []
  })
}

function FieldInput({ field, value, onChange }: {
  field: BookingField
  value: string | number | boolean | null | undefined
  onChange: (value: string | number | boolean | null) => void
}) {
  if (field.field_type === 'BOOLEAN') {
    return (
      <label className="checkout-checkbox">
        <input type="checkbox" checked={value === true} onChange={(event) => onChange(event.target.checked)} />
        <span>{field.label}{field.is_required ? ' *' : ''}</span>
      </label>
    )
  }

  if (field.field_type === 'SELECT') {
    return (
      <label>{field.label}{field.is_required ? ' *' : ''}
        <select value={typeof value === 'string' ? value : ''} onChange={(event) => onChange(event.target.value || null)} required={field.is_required}>
          <option value="">Selecione</option>
          {selectOptions(field).map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
        </select>
        {field.help_text ? <small>{field.help_text}</small> : null}
      </label>
    )
  }

  if (field.field_type === 'TEXTAREA') {
    return (
      <label>{field.label}{field.is_required ? ' *' : ''}
        <textarea value={typeof value === 'string' ? value : ''} placeholder={field.placeholder ?? undefined} onChange={(event) => onChange(event.target.value)} required={field.is_required} />
        {field.help_text ? <small>{field.help_text}</small> : null}
      </label>
    )
  }

  const type = field.field_type === 'DATE' ? 'date' : field.field_type === 'NUMBER' ? 'number' : 'text'
  return (
    <label>{field.label}{field.is_required ? ' *' : ''}
      <input
        type={type}
        value={typeof value === 'boolean' || value == null ? '' : String(value)}
        placeholder={field.placeholder ?? undefined}
        required={field.is_required}
        onChange={(event) => onChange(field.field_type === 'NUMBER' ? (event.target.value === '' ? null : Number(event.target.value)) : event.target.value)}
      />
      {field.help_text ? <small>{field.help_text}</small> : null}
    </label>
  )
}

export function BookingCheckout({ hold }: { hold: CheckoutHold }) {
  const [context, setContext] = useState<CheckoutContext | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [taxId, setTaxId] = useState('')
  const [recoveryEnabled, setRecoveryEnabled] = useState(true)
  const [binding, setBinding] = useState(false)
  const [customerBound, setCustomerBound] = useState(false)
  const [packages, setPackages] = useState<CheckoutPackage[]>([])
  const [packageId, setPackageId] = useState('')
  const [packageBusy, setPackageBusy] = useState(false)
  const [answers, setAnswers] = useState<Record<string, string | number | boolean | null>>({})
  const [acceptedTerms, setAcceptedTerms] = useState<Record<string, boolean>>({})
  const [submitting, setSubmitting] = useState(false)
  const [result, setResult] = useState<AppointmentCheckoutResult | null>(null)

  useEffect(() => {
    let active = true
    loadCheckoutContext(hold.checkout_hold_token)
      .then((data) => {
        if (!active) return
        setContext(data)
        setCustomerBound(data.customer_bound)
      })
      .catch((cause) => active && setError(readableError(cause)))
      .finally(() => active && setLoading(false))
    return () => { active = false }
  }, [hold.checkout_hold_token])

  useEffect(() => {
    if (!recoveryEnabled || digits(phone).length < 10 || result) return
    const timer = window.setTimeout(() => {
      setBookingRecoveryContact(hold.checkout_hold_token, phone, true).catch(() => undefined)
    }, 600)
    return () => window.clearTimeout(timer)
  }, [hold.checkout_hold_token, phone, recoveryEnabled, result])

  const requiredAnswersReady = useMemo(() => {
    if (!context) return false
    return context.fields.filter((field) => field.is_required).every((field) => {
      const value = answers[field.id]
      if (field.field_type === 'BOOLEAN') return value === true || value === false
      return value !== null && value !== undefined && String(value).trim() !== ''
    })
  }, [answers, context])

  const termsReady = useMemo(() => {
    if (!context?.service.requires_terms) return true
    return context.terms.length > 0 && context.terms.every((term) => acceptedTerms[term.id])
  }, [acceptedTerms, context])

  async function saveCustomer() {
    if (!context) return
    setBinding(true)
    setError(null)
    try {
      await bindCheckoutCustomer({
        token: hold.checkout_hold_token,
        name,
        email,
        phone,
        taxId,
        recoveryEnabled,
      })
      setCustomerBound(true)
      const available = await listCheckoutPackages(hold.checkout_hold_token)
      setPackages(available)
    } catch (cause) {
      setError(readableError(cause))
    } finally {
      setBinding(false)
    }
  }

  async function choosePackage(nextId: string) {
    setPackageBusy(true)
    setError(null)
    try {
      if (nextId) await selectCheckoutPackage(hold.checkout_hold_token, nextId)
      else await clearCheckoutPackage(hold.checkout_hold_token)
      setPackageId(nextId)
    } catch (cause) {
      setError(readableError(cause))
    } finally {
      setPackageBusy(false)
    }
  }

  async function submit() {
    if (!context || !customerBound || !requiredAnswersReady || !termsReady) return
    setSubmitting(true)
    setError(null)
    try {
      const payloadAnswers: ServiceAnswer[] = context.fields
        .filter((field) => answers[field.id] !== undefined && answers[field.id] !== null && answers[field.id] !== '')
        .map((field) => ({ service_field_id: field.id, value: answers[field.id] ?? null }))

      const appointment = await submitBookingCheckout({
        token: hold.checkout_hold_token,
        termVersionIds: context.terms.filter((term) => acceptedTerms[term.id]).map((term) => term.id),
        answers: payloadAnswers,
      })
      setResult(appointment)
      sessionStorage.removeItem('bs_checkout_hold')
      sessionStorage.setItem('bs_appointment_manage', JSON.stringify({
        appointmentId: appointment.appointment_id,
        publicCode: appointment.public_code,
        accessToken: appointment.access_token,
        status: appointment.status,
      }))
    } catch (cause) {
      setError(readableError(cause))
    } finally {
      setSubmitting(false)
    }
  }

  if (loading) return <section className="checkout-panel"><p>Preparando seus dados…</p></section>
  if (!context) return <section className="checkout-panel"><div className="form-alert error">{error ?? 'Checkout indisponível.'}</div></section>

  if (result) {
    return (
      <section className="checkout-panel checkout-result" aria-live="polite">
        <small>{result.status === 'CONFIRMED' ? 'Reserva confirmada' : 'Reserva criada'}</small>
        <h2>{context.service.name}</h2>
        <p>Código da reserva: <strong>{result.public_code}</strong></p>
        {result.status === 'CONFIRMED' ? (
          <p>Seu pacote cobriu a reserva e não há pagamento pendente.</p>
        ) : (
          <p>Falta concluir o pagamento de <strong>{money.format(numeric(result.cash_due))}</strong>. A próxima etapa será o pagamento.</p>
        )}
      </section>
    )
  }

  return (
    <section className="checkout-panel">
      <div className="checkout-heading">
        <small>Horário protegido</small>
        <h2>Complete sua reserva</h2>
        <p>Esses dados ficam vinculados a este horário enquanto o contador estiver ativo.</p>
      </div>

      {error ? <div className="form-alert error" role="alert">{error}</div> : null}

      <div className="checkout-section">
        <h3>Seus dados</h3>
        <div className="checkout-grid">
          <label>Nome completo *<input value={name} onChange={(event) => setName(event.target.value)} autoComplete="name" /></label>
          <label>E-mail *<input type="email" value={email} onChange={(event) => setEmail(event.target.value)} autoComplete="email" /></label>
          <label>WhatsApp *<input value={phone} onChange={(event) => setPhone(event.target.value)} inputMode="tel" autoComplete="tel" /></label>
          <label>CPF/CNPJ{context.require_tax_id ? ' *' : ''}<input value={taxId} onChange={(event) => setTaxId(event.target.value)} inputMode="numeric" /></label>
        </div>
        <label className="checkout-checkbox recovery-optin">
          <input type="checkbox" checked={recoveryEnabled} onChange={(event) => setRecoveryEnabled(event.target.checked)} />
          <span>Se eu não concluir, pode me enviar pelo WhatsApp um link para retomar minha escolha.</span>
        </label>
        {!customerBound ? (
          <button className="primary" type="button" disabled={binding} onClick={saveCustomer}>{binding ? 'Salvando…' : 'Continuar'}</button>
        ) : <div className="form-alert success">Dados vinculados ao horário protegido.</div>}
      </div>

      {customerBound && packages.length > 0 ? (
        <div className="checkout-section">
          <h3>Pacote de horas</h3>
          <p>Se quiser, use um pacote elegível nesta reserva. O pacote precisa cobrir todo o tempo aplicável.</p>
          <div className="package-list">
            <label className={`package-option ${packageId === '' ? 'selected' : ''}`}>
              <input type="radio" name="hour-package" checked={packageId === ''} disabled={packageBusy} onChange={() => choosePackage('')} />
              <span><strong>Não usar pacote</strong><small>Seguir com pagamento normal.</small></span>
            </label>
            {packages.map((item) => (
              <label className={`package-option ${packageId === item.hour_package_id ? 'selected' : ''} ${!item.usable ? 'disabled' : ''}`} key={item.hour_package_id}>
                <input type="radio" name="hour-package" checked={packageId === item.hour_package_id} disabled={packageBusy || !item.usable} onChange={() => choosePackage(item.hour_package_id)} />
                <span>
                  <strong>{item.name}</strong>
                  <small>Saldo: {Math.floor(item.available_seconds / 3600)}h {Math.floor((item.available_seconds % 3600) / 60)}min · consumo: {Math.floor(item.charged_seconds / 60)} min</small>
                  {item.is_special_period ? <small>Inclui acréscimo de tempo do período especial.</small> : null}
                  {numeric(item.cash_due) > 0 ? <small>Extras/ajustes em dinheiro: {money.format(numeric(item.cash_due))}</small> : null}
                </span>
              </label>
            ))}
          </div>
        </div>
      ) : null}

      {customerBound && context.fields.length > 0 ? (
        <div className="checkout-section">
          <h3>Informações do serviço</h3>
          <div className="checkout-grid">
            {context.fields.map((field) => (
              <FieldInput key={field.id} field={field} value={answers[field.id]} onChange={(value) => setAnswers((current) => ({ ...current, [field.id]: value }))} />
            ))}
          </div>
        </div>
      ) : null}

      {customerBound && context.terms.length > 0 ? (
        <div className="checkout-section">
          <h3>Termos</h3>
          <div className="terms-list">
            {context.terms.map((term) => (
              <div className="term-card" key={term.id}>
                <details><summary>{term.name} · versão {term.version}</summary><div className="term-content">{term.content}</div></details>
                <label className="checkout-checkbox">
                  <input type="checkbox" checked={acceptedTerms[term.id] ?? false} onChange={(event) => setAcceptedTerms((current) => ({ ...current, [term.id]: event.target.checked }))} />
                  <span>Li e aceito este termo.</span>
                </label>
              </div>
            ))}
          </div>
        </div>
      ) : null}

      {customerBound ? (
        <div className="checkout-submit-row">
          <div><small>Valor atual da reserva</small><strong>{money.format(numeric(context.summary.commercial_value))}</strong></div>
          <button className="primary" type="button" disabled={submitting || packageBusy || !requiredAnswersReady || !termsReady} onClick={submit}>
            {submitting ? 'Criando reserva…' : packageId ? 'Confirmar e continuar' : 'Continuar para pagamento'}
          </button>
        </div>
      ) : null}
    </section>
  )
}
