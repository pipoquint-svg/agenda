create index service_waitlist_entries_booking_page_idx
  on public.service_waitlist_entries(booking_page_id);

create index service_waitlist_entries_contacted_by_admin_idx
  on public.service_waitlist_entries(contacted_by_admin_id)
  where contacted_by_admin_id is not null;
