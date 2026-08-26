import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import {
  loadOperationSettings,
  updateOperationSettings,
  type OperationScope,
  type OperationSettingsBundle,
  type OperationSettingsKey,
  type OperationSettingsPatch,
  type OperationSettingsValues,
} from './operationSettingsApi'
import { supabase } from './supabase'
import './operationSettingsAdmin.css'

const textKeys: OperationSettingsKey[] = [
  'public_name', 'public_email', 'public_phone', 'public_address', 'public_site_url', 'timezone', 'default_currency',
]
const numberKeys: OperationSettingsKey[] = [
  'checkout_hold_minutes', 'payment_hold_minutes', 'agency_hold_minutes', 'default_confirmation_percentage',
  'pix_discount_percent', 'default_slot_interval_minutes',
]
const settingKeys = [...textKeys, ...numberKeys]
const labels: Record<OperationSettingsKey, string> = {
  public_name: 'Nome exibido ao cliente',
  public_email: 'E-mail público',
  public_phone: 'Telefone público',
  public_address: 'Endereço / local',
  public_site_url: 'Site',
  timezone: 'Fuso horário',
  default_currency: 'Moeda',
  checkout_hold_minutes: 'Hold do checkout (min)',
  payment_hold_minutes: 'Hold de pagamento (min)',
  agency_hold_minutes: 'Hold administrativo (min)',
  default_confirmation_percentage: 'Confirmação padrão (%)',
  pix_discount_percent: 'Desconto PIX (%)',
  default_slot_interval_minutes: 'Intervalo padrão de slots (min)',
}

function emptyValues(): OperationSettingsValues {
  return {
    public_name: null,
    public_email: null,
    public_phone: null,
    public_address: null,
    public_site_url: null,
    timezone: null,
    default_currency: null,
    checkout_hold_minutes: null,
    payment_hold_minutes: null,
    agency_hold_minutes: null,
    default_confirmation_percentage: null,
    pix_discount_percent: null,
    default_slot_interval_minutes: null,
  }
}

function rawValues(bundle: OperationSettingsBundle): OperationSettingsValues {
  const values = emptyValues()
  const source = bundle.override ?? {}
  for (const key of settingKeys) values[key] = source[key] ?? null
  return values
}

function changedValues(bundle: OperationSettingsBundle, values: OperationSettingsValues): OperationSettingsPatch {
  const baseline = rawValues(bundle)
  const patch: OperationSettingsPatch = {}
  for (const key of settingKeys) {
    if (!Object.is(values[key], baseline[key])) patch[key] = values[key]
  }
  return patch
}

function errorMessage(error: unknown): string {
  const code = error instanceof Error ? error.message : ''
  if (code === 'ADMIN_PERMISSION_DENIED') return 'Sua sessão não possui permissão para editar configurações.'
  if (code === 'ADMIN_FINANCE_PERMISSION_REQUIRED') return 'Alterar desconto PIX exige permissão financeira.'
  if (code === 'OPERATION_SCOPE_INVALID') return 'Operação inválida.'
  return 'Não foi possível salvar as configurações.'
}

