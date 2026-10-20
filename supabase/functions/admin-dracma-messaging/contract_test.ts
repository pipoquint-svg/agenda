import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import {
  clientPayload,
  messagingStatus,
  operationFor,
  ownedNumberBrowserResult,
  ownedNumberConnection,
} from "./contract.ts";

const CONNECTED = {
  contract: "DRACMA_AGENDA_OWNED_NUMBER_V1",
  status: "CONNECTED",
  waba_id: "1254994936060601",
  phone_number_id: "700000000000001",
  display_name: "Black Sheep Estúdio Criativo",
  masked_phone: "•••• 6969",
  webhook_subscribed: true,
};

Deno.test("accepts the owned-number operation without a browser payload", () => {
  assertEquals(
    operationFor("POST", { operation: "connect_owned_number" }),
    "CONNECT_OWNED_NUMBER",
  );
  assertEquals(
    clientPayload("CONNECT_OWNED_NUMBER", {
      operation: "CONNECT_OWNED_NUMBER",
      payload: { waba_id: "1" },
    }),
    undefined,
  );
  assertEquals(operationFor("GET", undefined), "START_SESSION");
  assertThrows(
    () => operationFor("POST", { operation: "SEND_MESSAGE" }),
    Error,
    "DRACMA_MESSAGING_OPERATION_INVALID",
  );
  assertThrows(
    () => clientPayload("COMPLETE_SESSION", {}),
    Error,
    "DRACMA_MESSAGING_PAYLOAD_INVALID",
  );
});

Deno.test("reports owned-number availability only as a boolean", () => {
  assertEquals(
    messagingStatus({
      status: "READY",
      signup_available: true,
      owned_number_available: true,
      organization_id: "hidden",
    }),
    { status: "READY", signup_available: true, owned_number_available: true },
  );
  assertEquals(
    messagingStatus({ status: "READY", signup_available: false })
      .owned_number_available,
    false,
  );
  assertThrows(
    () => messagingStatus({ status: "READY" }),
    Error,
    "DRACMA_MESSAGING_GATEWAY_INVALID",
  );
});

Deno.test("stores provider ids server-side and shows only the masked number", () => {
  const connection = ownedNumberConnection(CONNECTED);
  assertEquals(connection.waba_id, "1254994936060601");
  assertEquals(ownedNumberBrowserResult(connection, true), {
    status: "CONNECTED",
    display_name: "Black Sheep Estúdio Criativo",
    masked_phone: "•••• 6969",
    projection: "SAVED",
  });
  assertEquals(
    ownedNumberBrowserResult(connection, false).projection,
    "PENDING",
  );
});

Deno.test("rejects an incomplete or unmasked Dracma result", () => {
  for (
    const payload of [
      { ...CONNECTED, status: "READY" },
      { ...CONNECTED, waba_id: "abc" },
      { ...CONNECTED, masked_phone: "+55 48 99222-6969" },
      { ...CONNECTED, display_name: "" },
      null,
    ]
  ) {
    assertThrows(
      () => ownedNumberConnection(payload),
      Error,
      "DRACMA_MESSAGING_GATEWAY_INVALID",
    );
  }
});
