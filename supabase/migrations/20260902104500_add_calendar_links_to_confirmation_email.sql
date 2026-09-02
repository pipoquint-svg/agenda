do $$
declare
  v_template_id uuid := '5d421e7e-919b-4f89-8bde-75f135462ffe'::uuid;
  v_html text;
  v_body text;
  v_footer_marker text := '          <!-- Rodapé -->';
  v_calendar_html text := $calendar$
          <!-- Adicionar ao calendário -->
          <tr>
            <td style="padding:0 28px 24px 28px;">
              <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="width:100%; border-collapse:collapse; background-color:#FFF9F2; border:1px solid #E3DDD5; border-radius:8px;">
                <tr>
                  <td style="padding:18px 18px 8px 18px; font-family:Arial,Helvetica,sans-serif; font-size:15px; line-height:21px; font-weight:700; color:#292826;">
                    Adicione sua reserva ao calendário
                  </td>
                </tr>
                <tr>
                  <td style="padding:0 18px 14px 18px; font-family:Arial,Helvetica,sans-serif; font-size:12px; line-height:19px; color:#6D6862;">
                    Escolha onde deseja salvar este compromisso.
                  </td>
                </tr>
                <tr>
                  <td style="padding:0 18px 8px 18px;">
                    <a href="https://www.blacksheepestudiocriativo.com.br/adicionar-calendario?provider=google&amp;code={{appointment.public_code}}" style="display:block; padding:12px 16px; border:1px solid #D6CFC7; border-radius:7px; font-family:Arial,Helvetica,sans-serif; font-size:13px; line-height:18px; font-weight:700; text-align:center; color:#292826; text-decoration:none; background-color:#FFFFFF;">Google Calendar</a>
                  </td>
                </tr>
                <tr>
                  <td style="padding:0 18px 8px 18px;">
                    <a href="https://www.blacksheepestudiocriativo.com.br/adicionar-calendario?provider=apple&amp;code={{appointment.public_code}}" style="display:block; padding:12px 16px; border:1px solid #D6CFC7; border-radius:7px; font-family:Arial,Helvetica,sans-serif; font-size:13px; line-height:18px; font-weight:700; text-align:center; color:#292826; text-decoration:none; background-color:#FFFFFF;">Apple Calendar</a>
                  </td>
                </tr>
                <tr>
                  <td style="padding:0 18px 18px 18px;">
                    <a href="https://www.blacksheepestudiocriativo.com.br/adicionar-calendario?provider=outlook&amp;code={{appointment.public_code}}" style="display:block; padding:12px 16px; border:1px solid #D6CFC7; border-radius:7px; font-family:Arial,Helvetica,sans-serif; font-size:13px; line-height:18px; font-weight:700; text-align:center; color:#292826; text-decoration:none; background-color:#FFFFFF;">Outlook</a>
                  </td>
                </tr>
              </table>
            </td>
          </tr>
$calendar$;
  v_calendar_text text := E'\n\nAdicione sua reserva ao calendário:\nGoogle Calendar: https://www.blacksheepestudiocriativo.com.br/adicionar-calendario?provider=google&code={{appointment.public_code}}\nApple Calendar: https://www.blacksheepestudiocriativo.com.br/adicionar-calendario?provider=apple&code={{appointment.public_code}}\nOutlook: https://www.blacksheepestudiocriativo.com.br/adicionar-calendario?provider=outlook&code={{appointment.public_code}}';
begin
  select html_template, body_template
    into v_html, v_body
  from public.notification_template_configs
  where id = v_template_id
    and event_key = 'APPOINTMENT_APPROVED'
    and channel = 'EMAIL'
    and audience = 'CUSTOMER'
    and operation_scope = 'BLACKSHEEP'
    and is_active = true;

  if not found then
    raise exception 'ACTIVE_BLACKSHEEP_APPOINTMENT_APPROVED_EMAIL_TEMPLATE_NOT_FOUND';
  end if;

  if position('/adicionar-calendario?provider=google' in coalesce(v_html, '')) = 0 then
    if position(v_footer_marker in coalesce(v_html, '')) = 0 then
      raise exception 'APPOINTMENT_APPROVED_EMAIL_FOOTER_MARKER_NOT_FOUND';
    end if;
    v_html := replace(v_html, v_footer_marker, v_calendar_html || E'\n' || v_footer_marker);
  end if;

  if position('/adicionar-calendario?provider=google' in coalesce(v_body, '')) = 0 then
    v_body := coalesce(v_body, '') || v_calendar_text;
  end if;

  update public.notification_template_configs
  set html_template = v_html,
      body_template = v_body,
      updated_at = now()
  where id = v_template_id;
end
$$;
