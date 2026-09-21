import type { NotificationTemplate } from './notification-email.ts'

export function invoicePrebookEmail(template: NotificationTemplate, manual: boolean): NotificationTemplate {
  return {
    ...template,
    title_template: 'Pré-reserva com faturamento: {{appointment.public_code}}',
    body_template: 'Olá, {{customer.name}}!\n\nSeu horário para {{service.name}}, em {{appointment.start_at}}, está guardado até {{pre_reservation.expires_at}}.\n\n'
      + (manual ? 'A reserva depende da confirmação da nossa equipe dentro desse prazo.' : 'Confirme sua reserva dentro desse prazo pelo link abaixo.')
      + '\nNão há pagamento antecipado. O vencimento do faturamento será {{invoice.due_at}}, após a confirmação.\n\nAcompanhe sua pré-reserva: {{pre_reservation.payment_url}}\n\nSem confirmação dentro do prazo, o horário será liberado.',
    html_template: null,
    variable_schema: ['customer.name','service.name','appointment.public_code','appointment.start_at','pre_reservation.expires_at','pre_reservation.payment_url','invoice.due_at'],
  }
}
