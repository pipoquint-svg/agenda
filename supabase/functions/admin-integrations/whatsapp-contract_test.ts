import { assertEquals } from "jsr:@std/assert@1"
import { summarizeWhatsAppIntegration } from "./whatsapp-contract.ts"

Deno.test("WhatsApp projection hides provider data and reports a connected tenant", () => {
  assertEquals(summarizeWhatsAppIntegration(true, [{
    status: "CONNECTED",
    updated_at: "2026-10-15T12:00:00.000Z",
    embedded_signup_completed_at: "2026-10-15T11:59:00.000Z",
    waba_id: "must-not-leak",
  }]), {
    key: "whatsapp",
    label: "WhatsApp",
    status: "CONNECTED",
    last_sync_at: "2026-10-15T11:59:00.000Z",
    detail: { tenant_bound: true, signup_available: false, connection_ready: false },
  })
})

Deno.test("WhatsApp projection stays pending without a tenant or provider row", () => {
  assertEquals(summarizeWhatsAppIntegration(false, []), {
    key: "whatsapp",
    label: "WhatsApp",
    status: "PENDING",
    last_sync_at: null,
    detail: { tenant_bound: false, signup_available: false, connection_ready: false },
  })
})
