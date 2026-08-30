import { FormEvent, useEffect, useMemo, useState } from 'react'
import { ChangePolicyEditor, defaultChangePolicy } from './ChangePolicyEditor'
import {
  createService,
  listServiceSettings,
  removeService,
  saveChangePolicy,
  saveCustomFields,
  saveDurationConfiguration,
  saveServiceCatalog,
  saveServiceTiming,
  type ChangePolicy,
  type DurationPreset,
  type DurationPricingTier,
  type OperationScope,
  type ServiceCustomField,
  type ServiceFieldType,
  type ServiceSettings,
} from './serviceSettingsApi'
import { supabase } from './supabase'

function number(value: number | string | null | undefined): number {
  const next = Number(value ?? 0)
  return Number.isFinite(next) ? next : 0
}

function cloneService(service: ServiceSettings): ServiceSettings {
  return {
    ...service,
    slot_interval_minutes: Number(service.slot_interval_minutes ?? 30),
    custom_fields: (service.custom_fields ?? []).map((field) => ({
      ...field,
      options_json: Array.isArray(field.options_json) ? [...field.options_json] : null,
    })),
    pricing_tiers: service.pricing_tiers.map((tier) => ({ ...tier })),
    duration_presets: service.duration_presets.map((preset) => ({ ...preset })),
    change_policy: service.change_policy ? { ...service.change_policy } : { ...defaultChangePolicy },
  }
}

function slugify(value: string): string {
  return value.toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
}

function fieldKey(value: string): string {
  const next = slugify(value).replace(/-/g, '_')
  return /^[a-z]/.test(next) ? next.slice(0, 64) : `campo_${next}`.slice(0, 64)
}

function durationLabel(minutes: number): string {
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  if (!hours) return `${rest} min`
  if (!rest) return `${hours}h`
  return `${hours}h${String(rest).padStart(2, '0')}`
}

const slotIntervalOptions = Array.from({ length: 16 }, (_, index) => (index + 1) * 30)

const fieldTypes: Array<{ value: ServiceFieldType; label: string }> = [
  { value: 'TEXT', label: 'Texto curto' },
  { value: 'TEXTAREA', label: 'Texto longo' },
  { value: 'NUMBER', label: 'Número' },
  { value: 'DATE', label: 'Data' },
  { value: 'SELECT', label: 'Seleção única' },
  { value: 'MULTISELECT', label: 'Múltipla seleção' },
  { value: 'BOOLEAN', label: 'Sim / não' },
]

function Login({ onReady }: { onReady: (token: string) => void }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')

  async function submit(event: FormEvent) {
    event.preventDefault()
    setError('')
    const { data, error: signInError } = await supabase.auth.signInWithPassword({ email, password })
    if (signInError || !data.session) {
      setError('Não foi possível entrar com essas credenciais.')
      return
    }
    onReady(data.session.access_token)
  }

  return (
    <main className="admin-shell login-shell">
      <form className="login-card" onSubmit={submit}>
        <h1>BlackSheep Agenda</h1>
        <p>Configurações administrativas</p>
        <label><span>E-mail</span><input type="email" autoComplete="username" value={email} onChange={(event) => setEmail(event.target.value)} /></label>
        <label><span>Senha</span><input type="password" autoComplete="current-password" value={password} onChange={(event) => setPassword(event.target.value)} /></label>
        {error ? <div className="form-alert error">{error}</div> : null}
        <button className="primary" type="submit">Entrar</button>
      </form>
    </main>
  )
}

