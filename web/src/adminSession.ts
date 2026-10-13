import type { AuthChangeEvent, Session } from '@supabase/supabase-js'
import { supabase } from './supabase'

/**
 * Fonte única da sessão administrativa por instância da aplicação.
 *
 * Os módulos da gestão continuam com o mesmo contrato (`getSession` /
 * `onAuthStateChange`), mas todos compartilham UM listener do Supabase Auth: o
 * evento `INITIAL_SESSION` entrega a sessão restaurada (sem `getSession` extra) e
 * renovação, logout e expiração chegam pelo mesmo canal.
 *
 * Isto não autoriza nada: o token só identifica a sessão; permissões são sempre
 * verificadas pelo backend. Nenhum token é copiado para outro armazenamento.
 */

type Listener = (event: AuthChangeEvent, session: Session | null) => void

let started = false
let initialized = false
let current: Session | null = null
let resolveInitial: (session: Session | null) => void = () => undefined
const initial = new Promise<Session | null>((resolve) => { resolveInitial = resolve })
const listeners = new Set<Listener>()

function ensureStarted() {
  if (started) return
  started = true
  supabase.auth.onAuthStateChange((event, session) => {
    current = session
    if (!initialized) {
      initialized = true
      resolveInitial(session)
    }
    listeners.forEach((listener) => listener(event, session))
  })
}

export function getAdminSession(): Promise<{ data: { session: Session | null } }> {
  ensureStarted()
  if (initialized) return Promise.resolve({ data: { session: current } })
  return initial.then(() => ({ data: { session: current } }))
}

export function onAdminSessionChange(listener: Listener) {
  ensureStarted()
  listeners.add(listener)
  // Igual ao supabase-js: novo inscrito recebe INITIAL_SESSION se já houver sessão resolvida.
  if (initialized) queueMicrotask(() => { if (listeners.has(listener)) listener('INITIAL_SESSION', current) })
  return { data: { subscription: { unsubscribe: () => { listeners.delete(listener) } } } }
}
