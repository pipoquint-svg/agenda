-- Optional URL button on a WhatsApp draft: its label and which customer link
-- it opens. The link itself is built per message; only the choice is stored.

alter table public.notification_whatsapp_settings
  add column button_text text null,
  add column button_variable text null;

alter table public.notification_whatsapp_settings
  add constraint notification_whatsapp_settings_button_check check (
    (button_text is null and button_variable is null)
    or (
      char_length(button_text) between 1 and 25
      and button_text !~ '\{\{'
      and button_variable in (
        'appointment.manage_url', 'pre_reservation.payment_url', 'balance.payment_url', 'payment.resume_url'
      )
    )
  );
