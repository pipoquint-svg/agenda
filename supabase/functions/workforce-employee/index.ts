import { adminClient, requireAdmin } from '../_shared/supabase.ts'
import {
  parseWorkforceCommand,
  type WorkforceView,
  workforceCorsHeaders,
  workforceErrorResponse,
  workforceJson,
  workforceMonthParam,
  workforceViewArgs,
  workforcePdfResponse,
} from '../_shared/workforce-http.ts'
import { buildWorkforceReportPdf, type WorkforceReportPayload } from '../_shared/workforce-pdf.ts'

// Employee surface ("Minha Jornada", ADR-017). The employee is never chosen by
// the browser: every RPC resolves it from the authenticated login binding, and
// live start/finish use the database clock.
const EMPLOYEE_COMMANDS = {
  START_EXTRA: 'service_workforce_employee_start_extra',
  FINISH_EXTRA: 'service_workforce_employee_finish_extra',
  RECORD_EXCEPTION: 'service_workforce_employee_record_exception',
  REVIEW_EXCEPTION: 'service_workforce_employee_review_exception',
  ACKNOWLEDGE_MIRROR: 'service_workforce_employee_acknowledge_mirror',
} as const

type EmployeeCommand = keyof typeof EMPLOYEE_COMMANDS

const month = (url: URL) => ({ p_month: workforceMonthParam(url) })

const EMPLOYEE_VIEWS: Record<string, WorkforceView> = {
  profile: { rpc: 'service_workforce_employee_get_profile', args: () => ({}) },
  exceptions: { rpc: 'service_workforce_employee_list_exceptions', args: month },
  summary: { rpc: 'service_workforce_employee_get_month_summary', args: month },
  mirror: { rpc: 'service_workforce_employee_get_mirror', args: month },
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: workforceCorsHeaders })
  if (!['GET', 'POST'].includes(req.method)) return workforceJson({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      const url = new URL(req.url)
      if (url.searchParams.get('view') === 'mirror_pdf') {
        // Only her own closed mirror, resolved from the login binding.
        const args = month(url)
        const { data, error } = await client.rpc('service_workforce_employee_get_mirror', { p_actor_admin_id: admin.adminId, ...args })
        if (error) throw new Error(error.message)
        const mirror = (data as { mirror?: WorkforceReportPayload | null } | null)?.mirror
        if (!mirror) throw new Error('WORKFORCE_REPORT_NOT_FOUND')
        return workforcePdfResponse(buildWorkforceReportPdf(mirror), `minha-jornada-${args.p_month}.pdf`)
      }
      const { rpc, args } = workforceViewArgs(url, EMPLOYEE_VIEWS, 'profile')
      const { data, error } = await client.rpc(rpc, { p_actor_admin_id: admin.adminId, ...args })
      if (error) throw new Error(error.message)
      return workforceJson(data)
    }

    const envelope = parseWorkforceCommand(
      await req.json().catch(() => null),
      Object.keys(EMPLOYEE_COMMANDS) as EmployeeCommand[],
    )
    const { data, error } = await client.rpc(EMPLOYEE_COMMANDS[envelope.command], {
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
