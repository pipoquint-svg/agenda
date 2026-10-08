import { adminClient, requireAdmin } from '../_shared/supabase.ts'
import {
  workforceCorsHeaders,
  workforceErrorResponse,
  workforceJson,
} from '../_shared/workforce-http.ts'

// Employee surface ("Minha Jornada", ADR-017). The employee is never chosen by
// the browser: every RPC resolves it from the authenticated login binding.
const EMPLOYEE_VIEWS = {
  profile: 'service_workforce_employee_get_profile',
} as const

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: workforceCorsHeaders })
  if (req.method !== 'GET') return workforceJson({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const view = new URL(req.url).searchParams.get('view') ?? 'profile'
    if (!Object.hasOwn(EMPLOYEE_VIEWS, view)) throw new Error('WORKFORCE_VIEW_UNKNOWN')
    const { data, error } = await adminClient().rpc(EMPLOYEE_VIEWS[view as keyof typeof EMPLOYEE_VIEWS], {
      p_actor_admin_id: admin.adminId,
    })
    if (error) throw new Error(error.message)
    return workforceJson(data)
  } catch (error) {
    return workforceErrorResponse(error)
  }
})
