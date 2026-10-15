import { assertEquals, assertRejects } from "jsr:@std/assert@1"
import { DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT, signAgendaMessagingHandoff } from "./dracma-messaging-handoff.ts"

const secret = "01234567890123456789012345678901"
const handoff = {
  contract: DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT as typeof DRACMA_AGENDA_MESSAGING_HANDOFF_CONTRACT,
  request_id: "10000000-0000-4000-8000-000000000001",
  agenda_tenant_id: "20000000-0000-4000-8000-000000000001",
  agenda_admin_id: "30000000-0000-4000-8000-000000000001",
  operation: "START_SESSION" as const,
  issued_at: "2026-10-15T12:00:00.000Z",
  expires_at: "2026-10-15T12:01:00.000Z",
}

Deno.test("Agenda handoff is deterministic and bounded", async () => {
  assertEquals(await signAgendaMessagingHandoff(secret, handoff), await signAgendaMessagingHandoff(secret, handoff))
})

Deno.test("Agenda handoff rejects an excessive lifetime", async () => {
  await assertRejects(() => signAgendaMessagingHandoff(secret, { ...handoff, expires_at: "2026-10-15T12:03:00.000Z" }), Error, "AGENDA_MESSAGING_HANDOFF_TTL_INVALID")
})
