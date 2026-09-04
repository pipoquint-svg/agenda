import { assertGitHubBirthdayClaims, assertGitHubOpsAlertClaims, assertGitHubWorkerClaims } from './github-oidc.ts'

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message)
}

function validWorkerPayload(): Record<string, unknown> {
  return {
    repository: 'pipoquint-svg/agenda',
    repository_id: '1341970175',
    repository_owner_id: '318444162',
    ref: 'refs/heads/main',
    workflow_ref: 'pipoquint-svg/agenda/.github/workflows/integration-worker-schedule.yml@refs/heads/main',
    event_name: 'schedule',
  }
}

function validBirthdayPayload(): Record<string, unknown> {
  return {
    ...validWorkerPayload(),
    workflow_ref: 'pipoquint-svg/agenda/.github/workflows/birthday-automation-schedule.yml@refs/heads/main',
  }
}

function validOpsAlertPayload(): Record<string, unknown> {
  return {
    ...validWorkerPayload(),
    workflow_ref: 'pipoquint-svg/agenda/.github/workflows/ops-alert-schedule.yml@refs/heads/main',
  }
}

Deno.test('GitHub OIDC worker claims accept only the pinned scheduled workflow', () => {
  assertGitHubWorkerClaims(validWorkerPayload())
  assertGitHubWorkerClaims({ ...validWorkerPayload(), event_name: 'workflow_dispatch' })
})

Deno.test('GitHub OIDC birthday claims accept only the pinned birthday workflow', () => {
  assertGitHubBirthdayClaims(validBirthdayPayload())
  assertGitHubBirthdayClaims({ ...validBirthdayPayload(), event_name: 'workflow_dispatch' })
})

Deno.test('GitHub OIDC ops alert claims accept only the pinned ops workflow', () => {
  assertGitHubOpsAlertClaims(validOpsAlertPayload())
  assertGitHubOpsAlertClaims({ ...validOpsAlertPayload(), event_name: 'workflow_dispatch' })
})

Deno.test('GitHub OIDC worker claims reject another repository id', () => {
  let error = ''
  try {
    assertGitHubWorkerClaims({ ...validWorkerPayload(), repository_id: '1' })
  } catch (cause) {
    error = cause instanceof Error ? cause.message : String(cause)
  }
  assert(error === 'GITHUB_OIDC_REPOSITORY_ID_DENIED', 'repository id must fail closed')
})

Deno.test('GitHub OIDC claims reject another workflow, ref, or event', () => {
  for (const [assertClaims, payload] of [
    [assertGitHubWorkerClaims, { ...validWorkerPayload(), workflow_ref: 'pipoquint-svg/agenda/.github/workflows/other.yml@refs/heads/main' }],
    [assertGitHubWorkerClaims, { ...validWorkerPayload(), ref: 'refs/heads/feature/test' }],
    [assertGitHubWorkerClaims, { ...validWorkerPayload(), event_name: 'pull_request' }],
    [assertGitHubBirthdayClaims, validWorkerPayload()],
    [assertGitHubWorkerClaims, validBirthdayPayload()],
    [assertGitHubOpsAlertClaims, validWorkerPayload()],
    [assertGitHubWorkerClaims, validOpsAlertPayload()],
  ] as const) {
    let rejected = false
    try {
      assertClaims(payload)
    } catch {
      rejected = true
    }
    assert(rejected, 'unexpected OIDC claim combination must be rejected')
  }
})
