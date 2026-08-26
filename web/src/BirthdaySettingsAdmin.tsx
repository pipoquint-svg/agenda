import { FormEvent, useCallback, useEffect, useMemo, useState } from 'react'
import { functionsBaseUrl, publicApiKey, supabase } from './supabase'

type OperationScope = 'SABRINA' | 'BLACKSHEEP'
type BirthdaySettings = {
  id: string
  operation_scope: OperationScope
  is_active: boolean
  send_message: boolean
  generate_coupon: boolean
  send_on_birthday: boolean
  days_before: number | null
  coupon_prefix: string | null
  coupon_discount_type: 'PERCENT' | 'FIXED' | null
  coupon_discount_value: number | string | null
  coupon_validity_days: number | null
  coupon_max_uses: number | null
  coupon_max_uses_per_customer: number | null
  updated_at: string
}

type SettingsResponse = { settings: BirthdaySettings[] }

function clone(row: BirthdaySettings): BirthdaySettings {
  return { ...row }
}

async function api<T>(token: string, init?: RequestInit): Promise<T> {
  const response = await fetch(`${functionsBaseUrl}/admin-birthday-settings`, {
    ...init,
    headers: {
      apikey: publicApiKey,
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      ...(init?.headers ?? {}),
    },
  })
  const body = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(body?.error?.code ?? `HTTP_${response.status}`)
  return body as T
}

