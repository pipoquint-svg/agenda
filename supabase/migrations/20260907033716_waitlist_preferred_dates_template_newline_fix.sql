update public.notification_template_configs
set body_template = replace(body_template, E'{{waitlist.preferred_dates}}\\nInscrição:', E'{{waitlist.preferred_dates}}\nInscrição:'),
    updated_at = now()
where event_key='WAITLIST_SIGNUP_TEAM' and is_active;