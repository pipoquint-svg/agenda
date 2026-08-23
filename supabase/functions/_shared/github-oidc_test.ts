import { assertGitHubWorkerClaims } from './github-oidc.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function validPayload(): Record<string, unknown> {
  return {
    repository: 'pipoquint-svg/agenda',
    repository_id: '1341970175',
    repository_owner_id: '318444162',
    ref: 'refs/heads/main',
    workflow_ref: 'pipoquint-svg/agenda/.github/workflows/integration-worker-schedule.yml@refs/heads/main',
    event_name: 'schedule',
  }
}

Deno.test('GitHub OIDC worker claims accept only the pinned scheduled workflow', () => {
  assertGitHubWorkerClaims(validPayload())
  assertGitHubWorkerClaims({ ...validPayload(), event_name: 'workflow_dispatch' })
})

Deno.test('GitHub OIDC worker claims reject another repository id', () => {
  let error = ''
  try {
    assertGitHubWorkerClaims({ ...validPayload(), repository_id: '1' })
  } catch (cause) {
    error = cause instanceof Error ? cause.message : String(cause)
  }
  assert(error === 'GITHUB_OIDC_REPOSITORY_ID_DENIED', 'repository id must fail closed')
})

Deno.test('GitHub OIDC worker claims reject another workflow, ref, or event', () => {
  for (const payload of [
    { ...validPayload(), workflow_ref: 'pipoquint-svg/agenda/.github/workflows/other.yml@refs/heads/main' },
    { ...validPayload(), ref: 'refs/heads/feature/test' },
    { ...validPayload(), event_name: 'pull_request' },
  ]) {
    let rejected = false
    try {
      assertGitHubWorkerClaims(payload)
    } catch {
      rejected = true
    }
    assert(rejected, 'unexpected OIDC claim combination must be rejected')
  }
})
