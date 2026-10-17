import { financeServerDate, manualReceiptPaidAt } from './manual_receipt_date.ts'

function assertEquals(actual: unknown, expected: unknown) {
  if (actual !== expected) throw new Error(`Expected ${expected}, got ${actual}`)
}

Deno.test('server date follows midnight in Sao Paulo', () => {
  assertEquals(financeServerDate(new Date('2026-10-18T02:59:59Z')), '2026-10-17')
  assertEquals(financeServerDate(new Date('2026-10-18T03:00:00Z')), '2026-10-18')
})

Deno.test('uses server time for the selected server-local date', () => {
  assertEquals(manualReceiptPaidAt('2026-10-17', '2026-10-17T12:00:00-03:00', new Date('2026-10-17T09:30:00Z')), '2026-10-17T09:30:00.000Z')
})

Deno.test('preserves selected date across midnight in Sao Paulo', () => {
  assertEquals(manualReceiptPaidAt('2026-10-17', '2026-10-17T12:00:00-03:00', new Date('2026-10-18T03:00:01Z')), '2026-10-17T15:00:00.000Z')
})

Deno.test('rejects confirmation if the server date changed before recording', () => {
  let error = ''
  try {
    manualReceiptPaidAt('2026-10-17', null, new Date('2026-10-18T03:00:01Z'), '2026-10-17')
  } catch (caught) { error = (caught as Error).message }
  assertEquals(error, 'MANUAL_RECEIPT_SERVER_DATE_CHANGED')
})

Deno.test('rejects future dates and invalid calendar dates', () => {
  for (const selected of ['2026-10-18', '2026-02-30', 'not-a-date']) {
    let rejected = false
    try { manualReceiptPaidAt(selected, `${selected}T12:00:00-03:00`, new Date('2026-10-17T09:30:00Z')) } catch { rejected = true }
    assertEquals(rejected, true)
  }
})

Deno.test('preserves legacy requests without a selected date', () => {
  assertEquals(manualReceiptPaidAt(undefined, '2026-10-16T12:00:00-03:00', new Date('2026-10-17T09:30:00Z')), '2026-10-16T15:00:00.000Z')
  assertEquals(manualReceiptPaidAt(undefined, null, new Date('2026-10-17T09:30:00Z')), null)
})
