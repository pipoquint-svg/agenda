import { adminClient, requireAdmin } from '../_shared/supabase.ts'
import {
  parseWorkforceCommand,
  type WorkforceView,
  workforceCorsHeaders,
  workforceErrorResponse,
  workforceJson,
  workforceMonthParam,
  workforceUuidParam,
  workforceViewArgs,
  workforcePdfResponse,
} from '../_shared/workforce-http.ts'
import { buildWorkforceReportPdf, type WorkforceReportPayload } from '../_shared/workforce-pdf.ts'

// Owner surface of the Jornada por Exceção (ADR-017). requireAdmin only proves
// an authenticated Gestão login; owner authorization (role OWNER + ACTIVE OWNER
// membership) is enforced again inside every service_workforce_owner_* RPC.
const OWNER_COMMANDS = {
  SAVE_EMPLOYER: 'service_workforce_owner_save_employer',
  SAVE_PAYROLL_SETTINGS: 'service_workforce_owner_save_payroll_settings',
  SAVE_EMPLOYEE: 'service_workforce_owner_save_employee',
  CREATE_SCHEDULE_VERSION: 'service_workforce_owner_create_schedule_version',
  MANAGE_HOLIDAY: 'service_workforce_owner_manage_holiday',
  RECORD_EXCEPTION: 'service_workforce_owner_record_exception',
  RECALCULATE_MONTH: 'service_workforce_owner_recalculate_month',
  REVIEW_EXCEPTION: 'service_workforce_owner_review_exception',
  MANAGE_COMPLIANCE: 'service_workforce_owner_manage_compliance',
  MANAGE_PERIOD: 'service_workforce_owner_manage_period',
  MANAGE_DELIVERY: 'service_workforce_owner_manage_delivery',
} as const

type OwnerCommand = keyof typeof OWNER_COMMANDS

const employeeMonth = (url: URL) => ({
  p_employee_id: workforceUuidParam(url, 'employee_id'),
  p_month: workforceMonthParam(url),
})

const OWNER_VIEWS: Record<string, WorkforceView> = {
  setup: { rpc: 'service_workforce_owner_get_setup', args: () => ({}) },
  exceptions: { rpc: 'service_workforce_owner_list_exceptions', args: employeeMonth },
  summary: { rpc: 'service_workforce_owner_get_month_summary', args: employeeMonth },
  review_queue: { rpc: 'service_workforce_owner_list_review_queue', args: employeeMonth },
  alerts: { rpc: 'service_workforce_owner_list_compliance_alerts', args: employeeMonth },
  period: { rpc: 'service_workforce_owner_get_period', args: employeeMonth },
  deliveries: { rpc: 'service_workforce_owner_list_deliveries', args: employeeMonth },
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: workforceCorsHeaders })
  if (!['GET', 'POST'].includes(req.method)) return workforceJson({ error: { code: 'METHOD_NOT_ALLOWED' } }, 405)

  try {
    const admin = await requireAdmin(req)
    const client = adminClient()

    if (req.method === 'GET') {
      const url = new URL(req.url)
      if (url.searchParams.get('view') === 'report_pdf') {
        // Built only from the latest closed snapshot's accountant report.
        const args = employeeMonth(url)
        const { data, error } = await client.rpc('service_workforce_owner_get_period', { p_actor_admin_id: admin.adminId, ...args })
        if (error) throw new Error(error.message)
        const report = (data as { latest_report?: WorkforceReportPayload | null } | null)?.latest_report
        if (!report) throw new Error('WORKFORCE_REPORT_NOT_FOUND')
        return workforcePdfResponse(buildWorkforceReportPdf(report), `jornada-${args.p_month}-v${report.version ?? 1}.pdf`)
      }
      const { rpc, args } = workforceViewArgs(url, OWNER_VIEWS, 'setup')
      const { data, error } = await client.rpc(rpc, { p_actor_admin_id: admin.adminId, ...args })
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
