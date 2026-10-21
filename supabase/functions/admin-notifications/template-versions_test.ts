import { assertEquals } from "jsr:@std/assert@1";
import { rotateTemplateVersions, type TemplateVersions, type VersionDeps } from "./template-versions.ts";

function deps(statuses: Record<string, string | null>) {
  const removed: string[] = [];
  const value: VersionDeps = {
    statusOf: (name) => Promise.resolve(name in statuses ? statuses[name] : "PENDING"),
    nameForId: (id) => Promise.resolve(id === "111111" ? "agenda_x_old" : null),
    remove: (ref) => {
      removed.push(String(ref.name));
      return Promise.resolve(true);
    },
  };
  return { value, removed };
}

const row = (fields: Partial<TemplateVersions>): TemplateVersions => ({
  status: "APPROVED",
  provider_template_id: "111111",
  provider_template_name: "agenda_x_old",
  previous_template_name: null,
  previous_template_id: null,
  ...fields,
});

Deno.test("aprovada na Meta fica até a nova ser aprovada, mesmo com o registro como falhou", async () => {
  const { value, removed } = deps({ agenda_x_old: "APPROVED" });
  const previous = await rotateTemplateVersions(value, row({ status: "FAILED" }), {
    name: "agenda_x_new",
    id: "222222",
    approved: false,
  });
  assertEquals(previous, { name: "agenda_x_old", id: "111111" });
  assertEquals(removed, []);
});

Deno.test("não aprovada sai da Meta na hora", async () => {
  const { value, removed } = deps({ agenda_x_old: "PENDING" });
  const previous = await rotateTemplateVersions(value, row({ status: "APPROVED" }), {
    name: "agenda_x_new",
    id: "222222",
    approved: false,
  });
  assertEquals(previous, { name: null, id: null });
  assertEquals(removed, ["agenda_x_old"]);
});

Deno.test("sem resposta da Meta vale o último status conhecido", async () => {
  const { value, removed } = deps({ agenda_x_old: null });
  const kept = await rotateTemplateVersions(value, row({ status: "APPROVED" }), {
    name: "agenda_x_new",
    id: "222222",
    approved: false,
  });
  assertEquals(kept.name, "agenda_x_old");
  assertEquals(removed, []);
});

Deno.test("nova aprovada tira a guardada; nome antigo achado pelo id", async () => {
  const { value, removed } = deps({ agenda_x_old: "APPROVED" });
  const previous = await rotateTemplateVersions(
    value,
    row({ provider_template_name: null }),
    { name: "agenda_x_new", id: "222222", approved: true },
  );
  assertEquals(previous, { name: null, id: null });
  assertEquals(removed, ["agenda_x_old"]);
});

Deno.test("já excluída na Meta não é guardada nem excluída de novo", async () => {
  const { value, removed } = deps({ agenda_x_old: "NOT_FOUND" });
  const previous = await rotateTemplateVersions(value, row({}), {
    name: "agenda_x_new",
    id: "222222",
    approved: false,
  });
  assertEquals(previous, { name: null, id: null });
  assertEquals(removed, []);
});

Deno.test("modelos de outras ferramentas nunca são tocados", async () => {
  const { value, removed } = deps({});
  const previous = await rotateTemplateVersions(
    value,
    row({ provider_template_name: "kommo_followup", status: "PENDING_REVIEW" }),
    { name: "agenda_x_new", id: "222222", approved: false },
  );
  assertEquals(previous, { name: null, id: null });
  assertEquals(removed, []);
});
