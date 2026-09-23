import { timingSafeEqual } from './timing-safe-equal.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

Deno.test('timingSafeEqual matches identical strings', () => {
  assert(timingSafeEqual('same-secret', 'same-secret'), 'identical strings must match')
  assert(timingSafeEqual('', ''), 'two empty strings must match')
})

Deno.test('timingSafeEqual rejects differing strings', () => {
  assert(!timingSafeEqual('same-secret', 'same-secreT'), 'trailing case difference must not match')
  assert(!timingSafeEqual('short', 'much-longer-value'), 'different lengths must not match')
  assert(!timingSafeEqual('abc', 'abd'), 'single differing byte must not match')
})

Deno.test('timingSafeEqual treats missing values as non-matching unless both absent', () => {
  assert(!timingSafeEqual(null, 'expected'), 'null supplied value must not match a real secret')
  assert(!timingSafeEqual(undefined, 'expected'), 'undefined supplied value must not match a real secret')
  assert(!timingSafeEqual('expected', null), 'null expected value must not match a real supplied value')
  assert(timingSafeEqual(null, undefined), 'both absent is treated as equal empty strings')
})