function nullableNumber(value: string): number | null {
  if (value.trim() === '') return null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

function errorMessage(error: unknown): string {
  const code = error instanceof Error ? error.message : ''
  if (code === 'ADMIN_PERMISSION_DENIED') return 'Sua sessão não possui permissão para alterar aniversários.'
  if (code === 'ADMIN_FINANCE_PERMISSION_REQUIRED') return 'Alterar regras do cupom exige permissão financeira.'
  if (code.startsWith('ADMIN_AUTH_') || code === 'ADMIN_ACCESS_DENIED') return 'Sua sessão administrativa expirou ou não possui acesso.'
  return `Não foi possível salvar a configuração${code ? ` (${code})` : ''}.`
}

export function BirthdaySettingsAdmin() {
  const [authReady, setAuthReady] = useState(false)
  const [token, setToken] = useState<string | null>(null)
  const [settings, setSettings] = useState<BirthdaySettings[]>([])
  const [scope, setScope] = useState<OperationScope>('BLACKSHEEP')
  const [draft, setDraft] = useState<BirthdaySettings | null>(null)
  const [baseline, setBaseline] = useState<BirthdaySettings | null>(null)
  const [activationAcknowledged, setActivationAcknowledged] = useState(false)
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [message, setMessage] = useState('')

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setToken(data.session?.access_token ?? null)
      setAuthReady(true)
    })
    const { data: listener } = supabase.auth.onAuthStateChange((_event, session) => {
      setToken(session?.access_token ?? null)
      setAuthReady(true)
    })
    return () => listener.subscription.unsubscribe()
  }, [])

  const selectRow = useCallback((rows: BirthdaySettings[], operationScope: OperationScope) => {
    const row = rows.find((item) => item.operation_scope === operationScope) ?? null
    setDraft(row ? clone(row) : null)
    setBaseline(row ? clone(row) : null)
    setActivationAcknowledged(false)
  }, [])

  const load = useCallback(async (accessToken: string, operationScope: OperationScope) => {
    setLoading(true)
    setError('')
    try {
      const response = await api<SettingsResponse>(accessToken)
      setSettings(response.settings ?? [])
      selectRow(response.settings ?? [], operationScope)
    } catch (cause) {
      setError(errorMessage(cause))
    } finally {
      setLoading(false)
    }
  }, [selectRow])

  useEffect(() => {
    if (token) void load(token, scope)
  }, [load, scope, token])

  const isEnabling = Boolean(draft?.is_active && !baseline?.is_active)
  const hasChanges = useMemo(() => {
    if (!draft || !baseline) return false
    const keys: Array<keyof BirthdaySettings> = [
      'is_active', 'send_message', 'generate_coupon', 'send_on_birthday', 'days_before', 'coupon_prefix',
      'coupon_discount_type', 'coupon_discount_value', 'coupon_validity_days', 'coupon_max_uses', 'coupon_max_uses_per_customer',
    ]
    return keys.some((key) => String(draft[key] ?? '') !== String(baseline[key] ?? ''))
  }, [baseline, draft])

  function patch(values: Partial<BirthdaySettings>) {
    setDraft((current) => current ? { ...current, ...values } : current)
    setMessage('')
  }

  async function submit(event: FormEvent) {
    event.preventDefault()
    if (!token || !draft || !hasChanges) return
    if (isEnabling && !activationAcknowledged) {
      setError('Confirme que entende que ativar a automação muda o comportamento do scheduler.')
      return
    }
    setSaving(true)
    setError('')
    setMessage('')
    try {
      await api(token, {
        method: 'PUT',
        body: JSON.stringify({
          operation_scope: draft.operation_scope,
          is_active: draft.is_active,
          send_message: draft.send_message,
          generate_coupon: draft.generate_coupon,
          send_on_birthday: draft.send_on_birthday,
          days_before: draft.days_before,
          coupon_prefix: draft.coupon_prefix,
          coupon_discount_type: draft.coupon_discount_type,
          coupon_discount_value: draft.coupon_discount_value == null || draft.coupon_discount_value === '' ? null : Number(draft.coupon_discount_value),
          coupon_validity_days: draft.coupon_validity_days,
          coupon_max_uses: draft.coupon_max_uses,
          coupon_max_uses_per_customer: draft.coupon_max_uses_per_customer,
        }),
      })
      setMessage('Configuração salva e auditada. Nenhum ciclo foi executado por esta ação.')
      await load(token, scope)
    } catch (cause) {
      setError(errorMessage(cause))
    } finally {
      setSaving(false)
    }
  }

  if (!authReady) return <main className="admin-shell"><p>Carregando acesso.</p></main>
  if (!token) return <main className="admin-shell"><h1>Aniversários</h1><p>Entre pela Gestão para acessar esta área.</p><a href="/admin">Voltar ao login</a></main>

  return <main className="admin-shell settings-shell">
    <header className="admin-title-row settings-header">
      <div>
        <span className="agenda-eyebrow">BlackSheep Agenda</span>
        <h1>Aniversários</h1>
        <p>Configuração administrativa do ciclo de aniversário. Salvar não executa o scheduler, não gera cupom e não envia mensagem.</p>
      </div>
      <div className="agenda-header-actions">
        <a className="secondary agenda-link-button" href="/admin/configuracoes">Configurações</a>
        <a className="secondary agenda-link-button" href="/admin/notificacoes">Notificações</a>
        <a className="secondary agenda-link-button" href="/admin/cupons">Cupons</a>
      </div>
    </header>

    <div className="settings-operation-tabs" role="tablist" aria-label="Operação">
      <button type="button" className={scope === 'SABRINA' ? 'active' : ''} onClick={() => setScope('SABRINA')}>Sabrina</button>
      <button type="button" className={scope === 'BLACKSHEEP' ? 'active' : ''} onClick={() => setScope('BLACKSHEEP')}>BlackSheep</button>
    </div>

    {error ? <div className="form-alert error" role="alert">{error}</div> : null}
    {message ? <div className="form-alert success" role="status">{message}</div> : null}
    {loading ? <p role="status">Carregando configuração.</p> : null}

    {!loading && !draft ? <div className="form-alert error">Configuração de aniversário não encontrada para esta operação.</div> : null}
    {!loading && draft ? <form className="settings-editor" onSubmit={submit}>
      <section className="settings-card">
        <div className="settings-card-heading">
          <div><h2>Execução</h2><p>Todos os controles permanecem exatamente como estão até você salvar uma alteração explícita.</p></div>
          <span className={`agenda-badge ${draft.is_active ? 'agenda-badge-confirmed' : 'agenda-badge-cancelled'}`}>{draft.is_active ? 'Ativa' : 'Desligada'}</span>
        </div>
        <div className="settings-field-grid">
          <label className="settings-check"><input type="checkbox" checked={draft.is_active} onChange={(e) => { patch({ is_active: e.target.checked }); setActivationAcknowledged(false) }} />Automação ativa</label>
          <label className="settings-check"><input type="checkbox" checked={draft.send_message} onChange={(e) => patch({ send_message: e.target.checked })} />Gerar entrega de mensagem</label>
          <label className="settings-check"><input type="checkbox" checked={draft.generate_coupon} onChange={(e) => patch({ generate_coupon: e.target.checked })} />Gerar cupom</label>
          <label className="settings-check"><input type="checkbox" checked={draft.send_on_birthday} onChange={(e) => patch({ send_on_birthday: e.target.checked })} />Executar no dia do aniversário</label>
          <label><span>Dias antes</span><input type="number" min="0" value={draft.days_before ?? ''} onChange={(e) => patch({ days_before: nullableNumber(e.target.value) })} /></label>
        </div>
        {isEnabling ? <div className="form-alert">
          <strong>Atenção:</strong> ativar esta automação muda o comportamento do scheduler diário.
          <label className="settings-check"><input type="checkbox" checked={activationAcknowledged} onChange={(e) => setActivationAcknowledged(e.target.checked)} />Confirmo que desejo habilitar a automação desta operação.</label>
        </div> : null}
      </section>

      <section className="settings-card">
        <div><h2>Cupom de aniversário</h2><p>Estes campos exigem permissão financeira quando são alterados. O backend continua sendo a autoridade da regra.</p></div>
        <div className="settings-field-grid">
          <label><span>Prefixo</span><input value={draft.coupon_prefix ?? ''} onChange={(e) => patch({ coupon_prefix: e.target.value || null })} /></label>
          <label><span>Tipo de desconto</span><select value={draft.coupon_discount_type ?? ''} onChange={(e) => patch({ coupon_discount_type: (e.target.value || null) as BirthdaySettings['coupon_discount_type'] })}><option value="">Não definido</option><option value="PERCENT">Percentual</option><option value="FIXED">Valor fixo</option></select></label>
          <label><span>Valor do desconto</span><input type="number" min="0" step="0.01" value={draft.coupon_discount_value ?? ''} onChange={(e) => patch({ coupon_discount_value: e.target.value === '' ? null : Number(e.target.value) })} /></label>
          <label><span>Validade (dias)</span><input type="number" min="0" value={draft.coupon_validity_days ?? ''} onChange={(e) => patch({ coupon_validity_days: nullableNumber(e.target.value) })} /></label>
          <label><span>Uso máximo total</span><input type="number" min="0" value={draft.coupon_max_uses ?? ''} onChange={(e) => patch({ coupon_max_uses: nullableNumber(e.target.value) })} /></label>
          <label><span>Uso máximo por cliente</span><input type="number" min="0" value={draft.coupon_max_uses_per_customer ?? ''} onChange={(e) => patch({ coupon_max_uses_per_customer: nullableNumber(e.target.value) })} /></label>
        </div>
      </section>

      <section className="settings-card">
        <h2>Estado atual</h2>
        <p>Última atualização: {new Date(draft.updated_at).toLocaleString('pt-BR')}</p>
        <p>Alterar esta tela apenas persiste configuração auditada; não chama provider externo e não executa um ciclo de aniversário.</p>
      </section>

      <div className="settings-actions">
        <button className="secondary" type="button" disabled={saving || !hasChanges} onClick={() => baseline && setDraft(clone(baseline))}>Descartar alterações</button>
        <button className="primary" type="submit" disabled={saving || !hasChanges || (isEnabling && !activationAcknowledged)}>{saving ? 'Salvando…' : 'Salvar configuração'}</button>
      </div>
    </form> : null}
  </main>
}
