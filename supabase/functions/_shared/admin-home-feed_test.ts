import { assertEquals } from 'jsr:@std/assert@1'
import { buildHomeFeed, type HomeAppointmentRow, type HomeAuditRow } from './admin-home-feed.ts'

const appt = (id: string, scope: string, extra: Partial<HomeAppointmentRow> = {}): HomeAppointmentRow => ({
  id,
  public_code: `C-${id}`,
  status: 'CONFIRMED',
  start_at: '2026-10-20T12:00:00Z',
  end_at: '2026-10-20T14:00:00Z',
  created_at: '2026-10-13T10:00:00Z',
  origin: 'PUBLIC',
  service_name_snapshot: null,
  customer: { name: `Cliente ${id}` },
  service: { name: `Serviço ${scope}`, operation_scope: scope },
  ...extra,
})

Deno.test('home feed keeps the dashboard contract with embedded customer and service', () => {
  const recent = [appt('a', 'BLACKSHEEP', { service_name_snapshot: 'Locação 4h' }), appt('b', 'SABRINA', { customer: [{ name: 'Array' }] })]
  const audits: HomeAuditRow[] = [
    { id: 'l1', entity_id: 'b', action: 'APPOINTMENT_RESCHEDULED', before_json: { start_at: 'old' }, after_json: { start_at: 'new' }, created_at: '2026-10-13T11:00:00Z' },
    { id: 'l2', entity_id: 'missing', action: 'APPOINTMENT_CANCELLED', before_json: null, after_json: null, created_at: '2026-10-13T11:05:00Z' },
  ]
  const feed = buildHomeFeed(recent, audits, [recent[1]], null)
  assertEquals(feed.pending_items, [])
  assertEquals(feed.recent_appointments.map((r) => [r.id, r.customer_name, r.service_name, r.operation_scope]), [
    ['a', 'Cliente a', 'Locação 4h', 'BLACKSHEEP'],
    ['b', 'Array', 'Serviço SABRINA', 'SABRINA'],
  ])
  assertEquals(feed.recent_movements.length, 1)
  assertEquals(feed.recent_movements[0].old_start_at, 'old')
  assertEquals(feed.recent_movements[0].new_start_at, 'new')
  assertEquals(feed.recent_movements[0].appointment_id, 'b')
})

Deno.test('home feed honors operation scope and limits', () => {
  const recent = Array.from({ length: 8 }, (_, index) => appt(`x${index}`, index % 2 ? 'SABRINA' : 'BLACKSHEEP'))
  const feed = buildHomeFeed(recent, [], [], 'BLACKSHEEP')
  assertEquals(feed.recent_appointments.length, 4)
  assertEquals(feed.recent_appointments.every((r) => r.operation_scope === 'BLACKSHEEP'), true)
  assertEquals(buildHomeFeed(recent, [], [], null).recent_appointments.length, 5)
})