export function OperationSettingsAdmin() {
  const [authReady, setAuthReady] = useState(false)
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [scope, setScope] = useState<OperationScope>('BLACKSHEEP')
  const [bundle, setBundle] = useState<OperationSettingsBundle | null>(null)
  const [values, setValues] = useState<OperationSettingsValues>(emptyValues)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setAccessToken(data.session?.access_token ?? null)
      setAuthReady(true)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setAccessToken(session?.access_token ?? null)
      setAuthReady(true)
    })
    return () => listener.subscription.unsubscribe()
  }, [])

  const load = useCallback(async (token: string, operationScope: OperationScope) => {
    setLoading(true)
    setError('')
    setSuccess('')
    try {
      const next = await loadOperationSettings(operationScope, token)
      setBundle(next)
      setValues(rawValues(next))
    } catch (requestError) {
      setError(errorMessage(requestError))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    if (accessToken) void load(accessToken, scope)
  }, [accessToken, load, scope])

  const inheritedCount = useMemo(
    () => Object.values(values).filter((value) => value === null).length,
    [values],
  )
  const hasChanges = useMemo(() => bundle ? Object.keys(changedValues(bundle, values)).length > 0 : false, [bundle, values])

  function setText(key: OperationSettingsKey, value: string) {
    setValues((current) => ({ ...current, [key]: value.trim() === '' ? null : value }))
  }

  function setNumber(key: OperationSettingsKey, value: string) {
    setValues((current) => ({ ...current, [key]: value === '' ? null : Number(value) }))
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!accessToken || !bundle) return
    const patch = changedValues(bundle, values)
    if (Object.keys(patch).length === 0) {
      setSuccess('Nenhuma alteração para salvar.')
      return
    }
    setSaving(true)
    setError('')
    setSuccess('')
    try {
      const next = await updateOperationSettings(scope, patch, accessToken)
      setBundle(next)
      setValues(rawValues(next))
      setSuccess('Configurações salvas e auditadas.')
    } catch (requestError) {
      setError(errorMessage(requestError))
    } finally {
      setSaving(false)
    }
  }

  if (!authReady) return <main className="admin-shell"><p>Carregando acesso.</p></main>
  if (!accessToken) return <main className="admin-shell"><p>Entre pela Gestão para acessar Configurações.</p><a href="/admin">Voltar ao login</a></main>

  return (
    <main className="admin-shell operation-settings-shell">
      <header className="admin-title-row">
        <div>
          <span className="agenda-eyebrow">BlackSheep Agenda</span>
          <h1>Configurações gerais</h1>
          <p>Valores globais permanecem como base; cada operação pode sobrescrever apenas o que precisa.</p>
        </div>
        <div className="agenda-header-actions">
          <a className="secondary agenda-link-button" href="/admin/dashboard">Dashboard</a>
          <a className="secondary agenda-link-button" href="/admin/catalogo">Serviços</a>
          <a className="secondary agenda-link-button" href="/admin/funcionarios">Funcionários</a>
        </div>
      </header>

      <section className="settings-operation-switch" aria-label="Operação">
        <button type="button" className={scope === 'SABRINA' ? 'active' : ''} onClick={() => setScope('SABRINA')}>Sabrina</button>
        <button type="button" className={scope === 'BLACKSHEEP' ? 'active' : ''} onClick={() => setScope('BLACKSHEEP')}>BlackSheep</button>
      </section>

      {error ? <div className="form-alert error" role="alert">{error}</div> : null}
      {success ? <div className="form-alert success" role="status">{success}</div> : null}
      {loading || !bundle ? <p role="status">Carregando configurações.</p> : (
        <form className="operation-settings-form" onSubmit={submit}>
          <div className="settings-summary">
            <strong>{scope === 'SABRINA' ? 'Sabrina' : 'BlackSheep'}</strong>
            <span>{inheritedCount} de {textKeys.length + numberKeys.length} campos herdando o padrão global.</span>
            <small>Deixe um campo vazio para voltar a herdar o valor global. Reservas existentes não são alteradas.</small>
          </div>

          <section className="settings-card">
            <div><h2>Dados exibidos ao cliente</h2><p>Informações públicas da operação. Nenhum segredo é armazenado aqui.</p></div>
            <div className="settings-grid">
              {textKeys.map((key) => (
                <label key={key}>
                  <span>{labels[key]}</span>
                  <input
                    type={key === 'public_email' ? 'email' : key === 'public_site_url' ? 'url' : 'text'}
                    value={typeof values[key] === 'string' ? values[key] as string : ''}
                    placeholder={bundle.resolved[key] == null ? 'Herdar padrão global' : String(bundle.resolved[key])}
                    onChange={(event) => setText(key, event.target.value)}
                  />
                  {values[key] === null ? <small>Herdado: {bundle.resolved[key] == null ? 'não definido' : String(bundle.resolved[key])}</small> : <small>Override desta operação</small>}
                </label>
              ))}
            </div>
          </section>

          <section className="settings-card">
            <div><h2>Agenda e checkout</h2><p>Defaults operacionais. Overrides definidos diretamente em serviços continuam tendo precedência.</p></div>
            <div className="settings-grid">
              {numberKeys.map((key) => (
                <label key={key}>
                  <span>{labels[key]}</span>
                  <input
                    type="number"
                    min="0"
                    step={key.includes('percentage') || key === 'pix_discount_percent' ? '0.01' : '1'}
                    value={typeof values[key] === 'number' ? values[key] as number : ''}
                    placeholder={bundle.resolved[key] == null ? 'Herdar' : String(bundle.resolved[key])}
                    onChange={(event) => setNumber(key, event.target.value)}
                  />
                  {values[key] === null ? <small>Herdado: {bundle.resolved[key] == null ? 'não definido' : String(bundle.resolved[key])}</small> : <small>Override desta operação</small>}
                </label>
              ))}
            </div>
          </section>

          <section className="settings-card settings-links">
            <div><h2>Configurações relacionadas</h2><p>Regras específicas permanecem nos módulos responsáveis, sem duplicar editores.</p></div>
            <div>
              <a href="/admin/catalogo">Categorias, serviços, preços, extras e políticas</a>
              <a href="/admin/funcionarios">Horários, folgas e calendários de funcionários</a>
              <a href="/admin/clientes">Clientes e condições comerciais</a>
              <a href="/admin/cupons">Cupons e regras promocionais</a>
              <a href="/admin/notificacoes">Notificações e mensagens</a>
              <a href="/admin/aniversarios">Automação de aniversários</a>
              <a href="/admin/pagamentos">Cobranças e saldos</a>
              <a href="/admin/saude">Saúde operacional</a>
            </div>
          </section>

          <div className="settings-actions">
            <button className="secondary" type="button" disabled={saving || !hasChanges} onClick={() => accessToken && load(accessToken, scope)}>Descartar alterações</button>
            <button className="primary" type="submit" disabled={saving || !hasChanges}>{saving ? 'Salvando…' : 'Salvar configurações'}</button>
          </div>
        </form>
      )}
    </main>
  )
}