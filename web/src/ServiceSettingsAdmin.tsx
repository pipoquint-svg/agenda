import { FormEvent, useEffect, useMemo, useState } from 'react'
import { ChangePolicyEditor, defaultChangePolicy } from './ChangePolicyEditor'
import {
  listServiceSettings,
  saveChangePolicy,
  saveDurationConfiguration,
  saveServiceTiming,
  type ChangePolicy,
  type DurationPreset,
  type DurationPricingTier,
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
    pricing_tiers: service.pricing_tiers.map((tier) => ({ ...tier })),
    duration_presets: service.duration_presets.map((preset) => ({ ...preset })),
    change_policy: service.change_policy ? { ...service.change_policy } : { ...defaultChangePolicy },
  }
}

function durationLabel(minutes: number): string {
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  if (!hours) return `${rest} min`
  if (!rest) return `${hours}h`
  return `${hours}h${String(rest).padStart(2, '0')}`
}

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
  const [selectedId, setSelectedId] = useState('')
  const [draft, setDraft] = useState<ServiceSettings | null>(null)
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

  async function load(token = accessToken) {
    if (!token) return
    setLoading(true)
    setError('')
    try {
      const next = await listServiceSettings(token)
      setServices(next)
      const currentId = selectedId && next.some((service) => service.id === selectedId) ? selectedId : next[0]?.id ?? ''
      setSelectedId(currentId)
      const current = next.find((service) => service.id === currentId)
      setDraft(current ? cloneService(current) : null)
    } catch {
      setError('Não foi possível carregar as configurações dos serviços.')
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    if (accessToken) void load(accessToken)
  }, [accessToken])

  const selected = useMemo(() => services.find((service) => service.id === selectedId) ?? null, [services, selectedId])

  function selectService(id: string) {
    setSelectedId(id)
    const service = services.find((item) => item.id === id)
    setDraft(service ? cloneService(service) : null)
    setMessage('')
    setError('')
  }

  function patch(values: Partial<ServiceSettings>) {
    setDraft((current) => current ? { ...current, ...values } : current)
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
        booking_block_minutes: draft.duration_mode === 'BLOCKS' ? Number(draft.booking_block_minutes ?? 30) : null,
        minimum_booking_blocks: draft.duration_mode === 'BLOCKS' ? Number(draft.minimum_booking_blocks ?? 1) : null,
        maximum_booking_blocks: draft.duration_mode === 'BLOCKS' ? Number(draft.maximum_booking_blocks ?? 1) : null,
        base_price: number(draft.base_price),
        price_per_block: draft.duration_mode === 'BLOCKS' ? number(draft.price_per_block) : null,
        buffer_before_minutes: Number(draft.buffer_before_minutes),
        buffer_after_minutes: Number(draft.buffer_after_minutes),
      }, accessToken)
      setMessage('Duração, preço base e buffer salvos.')
      await load(accessToken)
    } catch {
      setError('Não foi possível salvar duração e buffer. Confira os valores.')
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
      await load(accessToken)
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
      await load(accessToken)
    } catch {
      setError('Não foi possível salvar a política. Confira multas, percentuais e janela de antecedência.')
    } finally {
      setSaving(false)
    }
  }

  function updateTier(index: number, values: Partial<DurationPricingTier>) {
    if (!draft) return
    const next = draft.pricing_tiers.map((tier, tierIndex) => tierIndex === index ? { ...tier, ...values } : tier)
    patch({ pricing_tiers: next })
  }

  function updatePreset(index: number, values: Partial<DurationPreset>) {
    if (!draft) return
    const next = draft.duration_presets.map((preset, presetIndex) => presetIndex === index ? { ...preset, ...values } : preset)
    patch({ duration_presets: next })
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
          <h1>Configurações dos serviços</h1>
          <p>Duração, buffers, preço e políticas são regras independentes de cada serviço.</p>
        </div>
        <div className="agenda-header-actions">
          <a className="secondary agenda-link-button" href="/admin/agenda">Agenda</a>
          <button className="secondary" type="button" onClick={() => supabase.auth.signOut()}>Sair</button>
        </div>
      </header>

      {error ? <div className="form-alert error" role="alert">{error}</div> : null}
      {message ? <div className="form-alert success" role="status">{message}</div> : null}

      <div className="settings-layout">
        <aside className="settings-service-list">
          <h2>Serviços</h2>
          {loading ? <p>Carregando.</p> : services.map((service) => (
            <button type="button" key={service.id} className={service.id === selectedId ? 'active' : ''} onClick={() => selectService(service.id)}>
              <strong>{service.name}</strong>
              <span>{service.category ?? 'Sem categoria'} • {service.duration_mode === 'FIXED' ? 'duração fixa' : 'por tempo'}</span>
            </button>
          ))}
        </aside>

        {draft ? (
          <div className="settings-editor">
            <section className="settings-card">
              <div className="settings-card-heading">
                <div><span className="agenda-eyebrow">{selected?.category}</span><h2>{draft.name}</h2></div>
                <span className="agenda-badge">{draft.duration_mode}</span>
              </div>

              <div className="settings-field-grid">
                <label><span>Modelo de duração</span><select value={draft.duration_mode} onChange={(event) => patch({ duration_mode: event.target.value as 'FIXED' | 'BLOCKS' })}><option value="FIXED">Duração fixa</option><option value="BLOCKS">Cliente escolhe o tempo</option></select></label>
                <label><span>Duração base (min)</span><input type="number" min="1" value={draft.base_duration_minutes} onChange={(event) => patch({ base_duration_minutes: Number(event.target.value) })} /></label>
                <label><span>Preço base (R$)</span><input type="number" min="0" step="0.01" value={number(draft.base_price)} onChange={(event) => patch({ base_price: Number(event.target.value) })} /></label>
                <label className="buffer-field"><span>Buffer após o serviço (min)</span><input type="number" min="0" step="5" value={draft.buffer_after_minutes} onChange={(event) => patch({ buffer_after_minutes: Number(event.target.value) })} /><small>Entra na ocupação da agenda depois do tempo contratado. Não é cobrado do cliente.</small></label>
                <label><span>Buffer antes (min)</span><input type="number" min="0" step="5" value={draft.buffer_before_minutes} onChange={(event) => patch({ buffer_before_minutes: Number(event.target.value) })} /></label>
              </div>

              {draft.duration_mode === 'FIXED' ? (
                <div className="settings-rule-callout"><strong>Como ficará na agenda</strong><span>{durationLabel(draft.base_duration_minutes)} para o cliente + {draft.buffer_after_minutes} min de buffer depois.</span></div>
              ) : (
                <div className="settings-field-grid settings-block-grid">
                  <label><span>Tamanho do bloco (min)</span><input type="number" min="1" value={draft.booking_block_minutes ?? 30} onChange={(event) => patch({ booking_block_minutes: Number(event.target.value) })} /></label>
                  <label><span>Mínimo de blocos</span><input type="number" min="1" value={draft.minimum_booking_blocks ?? 1} onChange={(event) => patch({ minimum_booking_blocks: Number(event.target.value) })} /></label>
                  <label><span>Máximo de blocos</span><input type="number" min="1" value={draft.maximum_booking_blocks ?? 1} onChange={(event) => patch({ maximum_booking_blocks: Number(event.target.value) })} /></label>
                  <label><span>Preço/bloco fallback (R$)</span><input type="number" min="0" step="0.01" value={number(draft.price_per_block)} onChange={(event) => patch({ price_per_block: Number(event.target.value) })} /><small>Usado apenas onde nenhuma faixa progressiva estiver configurada.</small></label>
                </div>
              )}

              <button className="primary" type="button" disabled={saving} onClick={() => void saveTiming()}>{saving ? 'Salvando…' : 'Salvar duração e buffer'}</button>
            </section>

            {draft.duration_mode === 'BLOCKS' ? (
              <>
                <section className="settings-card">
                  <div className="settings-card-heading"><div><h2>Preço progressivo</h2><p>Quanto maior a duração, menor pode ser o valor de cada bloco.</p></div><button className="secondary" type="button" onClick={() => patch({ pricing_tiers: [...draft.pricing_tiers, { min_blocks: Math.max(1, (draft.pricing_tiers.at(-1)?.max_blocks ?? 1) + 1), max_blocks: null, price_per_block: number(draft.price_per_block), is_active: true, sort_order: draft.pricing_tiers.length * 10 }] })}>+ Faixa</button></div>
                  <div className="settings-tier-list">
                    {draft.pricing_tiers.map((tier, index) => (
                      <div className="settings-tier-row" key={tier.id ?? `tier-${index}`}>
                        <label><span>De blocos</span><input type="number" min="1" value={tier.min_blocks} onChange={(event) => updateTier(index, { min_blocks: Number(event.target.value) })} /></label>
                        <label><span>Até</span><input type="number" min={tier.min_blocks} placeholder="sem limite" value={tier.max_blocks ?? ''} onChange={(event) => updateTier(index, { max_blocks: event.target.value ? Number(event.target.value) : null })} /></label>
                        <label><span>R$/bloco</span><input type="number" min="0" step="0.01" value={number(tier.price_per_block)} onChange={(event) => updateTier(index, { price_per_block: Number(event.target.value) })} /></label>
                        <button className="danger-text" type="button" onClick={() => patch({ pricing_tiers: draft.pricing_tiers.filter((_, tierIndex) => tierIndex !== index) })}>Remover</button>
                      </div>
                    ))}
                    {draft.pricing_tiers.length === 0 ? <p className="empty-state">Sem faixas: será usado o preço/bloco fallback.</p> : null}
                  </div>
                </section>

                <section className="settings-card">
                  <div className="settings-card-heading"><div><h2>Tempos recomendados</h2><p>Orientação de venda. Não cria novos serviços nem muda a curva de preço.</p></div><button className="secondary" type="button" onClick={() => patch({ duration_presets: [...draft.duration_presets, { block_count: draft.minimum_booking_blocks ?? 2, title: 'Novo tempo', description: null, badge: null, is_featured: false, is_active: true, sort_order: draft.duration_presets.length * 10 }] })}>+ Recomendação</button></div>
                  <div className="settings-preset-list">
                    {draft.duration_presets.map((preset, index) => (
                      <div className="settings-preset-row" key={preset.id ?? `preset-${index}`}>
                        <label><span>Blocos</span><input type="number" min={draft.minimum_booking_blocks ?? 1} max={draft.maximum_booking_blocks ?? undefined} value={preset.block_count} onChange={(event) => updatePreset(index, { block_count: Number(event.target.value) })} /></label>
                        <label><span>Título</span><input value={preset.title} onChange={(event) => updatePreset(index, { title: event.target.value })} /></label>
                        <label><span>Descrição</span><input value={preset.description ?? ''} onChange={(event) => updatePreset(index, { description: event.target.value || null })} /></label>
                        <label><span>Selo</span><input value={preset.badge ?? ''} placeholder="Ex.: Mais escolhido" onChange={(event) => updatePreset(index, { badge: event.target.value || null })} /></label>
                        <label className="settings-check"><input type="checkbox" checked={preset.is_featured} onChange={(event) => updatePreset(index, { is_featured: event.target.checked })} /><span>Destaque</span></label>
                        <button className="danger-text" type="button" onClick={() => patch({ duration_presets: draft.duration_presets.filter((_, presetIndex) => presetIndex !== index) })}>Remover</button>
                      </div>
                    ))}
                  </div>
                  <button className="primary" type="button" disabled={saving} onClick={() => void saveCurve()}>{saving ? 'Salvando…' : 'Salvar curva e recomendações'}</button>
                </section>
              </>
            ) : null}

            <ChangePolicyEditor
              policy={draft.change_policy ?? defaultChangePolicy}
              saving={saving}
              onChange={updatePolicy}
              onSave={() => void savePolicy()}
            />
          </div>
        ) : <section className="settings-card"><p>Selecione um serviço.</p></section>}
      </div>
    </main>
  )
}
