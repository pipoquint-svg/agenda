import type { ChangePolicy, PenaltyType } from './serviceSettingsApi'

export const defaultChangePolicy: ChangePolicy = {
  notice_hours: 48,
  reschedule_first_penalty_type: 'NONE',
  reschedule_first_penalty_value: 0,
  reschedule_repeat_penalty_type: 'PERCENT',
  reschedule_repeat_penalty_value: 20,
  reschedule_late_penalty_type: 'PERCENT',
  reschedule_late_penalty_value: 20,
  cancellation_early_penalty_type: 'NONE',
  cancellation_early_penalty_value: 0,
  cancellation_late_penalty_type: 'PERCENT',
  cancellation_late_penalty_value: 20,
  cancellation_early_refund_allowed: true,
  cancellation_early_credit_allowed: true,
  cancellation_late_refund_allowed: true,
  cancellation_late_credit_allowed: true,
  cancellation_credit_validity_days: 90,
}

function penaltyLabel(type: PenaltyType): string {
  if (type === 'FIXED') return 'Valor da multa (R$)'
  if (type === 'PERCENT') return 'Percentual da multa (%)'
  return 'Sem multa'
}

function PenaltyControl({
  title,
  type,
  value,
  onType,
  onValue,
}: {
  title: string
  type: PenaltyType
  value: number | string
  onType: (value: PenaltyType) => void
  onValue: (value: number) => void
}) {
  return (
    <div className="policy-penalty-card">
      <strong>{title}</strong>
      <label>
        <span>Multa</span>
        <select value={type} onChange={(event) => onType(event.target.value as PenaltyType)}>
          <option value="NONE">Sem multa</option>
          <option value="FIXED">Valor fixo em R$</option>
          <option value="PERCENT">Percentual do contrato</option>
        </select>
      </label>
      {type !== 'NONE' ? (
        <label>
          <span>{penaltyLabel(type)}</span>
          <input
            type="number"
            min="0"
            max={type === 'PERCENT' ? 100 : undefined}
            step={type === 'PERCENT' ? 1 : 0.01}
            value={Number(value ?? 0)}
            onChange={(event) => onValue(Number(event.target.value))}
          />
        </label>
      ) : <small>Nenhum valor será cobrado por esta condição.</small>}
    </div>
  )
}

