import { assertEquals } from 'jsr:@std/assert@1'
import { approvedByMeta, currentSubmission } from './approval.ts'

const pending = { status: 'PENDING_REVIEW', provider_template_name: 'agenda_reminder_v2', submitted_at: '2026-10-22T13:34:19Z' }

Deno.test('Meta approval is read for the submitted name only', () => {
  assertEquals(approvedByMeta({ templates: [{ name: 'agenda_reminder_v2', status: 'APPROVED' }] }, 'agenda_reminder_v2'), true)
  assertEquals(approvedByMeta({ templates: [{ name: 'agenda_reminder_v1', status: 'APPROVED' }] }, 'agenda_reminder_v2'), false)
  assertEquals(approvedByMeta({ templates: [{ name: 'agenda_reminder_v2', status: 'PENDING' }] }, 'agenda_reminder_v2'), false)
})

Deno.test('a message under review goes once Meta approves it', async () => {
  let saved = ''
  const result = await currentSubmission(pending, () => Promise.resolve({ templates: [{ name: 'agenda_reminder_v2', status: 'APPROVED' }] }), (at) => { saved = at; return Promise.resolve() })
  assertEquals(result?.status, 'APPROVED')
  assertEquals(saved !== '', true)
})

Deno.test('still under review: nothing is saved and the message waits', async () => {
  let calls = 0
  const result = await currentSubmission(pending, () => Promise.resolve({ templates: [{ name: 'agenda_reminder_v2', status: 'PENDING' }] }), () => { calls += 1; return Promise.resolve() })
  assertEquals(result?.status, 'PENDING_REVIEW')
  assertEquals(calls, 0)
})

Deno.test('an approved or rejected message does not ask Meta', async () => {
  let asked = false
  const gateway = () => { asked = true; return Promise.resolve({}) }
  await currentSubmission({ ...pending, status: 'APPROVED' }, gateway, () => Promise.resolve())
  await currentSubmission({ ...pending, status: 'REJECTED' }, gateway, () => Promise.resolve())
  assertEquals(asked, false)
})
