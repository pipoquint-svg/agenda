import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { recurrenceOption } from "./recurrence.ts";

Deno.test("recurrence checkbox preserves both explicit values and defaults older clients to false", () => {
  assertEquals(recurrenceOption(true), true);
  assertEquals(recurrenceOption(false), false);
  assertEquals(recurrenceOption(undefined), false);
});

Deno.test("recurrence checkbox rejects non-boolean values", () => {
  for (const value of [null, "true", 1, {}, []]) {
    assertThrows(() => recurrenceOption(value), Error, "MARKETING_CAMPAIGN_RECURRENCE_INVALID");
  }
});
