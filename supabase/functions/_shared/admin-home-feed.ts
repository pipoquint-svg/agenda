// Read model enxuto da página inicial da Gestão (`admin-dashboard?view=home`).
//
// A página inicial só exibe as últimas reservas confirmadas e as últimas
// movimentações. Este modo evita o RPC de indicadores e a leitura de saldos em
// aberto (que a página descarta) e traz cliente e serviço embutidos na mesma
// consulta (FKs appointments → customers/services), reduzindo idas ao banco.
// Autorização continua a do endpoint: DASHBOARD_VIEW verificado no servidor.

export const HOME_MOVEMENT_ACTIONS = [
  'PAYMENT_HOLD_EXPIRED',
  'APPOINTMENT_CANCELLED',
  'APPOINTMENT_RESCHEDULED',
]

export const HOME_APPOINTMENT_SELECT =
  'id,public_code,status,start_at,end_at,created_at,origin,service_name_snapshot,customer:customers(name),service:services(name,operation_scope)'

type Embedded<T> = T | T[] | null | undefined

export type HomeAppointmentRow = {
  id: string
  public_code: string | null
  status: string
  start_at: string
  end_at: string
  created_at?: string | null
  origin?: string | null
  service_name_snapshot: string | null
  customer?: Embedded<{ name: string | null }>
  service?: Embedded<{ name: string | null; operation_scope: string | null }>
}

export type HomeAuditRow = {
  id: string
  entity_id: string | null
  action: string
  before_json: unknown
  after_json: unknown
  created_at: string
}

function one<T>(value: Embedded<T>): T | null {
  if (Array.isArray(value)) return value[0] ?? null
  return value ?? null
}

function objectValue(value: unknown, key: string): unknown {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null
  return (value as Record<string, unknown>)[key] ?? null
}

export function buildHomeFeed(
  recentRows: HomeAppointmentRow[],
  movementRows: HomeAuditRow[],
  movementAppointments: HomeAppointmentRow[],
  operationScope: string | null,
) {
  const byId = new Map(movementAppointments.map((row) => [row.id, row]))

  const recent_appointments = recentRows
    .map((row) => {
      const service = one(row.service)
      return {
        id: row.id,
        public_code: row.public_code,
        status: row.status,
        start_at: row.start_at,
        end_at: row.end_at,
        created_at: row.created_at ?? null,
        origin: row.origin ?? null,
        customer_name: one(row.customer)?.name ?? null,
        service_name: row.service_name_snapshot || service?.name || null,
        operation_scope: service?.operation_scope ?? null,
      }
    })
    .filter((row) => !operationScope || row.operation_scope === operationScope)
    .slice(0, 5)

  const recent_movements = movementRows
    .map((row) => {
      const appointment = byId.get(String(row.entity_id))
      if (!appointment) return null
      const service = one(appointment.service)
      return {
        id: row.id,
        appointment_id: appointment.id,
        public_code: appointment.public_code,
        action: row.action,
        occurred_at: row.created_at,
        customer_name: one(appointment.customer)?.name ?? null,
        service_name: appointment.service_name_snapshot || service?.name || null,
        operation_scope: service?.operation_scope ?? null,
        old_start_at: row.action === 'APPOINTMENT_RESCHEDULED' ? objectValue(row.before_json, 'start_at') : null,
        new_start_at: row.action === 'APPOINTMENT_RESCHEDULED' ? objectValue(row.after_json, 'start_at') : null,
        current_start_at: appointment.start_at,
        current_end_at: appointment.end_at,
      }
    })
    .filter((row): row is NonNullable<typeof row> => row !== null)
    .filter((row) => !operationScope || row.operation_scope === operationScope)
    .slice(0, 5)

  return { pending_items: [] as unknown[], recent_appointments, recent_movements }
}