export function ServiceSettingsAdmin() {
  const [authReady, setAuthReady] = useState(false)
  const [accessToken, setAccessToken] = useState<string | null>(null)
  const [services, setServices] = useState<ServiceSettings[]>([])
  const [operation, setOperation] = useState<OperationScope>('BLACKSHEEP')
  const [selectedId, setSelectedId] = useState('')
  const [draft, setDraft] = useState<ServiceSettings | null>(null)
  const [creating, setCreating] = useState(false)
  const [newName, setNewName] = useState('')
  const [newSlug, setNewSlug] = useState('')
  const [loading, setLoading] = useState(false)
  const [saving, setSaving] = useState(false)
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')

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

  async function load(token = accessToken, preferredId?: string) {
    if (!token) return
    setLoading(true)
    setError('')
    try {
      const next = await listServiceSettings(token)
      setServices(next)
      const visible = next.filter((service) => service.operation_scope === operation)
      const requestedId = preferredId ?? selectedId
      const currentId = requestedId && visible.some((service) => service.id === requestedId) ? requestedId : visible[0]?.id ?? ''
      setSelectedId(currentId)
      const current = next.find((service) => service.id === currentId)
      setDraft(current ? cloneService(current) : null)
    } catch {
      setError('Não foi possível carregar os serviços.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (accessToken) void load(accessToken)
  }, [accessToken])

  useEffect(() => {
    const visible = services.filter((service) => service.operation_scope === operation)
    const current = visible.find((service) => service.id === selectedId) ?? visible[0] ?? null
    setSelectedId(current?.id ?? '')
    setDraft(current ? cloneService(current) : null)
    setCreating(false)
    setMessage('')
    setError('')
  }, [operation])

  const visibleServices = useMemo(
    () => services.filter((service) => service.operation_scope === operation),
    [services, operation],
  )
  const unclassifiedCount = useMemo(() => services.filter((service) => !service.operation_scope).length, [services])

  function selectService(id: string) {
    setSelectedId(id)
    const service = services.find((item) => item.id === id)
    setDraft(service ? cloneService(service) : null)
    setCreating(false)
    setMessage('')
    setError('')
  }

  function patch(values: Partial<ServiceSettings>) {
    setDraft((current) => current ? { ...current, ...values } : current)
  }

  async function createNewService(event: FormEvent) {
    event.preventDefault()
    if (!accessToken) return
    const name = newName.trim()
    const slug = (newSlug.trim() || slugify(name)).trim()
    if (!name || !slug) {
      setError('Informe nome e identificador do serviço.')
      return
    }
    setSaving(true)
    setError('')
    try {
      await createService({ name, slug, operation_scope: operation }, accessToken)
      setNewName('')
      setNewSlug('')
      setCreating(false)
      setMessage('Serviço criado. Agora configure duração, preço, políticas e campos de coleta.')
      await load(accessToken)
    } catch {
      setError('Não foi possível criar o serviço. Verifique se o identificador já existe.')
    } finally {
      setSaving(false)
    }
  }

  async function saveCatalog() {
    if (!draft || !accessToken || !draft.operation_scope) return
    setSaving(true)
    setError('')
    setMessage('')
    try {
      await saveServiceCatalog({
        service_id: draft.id,
        action: 'CATALOG',
        name: draft.name,
        slug: draft.slug,
        operation_scope: draft.operation_scope,
        short_description: draft.short_description,
        full_description: draft.full_description,
        is_active: draft.is_active,
        sort_order: draft.sort_order,
      }, accessToken)
      setMessage('Cadastro do serviço salvo.')
      await load(accessToken, draft.id)
    } catch {
      setError('Não foi possível salvar o cadastro do serviço.')
    } finally {
      setSaving(false)
    }
  }

  async function deleteOrArchive() {
    if (!draft || !accessToken) return
    setSaving(true)
    setError('')
    setMessage('')
    try {
      const result = await removeService(draft.id, accessToken)
      setMessage(result.archived ? 'Serviço possui histórico e foi arquivado com segurança.' : 'Serviço excluído.')
      setSelectedId('')
      setDraft(null)
      await load(accessToken)
    } catch {
      setError('Não foi possível remover o serviço.')
    } finally {
      setSaving(false)
    }
  }

  async function saveFields() {
    if (!draft || !accessToken) return
    setSaving(true)
    setError('')
    setMessage('')
    try {
      await saveCustomFields(draft.id, draft.custom_fields.map((field, index) => ({ ...field, sort_order: index * 10 })), accessToken)
      setMessage('Campos de coleta salvos para este serviço.')
      await load(accessToken, draft.id)
    } catch {
      setError('Não foi possível salvar os campos. Confira identificadores duplicados e opções.')
    } finally {
      setSaving(false)
    }
  }

  async function saveTiming() {
    if (!draft || !accessToken) return
    setSaving(true)
    setError('')
    setMessage('')
    try {
      await saveServiceTiming({
        service_id: draft.id,
        action: 'TIMING',
        duration_mode: draft.duration_mode,
        base_duration_minutes: Number(draft.base_duration_minutes),
        slot_interval_minutes: Number(draft.slot_interval_minutes ?? 30),
        booking_block_minutes: draft.duration_mode === 'BLOCKS' ? Number(draft.booking_block_minutes ?? 30) : null,
        minimum_booking_blocks: draft.duration_mode === 'BLOCKS' ? Number(draft.minimum_booking_blocks ?? 1) : null,
        maximum_booking_blocks: draft.duration_mode === 'BLOCKS' ? Number(draft.maximum_booking_blocks ?? 1) : null,
        base_price: number(draft.base_price),
        price_per_block: draft.duration_mode === 'BLOCKS' ? number(draft.price_per_block) : null,
        buffer_before_minutes: Number(draft.buffer_before_minutes),
        buffer_after_minutes: Number(draft.buffer_after_minutes),
      }, accessToken)
      setMessage('Duração, preço base, buffer e passo de agendamento salvos.')
      await load(accessToken, draft.id)
    } catch {
      setError('Não foi possível salvar duração, buffer e passo de agendamento. Confira os valores.')
    } finally {
      setSaving(false)
    }
  }

  async function saveCurve() {
    if (!draft || !accessToken || draft.duration_mode !== 'BLOCKS') return
    setSaving(true)
    setError('')
    setMessage('')
    try {
      await saveDurationConfiguration({
        service_id: draft.id,
        action: 'DURATION_CONFIGURATION',
        pricing_tiers: draft.pricing_tiers.map((tier, index) => ({ ...tier, sort_order: index * 10 })),
        duration_presets: draft.duration_presets.map((preset, index) => ({ ...preset, sort_order: index * 10 })),
      }, accessToken)
      setMessage('Curva de preço e recomendações salvas.')
      await load(accessToken, draft.id)
    } catch {
      setError('Não foi possível salvar a curva. Verifique faixas sobrepostas e limites de duração.')
    } finally {
      setSaving(false)
    }
  }

  async function savePolicy() {
    if (!draft || !accessToken || !draft.change_policy) return
    setSaving(true)
    setError('')
    setMessage('')
    try {
      await saveChangePolicy(draft.id, draft.change_policy, accessToken)
      setMessage('Política de remarcação e cancelamento salva para este serviço.')
      await load(accessToken, draft.id)
    } catch {
      setError('Não foi possível salvar a política. Confira multas, percentuais e janela de antecedência.')
    } finally {
      setSaving(false)
    }
  }

  function updateTier(index: number, values: Partial<DurationPricingTier>) {
    if (!draft) return
    patch({ pricing_tiers: draft.pricing_tiers.map((tier, tierIndex) => tierIndex === index ? { ...tier, ...values } : tier) })
  }

  function updatePreset(index: number, values: Partial<DurationPreset>) {
    if (!draft) return
    patch({ duration_presets: draft.duration_presets.map((preset, presetIndex) => presetIndex === index ? { ...preset, ...values } : preset) })
  }

  function updateField(index: number, values: Partial<ServiceCustomField>) {
    if (!draft) return
    patch({ custom_fields: draft.custom_fields.map((field, fieldIndex) => fieldIndex === index ? { ...field, ...values } : field) })
  }

  function addField() {
    if (!draft) return
    const index = draft.custom_fields.length + 1
    patch({ custom_fields: [...draft.custom_fields, {
      field_key: `campo_${index}`,
      label: 'Novo campo',
      field_type: 'TEXT',
      help_text: null,
      placeholder: null,
      is_required: false,
      sort_order: index * 10,
      options_json: null,
      is_active: true,
    }] })
  }

  function updatePolicy(policy: ChangePolicy) {
    patch({ change_policy: policy })
  }

  if (!authReady) return <main className="admin-shell"><p>Carregando acesso.</p></main>
  if (!accessToken) return <Login onReady={setAccessToken} />

  return (
    <main className="admin-shell settings-shell">
      <header className="admin-title-row settings-header">
        <div>
          <span className="agenda-eyebrow">BlackSheep Agenda</span>
          <h1>Serviços</h1>
          <p>Cadastre os serviços diretamente em cada operação e defina os dados que precisam ser coletados em cada um.</p>
        </div>
        <div className="agenda-header-actions">
          <a className="secondary agenda-link-button" href="/admin/agenda">Agenda</a>
          <button className="secondary" type="button" onClick={() => supabase.auth.signOut()}>Sair</button>
        </div>
      </header>

      <div className="settings-operation-tabs" role="tablist" aria-label="Operação">
        <button type="button" className={operation === 'SABRINA' ? 'active' : ''} onClick={() => setOperation('SABRINA')}>Sabrina Pierri</button>
        <button type="button" className={operation === 'BLACKSHEEP' ? 'active' : ''} onClick={() => setOperation('BLACKSHEEP')}>BlackSheep</button>
      </div>

      {unclassifiedCount > 0 ? <div className="form-alert">{unclassifiedCount} serviço(s) técnico(s)/legado(s) sem operação continuam preservados e não aparecem neste cadastro.</div> : null}
      {error ? <div className="form-alert error" role="alert">{error}</div> : null}
      {message ? <div className="form-alert success" role="status">{message}</div> : null}

      <div className="settings-layout">
        <aside className="settings-service-list">
          <div className="settings-card-heading"><h2>Serviços</h2><button className="secondary" type="button" onClick={() => setCreating(true)}>+ Serviço</button></div>
          {creating ? (
            <form className="settings-create-service" onSubmit={createNewService}>
              <label><span>Nome</span><input autoFocus value={newName} onChange={(event) => { setNewName(event.target.value); if (!newSlug) setNewSlug(slugify(event.target.value)) }} /></label>
              <label><span>Identificador</span><input value={newSlug} onChange={(event) => setNewSlug(slugify(event.target.value))} /></label>
              <div className="agenda-header-actions"><button className="primary" disabled={saving}>Criar</button><button className="secondary" type="button" onClick={() => setCreating(false)}>Cancelar</button></div>
            </form>
          ) : null}
          {loading ? <p>Carregando.</p> : visibleServices.map((service) => (
            <button type="button" key={service.id} className={service.id === selectedId ? 'active' : ''} onClick={() => selectService(service.id)}>
              <strong>{service.name}</strong>
              <span>{service.is_active ? 'Ativo' : 'Arquivado'} • {service.duration_mode === 'FIXED' ? 'duração fixa' : 'por tempo'}</span>
            </button>
          ))}
          {!loading && visibleServices.length === 0 ? <p className="empty-state">Nenhum serviço nesta operação.</p> : null}
        </aside>

        {draft ? (
          <div className="settings-editor">
            <section className="settings-card">
              <div className="settings-card-heading"><div><span className="agenda-eyebrow">{draft.operation_scope === 'SABRINA' ? 'Sabrina Pierri' : 'BlackSheep'}</span><h2>Cadastro do serviço</h2></div><span className="agenda-badge">{draft.is_active ? 'ATIVO' : 'ARQUIVADO'}</span></div>
              <div className="settings-field-grid">
                <label><span>Nome</span><input value={draft.name} onChange={(event) => patch({ name: event.target.value })} /></label>
                <label><span>Identificador</span><input value={draft.slug} onChange={(event) => patch({ slug: slugify(event.target.value) })} /></label>
                <label><span>Operação</span><select value={draft.operation_scope ?? operation} onChange={(event) => patch({ operation_scope: event.target.value as OperationScope })}><option value="SABRINA">Sabrina Pierri</option><option value="BLACKSHEEP">BlackSheep</option></select></label>
                <label><span>Ordem</span><input type="number" value={draft.sort_order} onChange={(event) => patch({ sort_order: Number(event.target.value) })} /></label>
                <label className="settings-check"><input type="checkbox" checked={draft.is_active} onChange={(event) => patch({ is_active: event.target.checked })} /><span>Serviço ativo</span></label>
                <label><span>Descrição curta</span><input value={draft.short_description ?? ''} onChange={(event) => patch({ short_description: event.target.value || null })} /></label>
              </div>
              <label><span>Descrição completa</span><textarea rows={3} value={draft.full_description ?? ''} onChange={(event) => patch({ full_description: event.target.value || null })} /></label>
              <div className="agenda-header-actions"><button className="primary" type="button" disabled={saving} onClick={() => void saveCatalog()}>Salvar cadastro</button><button className="danger-text" type="button" disabled={saving} onClick={() => void deleteOrArchive()}>Excluir / arquivar serviço</button></div>
              <small>Se o serviço já tiver reservas ou histórico, ele será arquivado em vez de apagado.</small>
            </section>

            <section className="settings-card">
              <div className="settings-card-heading"><div><h2>Campos de coleta</h2><p>Estes campos pertencem somente a este serviço. Sabrina e BlackSheep podem ter formulários completamente diferentes.</p></div><button className="secondary" type="button" onClick={addField}>+ Campo</button></div>
              <div className="settings-custom-fields">
                {draft.custom_fields.map((field, index) => (
                  <div className="settings-custom-field" key={field.id ?? `field-${index}`}>
                    <div className="settings-field-grid">
                      <label><span>Nome do campo</span><input value={field.label} onChange={(event) => updateField(index, { label: event.target.value, field_key: field.id ? field.field_key : fieldKey(event.target.value) })} /></label>
                      <label><span>Identificador</span><input value={field.field_key} onChange={(event) => updateField(index, { field_key: fieldKey(event.target.value) })} /></label>
                      <label><span>Tipo</span><select value={field.field_type} onChange={(event) => updateField(index, { field_type: event.target.value as ServiceFieldType, options_json: ['SELECT','MULTISELECT'].includes(event.target.value) ? field.options_json ?? [] : null })}>{fieldTypes.map((type) => <option key={type.value} value={type.value}>{type.label}</option>)}</select></label>
                      <label><span>Placeholder</span><input value={field.placeholder ?? ''} onChange={(event) => updateField(index, { placeholder: event.target.value || null })} /></label>
                      <label><span>Ajuda</span><input value={field.help_text ?? ''} onChange={(event) => updateField(index, { help_text: event.target.value || null })} /></label>
                      {['SELECT','MULTISELECT'].includes(field.field_type) ? <label><span>Opções</span><input placeholder="Opção 1, Opção 2" value={(field.options_json ?? []).join(', ')} onChange={(event) => updateField(index, { options_json: event.target.value.split(',').map((item) => item.trim()).filter(Boolean) })} /></label> : null}
                      <label className="settings-check"><input type="checkbox" checked={field.is_required} onChange={(event) => updateField(index, { is_required: event.target.checked })} /><span>Obrigatório</span></label>
                      <label className="settings-check"><input type="checkbox" checked={field.is_active} onChange={(event) => updateField(index, { is_active: event.target.checked })} /><span>Ativo</span></label>
                    </div>
                    <button className="danger-text" type="button" onClick={() => patch({ custom_fields: draft.custom_fields.filter((_, fieldIndex) => fieldIndex !== index) })}>Remover campo</button>
                  </div>
                ))}
                {draft.custom_fields.length === 0 ? <p className="empty-state">Nenhum campo personalizado. O serviço usará somente os dados comuns do checkout.</p> : null}
              </div>
              <button className="primary" type="button" disabled={saving} onClick={() => void saveFields()}>{saving ? 'Salvando…' : 'Salvar campos de coleta'}</button>
            </section>

            <section className="settings-card">
              <div className="settings-card-heading"><div><h2>Duração e preço</h2><p>Regras independentes deste serviço.</p></div><span className="agenda-badge">{draft.duration_mode}</span></div>
              <div className="settings-field-grid">
                <label><span>Modelo de duração</span><select value={draft.duration_mode} onChange={(event) => patch({ duration_mode: event.target.value as 'FIXED' | 'BLOCKS' })}><option value="FIXED">Duração fixa</option><option value="BLOCKS">Cliente escolhe o tempo</option></select></label>
                <label><span>Duração base (min)</span><input type="number" min="1" value={draft.base_duration_minutes} onChange={(event) => patch({ base_duration_minutes: Number(event.target.value) })} /></label>
                <label><span>Passo de agendamento</span><select value={draft.slot_interval_minutes ?? 30} onChange={(event) => patch({ slot_interval_minutes: Number(event.target.value) })}>{slotIntervalOptions.map((minutes) => <option key={minutes} value={minutes}>{durationLabel(minutes)}</option>)}</select></label>
                <label><span>Preço base (R$)</span><input type="number" min="0" step="0.01" value={number(draft.base_price)} onChange={(event) => patch({ base_price: Number(event.target.value) })} /></label>
                <label><span>Buffer antes (min)</span><input type="number" min="0" step="5" value={draft.buffer_before_minutes} onChange={(event) => patch({ buffer_before_minutes: Number(event.target.value) })} /></label>
                <label><span>Buffer depois (min)</span><input type="number" min="0" step="5" value={draft.buffer_after_minutes} onChange={(event) => patch({ buffer_after_minutes: Number(event.target.value) })} /></label>
              </div>
              {(draft.slot_interval_minutes ?? 30) < draft.base_duration_minutes ? <div className="form-alert">O passo de agendamento é menor que a duração do serviço. Isso é permitido; a trava de conflito continua sendo aplicada normalmente.</div> : null}
              {draft.duration_mode === 'FIXED' ? <div className="settings-rule-callout"><strong>Agenda</strong><span>{durationLabel(draft.base_duration_minutes)} para o cliente + {draft.buffer_after_minutes} min de buffer depois.</span></div> : (
                <div className="settings-field-grid settings-block-grid">
                  <label><span>Tamanho do bloco (min)</span><input type="number" min="1" value={draft.booking_block_minutes ?? 30} onChange={(event) => patch({ booking_block_minutes: Number(event.target.value) })} /></label>
                  <label><span>Mínimo de blocos</span><input type="number" min="1" value={draft.minimum_booking_blocks ?? 1} onChange={(event) => patch({ minimum_booking_blocks: Number(event.target.value) })} /></label>
                  <label><span>Máximo de blocos</span><input type="number" min="1" value={draft.maximum_booking_blocks ?? 1} onChange={(event) => patch({ maximum_booking_blocks: Number(event.target.value) })} /></label>
                  <label><span>Preço/bloco fallback (R$)</span><input type="number" min="0" step="0.01" value={number(draft.price_per_block)} onChange={(event) => patch({ price_per_block: Number(event.target.value) })} /></label>
                </div>
              )}
              <button className="primary" type="button" disabled={saving} onClick={() => void saveTiming()}>{saving ? 'Salvando…' : 'Salvar duração, buffer e passo'}</button>
            </section>

            {draft.duration_mode === 'BLOCKS' ? <>
              <section className="settings-card">
                <div className="settings-card-heading"><div><h2>Preço progressivo</h2></div><button className="secondary" type="button" onClick={() => patch({ pricing_tiers: [...draft.pricing_tiers, { min_blocks: Math.max(1, (draft.pricing_tiers.at(-1)?.max_blocks ?? 1) + 1), max_blocks: null, price_per_block: number(draft.price_per_block), is_active: true, sort_order: draft.pricing_tiers.length * 10 }] })}>+ Faixa</button></div>
                <div className="settings-tier-list">{draft.pricing_tiers.map((tier, index) => <div className="settings-tier-row" key={tier.id ?? `tier-${index}`}><label><span>De blocos</span><input type="number" min="1" value={tier.min_blocks} onChange={(event) => updateTier(index, { min_blocks: Number(event.target.value) })} /></label><label><span>Até</span><input type="number" min={tier.min_blocks} value={tier.max_blocks ?? ''} onChange={(event) => updateTier(index, { max_blocks: event.target.value ? Number(event.target.value) : null })} /></label><label><span>R$/bloco</span><input type="number" min="0" step="0.01" value={number(tier.price_per_block)} onChange={(event) => updateTier(index, { price_per_block: Number(event.target.value) })} /></label><button className="danger-text" type="button" onClick={() => patch({ pricing_tiers: draft.pricing_tiers.filter((_, tierIndex) => tierIndex !== index) })}>Remover</button></div>)}</div>
              </section>
              <section className="settings-card">
                <div className="settings-card-heading"><div><h2>Tempos recomendados</h2></div><button className="secondary" type="button" onClick={() => patch({ duration_presets: [...draft.duration_presets, { block_count: draft.minimum_booking_blocks ?? 2, title: 'Novo tempo', description: null, badge: null, is_featured: false, is_active: true, sort_order: draft.duration_presets.length * 10 }] })}>+ Recomendação</button></div>
                <div className="settings-preset-list">{draft.duration_presets.map((preset, index) => <div className="settings-preset-row" key={preset.id ?? `preset-${index}`}><label><span>Blocos</span><input type="number" value={preset.block_count} onChange={(event) => updatePreset(index, { block_count: Number(event.target.value) })} /></label><label><span>Título</span><input value={preset.title} onChange={(event) => updatePreset(index, { title: event.target.value })} /></label><label><span>Descrição</span><input value={preset.description ?? ''} onChange={(event) => updatePreset(index, { description: event.target.value || null })} /></label><label><span>Selo</span><input value={preset.badge ?? ''} onChange={(event) => updatePreset(index, { badge: event.target.value || null })} /></label><label className="settings-check"><input type="checkbox" checked={preset.is_featured} onChange={(event) => updatePreset(index, { is_featured: event.target.checked })} /><span>Destaque</span></label><button className="danger-text" type="button" onClick={() => patch({ duration_presets: draft.duration_presets.filter((_, presetIndex) => presetIndex !== index) })}>Remover</button></div>)}</div>
                <button className="primary" type="button" disabled={saving} onClick={() => void saveCurve()}>Salvar curva e recomendações</button>
              </section>
            </> : null}

            <ChangePolicyEditor policy={draft.change_policy ?? defaultChangePolicy} saving={saving} onChange={updatePolicy} onSave={() => void savePolicy()} />
          </div>
        ) : <section className="settings-card"><p>Cadastre ou selecione um serviço em {operation === 'SABRINA' ? 'Sabrina Pierri' : 'BlackSheep'}.</p></section>}
      </div>
    </main>
  )
}