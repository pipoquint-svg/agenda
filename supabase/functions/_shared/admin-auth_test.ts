import { assertEquals, assertRejects } from 'jsr:@std/assert@1'
import {
  authorizeAdmin,
  forgetRememberedPermissions,
  rememberedPermission,
  rememberedProfile,
  rememberProfile,
  unverifiedJwtSubject,
  type AdminAuthDeps,
} from './admin-auth.ts'

const USER = '11111111-1111-4111-8111-111111111111'
const OTHER = '22222222-2222-4222-8222-222222222222'
const b64 = (value: unknown) => btoa(JSON.stringify(value)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
const token = (sub: string) => `${b64({ alg: 'HS256' })}.${b64({ sub, role: 'authenticated' })}.signature`
const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

function deps(overrides: Partial<AdminAuthDeps> = {}, log: string[] = []): AdminAuthDeps {
  return {
    getUser: async () => { log.push('auth'); await sleep(30); return { id: USER } },
    resolveProfile: async (id) => {
      log.push(`resolve:${id}`)
      await sleep(10)
      return id === USER ? { admin_user_id: 'admin-1', display_name: 'Perf', permissions: { AGENDA_VIEW: true, FINANCE_VIEW: false } } : null
    },
    ...overrides,
  }
}

Deno.test('lê o sub sem confiar nele e rejeita formatos inválidos', () => {
  assertEquals(unverifiedJwtSubject(token(USER)), USER)
  assertEquals(unverifiedJwtSubject('not-a-jwt'), null)
  assertEquals(unverifiedJwtSubject(`${b64({})}.${b64({ sub: 'x' })}.s`), null)
})

Deno.test('Auth e banco correm em paralelo e o resultado traz o perfil', async () => {
  const log: string[] = []
  const result = await authorizeAdmin(token(USER), deps({
    getUser: async () => { log.push('auth-start'); await sleep(30); log.push('auth-end'); return { id: USER } },
    resolveProfile: async (id) => {
      log.push('profile-start')
      await sleep(5)
      return id === USER ? { admin_user_id: 'admin-1', display_name: 'Perf', permissions: { AGENDA_VIEW: true, FINANCE_VIEW: false } } : null
    },
  }, log))
  assertEquals(result, {
    adminId: 'admin-1',
    authUserId: USER,
    profile: { admin_user_id: 'admin-1', display_name: 'Perf', permissions: { AGENDA_VIEW: true, FINANCE_VIEW: false } },
  })
  // Determinístico: a leitura do perfil começa antes de o Auth terminar (paralelo) e acontece uma vez só.
  assertEquals(log.indexOf('profile-start') < log.indexOf('auth-end'), true)
  assertEquals(log.filter((entry) => entry === 'profile-start').length, 1)
})

Deno.test('token rejeitado pelo Auth nunca autoriza, mesmo com admin resolvido', async () => {
  await assertRejects(() => authorizeAdmin(token(USER), deps({ getUser: async () => null })), Error, 'ADMIN_AUTH_INVALID')
  await assertRejects(
    () => authorizeAdmin(token(USER), deps({ getUser: async () => { throw new Error('network') } })),
    Error,
    'ADMIN_AUTH_INVALID',
  )
})

Deno.test('sub adulterado no token é ignorado: vale o usuário confirmado pelo Auth', async () => {
  const log: string[] = []
  // O token diz OTHER (que seria admin), mas o Auth confirma USER, que não é admin.
  const forged = deps({
    getUser: async () => ({ id: USER }),
    resolveProfile: async (id) => { log.push(`resolve:${id}`); return id === OTHER ? { admin_user_id: 'admin-other', permissions: {} } : null },
  }, log)
  await assertRejects(() => authorizeAdmin(token(OTHER), forged), Error, 'ADMIN_ACCESS_DENIED')
  // A leitura especulativa do sub alegado é descartada; a decisão usa o usuário do Auth.
  assertEquals(log.includes(`resolve:${OTHER}`) && log.includes(`resolve:${USER}`), true)
})

Deno.test('usuário sem admin ativo é negado; falha de leitura nega (nunca concede)', async () => {
  await assertRejects(() => authorizeAdmin(token(USER), deps({ resolveProfile: async () => null })), Error, 'ADMIN_ACCESS_DENIED')
  await assertRejects(
    () => authorizeAdmin(token(USER), deps({ resolveProfile: async () => { throw new Error('db') } })),
    Error,
    'ADMIN_ACCESS_DENIED',
  )
  await assertRejects(
    () => authorizeAdmin(token(USER), deps({ resolveProfile: async () => ({ permissions: { AGENDA_VIEW: true } }) })),
    Error,
    'ADMIN_ACCESS_DENIED',
  )
})

Deno.test('perfil lembrado vale 1 s e só para permissões conhecidas', () => {
  forgetRememberedPermissions()
  rememberProfile('admin-1', { role: 'OWNER', permissions: { AGENDA_VIEW: true, FINANCE_VIEW: false } }, 1_000)
  assertEquals(rememberedProfile('admin-1', 1_500)?.role, 'OWNER')
  assertEquals(rememberedPermission('admin-1', 'AGENDA_VIEW', 1_500), true)
  assertEquals(rememberedPermission('admin-1', 'FINANCE_VIEW', 1_500), false)
  assertEquals(rememberedPermission('admin-1', 'TEAM_MANAGE', 1_500), null)
  assertEquals(rememberedPermission('admin-1', 'AGENDA_VIEW', 2_000), null)
  assertEquals(rememberedPermission('admin-2', 'AGENDA_VIEW', 1_500), null)
  rememberProfile('admin-3', null, 1_000)
  rememberProfile('admin-4', { permissions: [] }, 1_000)
  assertEquals(rememberedProfile('admin-4', 1_100), null)
  assertEquals(rememberedPermission('admin-3', 'AGENDA_VIEW', 1_100), null)
})
