import { FormEvent, useEffect, useMemo, useState } from 'react'
import { supabase } from './supabase'

function basePath(): string {
  return import.meta.env.BASE_URL.replace(/\/+$/, '')
}

function routeUrl(path: string): string {
  return `${window.location.origin}${basePath()}${path}`
}

function hasRecoveryHint(): boolean {
  const search = new URLSearchParams(window.location.search)
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ''))
  return search.get('type') === 'recovery' || hash.get('type') === 'recovery'
}

export function PasswordRecoveryPage() {
  const [email, setEmail] = useState('')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [recoveryReady, setRecoveryReady] = useState(false)
  const [password, setPassword] = useState('')
  const [confirmPassword, setConfirmPassword] = useState('')
  const [saving, setSaving] = useState(false)
  const hinted = useMemo(hasRecoveryHint, [])

  useEffect(() => {
    let active = true

    supabase.auth.getSession().then(({ data }) => {
      if (active && hinted && data.session) setRecoveryReady(true)
    })

    const { data: listener } = supabase.auth.onAuthStateChange((event, session) => {
      if (!active) return
      if (event === 'PASSWORD_RECOVERY' || (hinted && session)) setRecoveryReady(true)
    })

    return () => {
      active = false
      listener.subscription.unsubscribe()
    }
  }, [hinted])

  async function requestRecovery(event: FormEvent) {
    event.preventDefault()
    setError('')
    setMessage('')
    const cleanEmail = email.trim().toLowerCase()
    if (!cleanEmail) {
      setError('Informe o e-mail do seu acesso administrativo.')
      return
    }

    const { error: requestError } = await supabase.auth.resetPasswordForEmail(cleanEmail, {
      redirectTo: routeUrl('/gestao/recuperar-senha'),
    })

    if (requestError) {
      setError('Não foi possível solicitar a recuperação agora. Tente novamente em alguns minutos.')
      return
    }

    setMessage('Se o e-mail estiver cadastrado, você receberá um link seguro para definir uma nova senha.')
  }

  async function savePassword(event: FormEvent) {
    event.preventDefault()
    setError('')
    setMessage('')

    if (password.length < 10) {
      setError('Use uma senha com pelo menos 10 caracteres.')
      return
    }
    if (password !== confirmPassword) {
      setError('As senhas não coincidem.')
      return
    }

    setSaving(true)
    const { error: updateError } = await supabase.auth.updateUser({ password })
    setSaving(false)

    if (updateError) {
      setError('Não foi possível atualizar a senha. Solicite um novo link de recuperação.')
      return
    }

    await supabase.auth.signOut()
    window.location.assign(routeUrl('/gestao'))
  }

  return (
    <main className="admin-shell login-shell">
      <section className="login-card" aria-labelledby="recovery-title">
        <h1 id="recovery-title">Recuperar acesso</h1>
        <p>BlackSheep Agenda</p>

        {recoveryReady ? (
          <form onSubmit={savePassword}>
            <label>
              <span>Nova senha</span>
              <input type="password" autoComplete="new-password" value={password} onChange={(event) => setPassword(event.target.value)} />
            </label>
            <label>
              <span>Confirmar nova senha</span>
              <input type="password" autoComplete="new-password" value={confirmPassword} onChange={(event) => setConfirmPassword(event.target.value)} />
            </label>
            {error && <div className="form-alert error" role="alert">{error}</div>}
            {message && <div className="form-alert" role="status">{message}</div>}
            <button className="primary" type="submit" disabled={saving}>{saving ? 'Salvando…' : 'Definir nova senha'}</button>
          </form>
        ) : (
          <form onSubmit={requestRecovery}>
            <label>
              <span>E-mail</span>
              <input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} />
            </label>
            {error && <div className="form-alert error" role="alert">{error}</div>}
            {message && <div className="form-alert" role="status">{message}</div>}
            <button className="primary" type="submit">Enviar link de recuperação</button>
          </form>
        )}

        <p><a href={`${basePath()}/gestao`}>Voltar ao login</a></p>
      </section>
    </main>
  )
}
