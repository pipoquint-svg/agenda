// Constant-time comparison for secrets/tokens read off the request (internal
// worker secrets, webhook channel-token hashes, machine-to-machine headers).
// A plain `===`/`!==` on these short-circuits at the first differing byte, which
// leaks a timing signal an attacker can use to guess the secret byte-by-byte.
// This always walks the full length of the longer input regardless of where a
// mismatch occurs, so the comparison time does not depend on how much of the
// value the caller got right.
export function timingSafeEqual(a: string | null | undefined, b: string | null | undefined): boolean {
  const encoder = new TextEncoder()
  const bytesA = encoder.encode(a ?? '')
  const bytesB = encoder.encode(b ?? '')
  const length = Math.max(bytesA.length, bytesB.length)

  let diff = bytesA.length ^ bytesB.length
  for (let i = 0; i < length; i++) {
    diff |= (bytesA[i] ?? 0) ^ (bytesB[i] ?? 0)
  }
  return diff === 0
}