export function ChangePolicyEditor({
  policy,
  saving,
  onChange,
  onSave,
}: {
  policy: ChangePolicy
  saving: boolean
  onChange: (policy: ChangePolicy) => void
  onSave: () => void
}) {
  function patch(values: Partial<ChangePolicy>) {
    onChange({ ...policy, ...values })
  }

  return (
    <section className="settings-card policy-settings-card">
      <div className="settings-card-heading">
        <div>
          <h2>Remarcação e cancelamento</h2>
          <p>Esta política é exclusiva deste serviço. O cálculo usa o valor real da reserva no momento da solicitação.</p>
        </div>
      </div>

      <div className="policy-window-row">
        <label>
          <span>Janela de antecedência</span>
          <div className="policy-input-suffix">
            <input type="number" min="0" value={policy.notice_hours} onChange={(event) => patch({ notice_hours: Number(event.target.value) })} />
            <span>horas</span>
          </div>
          <small>Antes desta janela vale a regra antecipada; dentro dela vale a regra tardia.</small>
        </label>
      </div>

      <div className="policy-section">
        <div className="policy-section-title">
          <div><h3>Remarcação</h3><p>O cliente escolhe uma nova data. A reincidência pode ter regra própria.</p></div>
        </div>
        <div className="policy-penalty-grid">
          <PenaltyControl
            title={`1ª remarcação — mais de ${policy.notice_hours}h antes`}
            type={policy.reschedule_first_penalty_type}
            value={policy.reschedule_first_penalty_value}
            onType={(value) => patch({ reschedule_first_penalty_type: value, reschedule_first_penalty_value: value === 'NONE' ? 0 : Number(policy.reschedule_first_penalty_value) })}
            onValue={(value) => patch({ reschedule_first_penalty_value: value })}
          />
          <PenaltyControl
            title={`Reincidência — mais de ${policy.notice_hours}h antes`}
            type={policy.reschedule_repeat_penalty_type}
            value={policy.reschedule_repeat_penalty_value}
            onType={(value) => patch({ reschedule_repeat_penalty_type: value, reschedule_repeat_penalty_value: value === 'NONE' ? 0 : Number(policy.reschedule_repeat_penalty_value) })}
            onValue={(value) => patch({ reschedule_repeat_penalty_value: value })}
          />
          <PenaltyControl
            title={`Qualquer remarcação — menos de ${policy.notice_hours}h`}
            type={policy.reschedule_late_penalty_type}
            value={policy.reschedule_late_penalty_value}
            onType={(value) => patch({ reschedule_late_penalty_type: value, reschedule_late_penalty_value: value === 'NONE' ? 0 : Number(policy.reschedule_late_penalty_value) })}
            onValue={(value) => patch({ reschedule_late_penalty_value: value })}
          />
        </div>
      </div>

      <div className="policy-section">
        <div className="policy-section-title">
          <div><h3>Cancelamento</h3><p>Define a retenção e quais formas de devolução ficam disponíveis ao cliente.</p></div>
        </div>
        <div className="policy-cancel-grid">
          <div className="policy-cancel-window">
            <PenaltyControl
              title={`Mais de ${policy.notice_hours}h antes`}
              type={policy.cancellation_early_penalty_type}
              value={policy.cancellation_early_penalty_value}
              onType={(value) => patch({ cancellation_early_penalty_type: value, cancellation_early_penalty_value: value === 'NONE' ? 0 : Number(policy.cancellation_early_penalty_value) })}
              onValue={(value) => patch({ cancellation_early_penalty_value: value })}
            />
            <div className="policy-options">
              <label className="settings-check"><input type="checkbox" checked={policy.cancellation_early_refund_allowed} onChange={(event) => patch({ cancellation_early_refund_allowed: event.target.checked })} /><span>Permitir estorno do saldo elegível</span></label>
              <label className="settings-check"><input type="checkbox" checked={policy.cancellation_early_credit_allowed} onChange={(event) => patch({ cancellation_early_credit_allowed: event.target.checked })} /><span>Permitir crédito de uso</span></label>
            </div>
          </div>

          <div className="policy-cancel-window">
            <PenaltyControl
              title={`Menos de ${policy.notice_hours}h`}
              type={policy.cancellation_late_penalty_type}
              value={policy.cancellation_late_penalty_value}
              onType={(value) => patch({ cancellation_late_penalty_type: value, cancellation_late_penalty_value: value === 'NONE' ? 0 : Number(policy.cancellation_late_penalty_value) })}
              onValue={(value) => patch({ cancellation_late_penalty_value: value })}
            />
            <div className="policy-options">
              <label className="settings-check"><input type="checkbox" checked={policy.cancellation_late_refund_allowed} onChange={(event) => patch({ cancellation_late_refund_allowed: event.target.checked })} /><span>Permitir estorno do saldo elegível</span></label>
              <label className="settings-check"><input type="checkbox" checked={policy.cancellation_late_credit_allowed} onChange={(event) => patch({ cancellation_late_credit_allowed: event.target.checked })} /><span>Permitir crédito de uso</span></label>
            </div>
          </div>
        </div>

        <label className="policy-credit-days">
          <span>Validade do crédito de cancelamento</span>
          <div className="policy-input-suffix">
            <input type="number" min="1" value={policy.cancellation_credit_validity_days} onChange={(event) => patch({ cancellation_credit_validity_days: Number(event.target.value) })} />
            <span>dias</span>
          </div>
          <small>Usado apenas quando a opção de crédito estiver habilitada e escolhida.</small>
        </label>
      </div>

      <div className="settings-rule-callout policy-summary">
        <strong>Regra operacional</strong>
        <span>Multa fixa retém até o valor configurado; percentual é calculado sobre o valor total contratado. Reembolso/crédito considera o valor efetivamente pago e a multa aplicável.</span>
      </div>

      <button className="primary" type="button" disabled={saving} onClick={onSave}>{saving ? 'Salvando…' : 'Salvar política deste serviço'}</button>
    </section>
  )
}
