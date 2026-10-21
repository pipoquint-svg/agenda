import type { adminClient } from './supabase.ts'

/**
 * Diferença de remarcação (ou acréscimo de tempo) aprovada: aplica a remarcação da
 * cliente na hora, para ela nunca ficar paga e não remarcada. Sem remarcação pendente
 * no pagamento, não faz nada. Falhar aqui não desfaz o pagamento já registrado; a
 * falha fica na auditoria (RESCHEDULE_AUTO_APPLY_FAILED).
 */
export async function applyPaidClientReschedule(
  client: ReturnType<typeof adminClient>,
  transactionId: string,
): Promise<void> {
  try {
    const { data, error } = await client.rpc('service_apply_paid_client_reschedule', { p_transaction_id: transactionId })
    if (error) {
      console.error('PAID_RESCHEDULE_APPLY_FAILED', error.message.slice(0, 120))
      return
    }
    const result = data as { applied?: boolean; reason?: string } | null
    if (result?.reason === 'APPLY_FAILED') console.error('PAID_RESCHEDULE_APPLY_FAILED', 'APPLY_FAILED')
  } catch (error) {
    console.error('PAID_RESCHEDULE_APPLY_FAILED', error instanceof Error ? error.message.slice(0, 120) : 'unknown')
  }
}
