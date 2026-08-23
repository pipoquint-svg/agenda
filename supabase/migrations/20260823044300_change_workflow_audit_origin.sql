-- Client-originated change workflows were persisting audit origin as ADMIN in the
-- final cancel/apply steps even when the policy action explicitly said CLIENT.
-- Rewrite only that final audit argument, preserving the already-tested workflow body.

do $$
declare
  v_def text;
  v_new text;
  v_old text := $$),'ADMIN');$$;
  v_replacement text := $$),case when p_change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);$$;
begin
  v_def := pg_get_functiondef('public.service_admin_cancel_appointment(uuid,text,text,timestamptz,text,uuid)'::regprocedure);
  if strpos(v_def, v_old) = 0 then
    raise exception 'CANCEL_AUDIT_ORIGIN_PATTERN_NOT_FOUND';
  end if;
  v_new := replace(v_def, v_old, v_replacement);
  if v_new = v_def then
    raise exception 'CANCEL_AUDIT_ORIGIN_NOT_REWRITTEN';
  end if;
  execute v_new;
end;
$$;

do $$
declare
  v_def text;
  v_new text;
  v_old text := $$),'ADMIN');$$;
  v_replacement text := $$),case when v_action.change_origin='CLIENT' then 'CLIENT' else 'ADMIN' end);$$;
begin
  v_def := pg_get_functiondef('public.service_admin_apply_reschedule(uuid,uuid)'::regprocedure);
  if strpos(v_def, v_old) = 0 then
    raise exception 'RESCHEDULE_AUDIT_ORIGIN_PATTERN_NOT_FOUND';
  end if;
  v_new := replace(v_def, v_old, v_replacement);
  if v_new = v_def then
    raise exception 'RESCHEDULE_AUDIT_ORIGIN_NOT_REWRITTEN';
  end if;
  execute v_new;
end;
$$;
