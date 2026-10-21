/**
 * Versões de um modelo de WhatsApp na Meta. Quando um rascunho vai para a Meta com
 * outro nome, a versão anterior é tratada assim:
 * - ainda não aprovada (em análise, rejeitada, pausada): sai da Meta na hora;
 * - aprovada: continua valendo até a nova ser aprovada, e só então sai.
 * O status da versão anterior vem da própria Meta: o registro local pode estar como
 * "falhou" depois de um envio interrompido, e isso não pode apagar uma aprovada.
 */
export type MetaTemplateRef = { name: string | null; id: string | null };

export type TemplateVersions = {
  status: string;
  provider_template_id: string | null;
  provider_template_name: string | null;
  previous_template_name: string | null;
  previous_template_id: string | null;
};

export type VersionDeps = {
  /** Status na Meta ("APPROVED", "PENDING", "NOT_FOUND"…) ou null se não deu para saber. */
  statusOf(name: string): Promise<string | null>;
  /** Nome na Meta a partir do id (registros enviados antes de guardarmos o nome). */
  nameForId(id: string): Promise<string | null>;
  /** Exclui na Meta; false mantém para tentar de novo depois. */
  remove(ref: MetaTemplateRef): Promise<boolean>;
};

const AGENDA_TEMPLATE = /^agenda_[a-z0-9_]+$/;
export const isAgendaTemplate = (name: string | null | undefined): name is string =>
  typeof name === "string" && name.length <= 512 && AGENDA_TEMPLATE.test(name);

const NONE: MetaTemplateRef = { name: null, id: null };

export async function rotateTemplateVersions(
  deps: VersionDeps,
  existing: TemplateVersions | null,
  current: { name: string; id: string | null; approved: boolean },
): Promise<MetaTemplateRef> {
  let previous: MetaTemplateRef = {
    name: existing?.previous_template_name ?? null,
    id: existing?.previous_template_id ?? null,
  };
  const oldId = existing?.provider_template_id ?? null;
  let oldName = existing?.provider_template_name ?? null;
  const replaced = existing &&
    (oldName ? oldName !== current.name : Boolean(oldId && oldId !== current.id));
  if (existing && replaced) {
    if (!oldName && oldId) oldName = await deps.nameForId(oldId).catch(() => null);
    if (oldName && oldName !== current.name && isAgendaTemplate(oldName)) {
      const old = { name: oldName, id: oldId };
      const status = await deps.statusOf(oldName).catch(() => null);
      // Sem resposta da Meta, vale o último status conhecido.
      const oldApproved = status === "APPROVED" ||
        (status === null && existing.status === "APPROVED");
      if (status === "NOT_FOUND") {
        // Já não existe na Meta: nada a guardar.
      } else if (oldApproved && !current.approved) {
        // Uma versão ainda mais antiga que estava guardada é substituída por esta.
        if (previous.name && previous.name !== oldName) await deps.remove(previous);
        previous = old;
      } else if (!(await deps.remove(old))) {
        previous = old;
      }
    }
  }
  if (previous.name === current.name) previous = NONE;
  if (current.approved && previous.name && (await deps.remove(previous))) previous = NONE;
  return previous;
}
