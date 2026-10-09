import { adminClient, requireAdmin } from '../_shared/supabase.ts'
import {
  parseWorkforceCommand,
  workforceCorsHeaders,
  workforceErrorResponse,
  workforceJson,
} from '../_shared/workforce-http.ts'

// Owner surface of the Jornada por Exceção (ADR-017). requireAdmin only proves
// an authenticated Gestão login; owner authorization (role OWNER + ACTIVE OWNER
// membership) is enforced again inside every service_workforce_owner_* RPC.
const OWNER_COMMANDS = {
  SAVE_EMPLOYER: 'service_workforce_owner_save_employer',
  SAVE_PAYROLL_SETTINGS: 'service_workforce_owner_save_payroll_settings',
  SAVE_EMPLOYEE: 'service_workforce_owner_save_employee',
  CREATE_SCHEDULE_VERSION: 'service_workforce_owner_create_schedule_version',
  MANAGE_HOLIDAY: 'service_workforce_owner_manage_holiday',
} as const

type OwnerCommand = keyof typeof OWNER_COMMANDS

const OWNER_VIEWS = {
  setup: 'service_workforce_owner_get_setup',
} as const

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: workforceCorsHeaders })
  if (!['GET', 'POST'].includes(req.method)) return workforceJson({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      const view = new URL(req.url).searchParams.get('view') ?? 'setup'
      if (!Object.hasOwn(OWNER_VIEWS, view)) throw new Error('WORKFORCE_VIEW_UNKNOWN')
      const { data, error } = await client.rpc(OWNER_VIEWS[view as keyof typeof OWNER_VIEWS], {
        p_actor_admin_id: admin.adminId,
      })
      if (error) throw new Error(error.message)
      return workforceJson(data)
    }

    const envelope = parseWorkforceCommand(
      await req.json().catch(() => null),
      Object.keys(OWNER_COMMANDS) as OwnerCommand[],
    )
    const { data, error } = await client.rpc(OWNER_COMMANDS[envelope.command], {
      p_actor_admin_id: admin.adminId,
      p_idempotency_key: envelope.idempotencyKey,
      p_payload: envelope.payload,
    })
    if (error) throw new Error(error.message)
    return workforceJson(data)
  } catch (error) {
    return workforceErrorResponse(error)
  }
})
