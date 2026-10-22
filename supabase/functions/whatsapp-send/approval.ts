import { submissionStatus } from '../admin-notifications/whatsapp-template.ts'

export type Submission = { status: string | null; provider_template_name: string | null; submitted_at: string | null }
type Gateway = (request: { operation: 'TEMPLATE_STATUS'; payload: { names: string[] } }) => Promise<Record<string, unknown>>
type Save = (approvedAt: string) => Promise<void>

/** Meta's answer for one template name: approved or not. */
export function approvedByMeta(result: Record<string, unknown>, name: string) {
  const templates = Array.isArray(result.templates) ? result.templates as Record<string, unknown>[] : []
  const provider = templates.find((item) => String(item.name ?? '') === name)
  return submissionStatus(provider?.status)?.status === 'APPROVED'
}

/**
 * A message whose new text is still under Meta review is checked with Meta when it is
 * about to go out: once approved, the submission is marked approved and the message
 * goes, without anyone opening Gestão to refresh the status.
 */
export async function currentSubmission(submission: Submission | null, gateway: Gateway, save: Save): Promise<Submission | null> {
  if (submission?.status !== 'PENDING_REVIEW' || !submission.provider_template_name) return submission
  const result = await gateway({ operation: 'TEMPLATE_STATUS', payload: { names: [submission.provider_template_name] } })
  if (!approvedByMeta(result, submission.provider_template_name)) return submission
  await save(new Date().toISOString())
  return { ...submission, status: 'APPROVED' }
}
