export const GITHUB_OIDC_ISSUER = 'https://token.actions.githubusercontent.com'
export const GITHUB_WORKER_AUDIENCE = 'blacksheep-agenda-integration-worker'
export const GITHUB_BIRTHDAY_AUDIENCE = 'blacksheep-agenda-birthday-scheduler'
export const GITHUB_OPS_ALERT_AUDIENCE = 'blacksheep-agenda-ops-alert-monitor'

const EXPECTED_REPOSITORY = 'pipoquint-svg/agenda'
const EXPECTED_REPOSITORY_ID = '1341970175'
const EXPECTED_OWNER_ID = '318444162'
const EXPECTED_REF = 'refs/heads/main'
const EXPECTED_WORKER_WORKFLOW_REF =
  'pipoquint-svg/agenda/.github/workflows/integration-worker-schedule.yml@refs/heads/main'
const EXPECTED_BIRTHDAY_WORKFLOW_REF =
  'pipoquint-svg/agenda/.github/workflows/birthday-automation-schedule.yml@refs/heads/main'
const EXPECTED_OPS_ALERT_WORKFLOW_REF =
  'pipoquint-svg/agenda/.github/workflows/ops-alert-schedule.yml@refs/heads/main'
const ALLOWED_EVENTS = new Set(['schedule', 'workflow_dispatch'])

function claim(payload: Record<string, unknown>, name: string): string {
  const value = payload[name]
  return typeof value === 'string' ? value : value == null ? '' : String(value)
}

function assertBaseClaims(payload: Record<string, unknown>): void {
  if (claim(payload, 'repository') !== EXPECTED_REPOSITORY) {
    throw new Error('GITHUB_OIDC_REPOSITORY_DENIED')
  }
  if (claim(payload, 'repository_id') !== EXPECTED_REPOSITORY_ID) {
    throw new Error('GITHUB_OIDC_REPOSITORY_ID_DENIED')
  }
  if (claim(payload, 'repository_owner_id') !== EXPECTED_OWNER_ID) {
    throw new Error('GITHUB_OIDC_OWNER_ID_DENIED')
  }
  if (claim(payload, 'ref') !== EXPECTED_REF) {
    throw new Error('GITHUB_OIDC_REF_DENIED')
  }
  if (!ALLOWED_EVENTS.has(claim(payload, 'event_name'))) {
    throw new Error('GITHUB_OIDC_EVENT_DENIED')
  }
}

export function assertGitHubWorkerClaims(payload: Record<string, unknown>): void {
  assertBaseClaims(payload)
  if (claim(payload, 'workflow_ref') !== EXPECTED_WORKER_WORKFLOW_REF) {
    throw new Error('GITHUB_OIDC_WORKFLOW_DENIED')
  }
}

export function assertGitHubBirthdayClaims(payload: Record<string, unknown>): void {
  assertBaseClaims(payload)
  if (claim(payload, 'workflow_ref') !== EXPECTED_BIRTHDAY_WORKFLOW_REF) {
    throw new Error('GITHUB_OIDC_WORKFLOW_DENIED')
  }
}

export function assertGitHubOpsAlertClaims(payload: Record<string, unknown>): void {
  assertBaseClaims(payload)
  if (claim(payload, 'workflow_ref') !== EXPECTED_OPS_ALERT_WORKFLOW_REF) {
    throw new Error('GITHUB_OIDC_WORKFLOW_DENIED')
  }
}
