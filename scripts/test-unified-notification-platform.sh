#!/usr/bin/env bash
set -euo pipefail

root='supabase/functions'
confirmation="$root/email-send/index.ts"
balance="$root/balance-collection-notify-email/index.ts"
birthday="$root/birthday-email-worker/index.ts"
admin_notifications="$root/admin-notifications/index.ts"
auth="$root/auth-send-email/index.ts"

fail() {
  echo "NOTIFICATION_PLATFORM_INVARIANT_FAILED: $1" >&2
  exit 1
}

for flow in "$confirmation" "$balance" "$birthday" "$admin_notifications"; do
  grep -Fq 'notificationSenderForScope' "$flow" || fail "$flow bypasses the canonical notification sender"
  grep -Fq 'sendEmailWithProvider' "$flow" || fail "$flow bypasses the canonical provider"
  grep -Fq 'renderNotificationMessage' "$flow" || fail "$flow bypasses the shared renderer"

  if grep -Eqi '<!doctype|<html|<body' "$flow"; then
    fail "$flow contains inline email HTML"
  fi
  if grep -Eqi 'build[A-Za-z0-9_]*Email' "$flow"; then
    fail "$flow contains a hard-coded email builder fallback"
  fi
  if grep -Eq "EMAIL_FROM_(BLACKSHEEP|SABRINA)|EMAIL_REPLY_TO_(BLACKSHEEP|SABRINA)" "$flow"; then
    fail "$flow reads sender environment variables directly"
  fi
done

for flow in "$confirmation" "$balance"; do
  grep -Fq 'resolve_notification_template' "$flow" || fail "$flow does not resolve its active database template"
  grep -Fq 'beginNotificationDelivery' "$flow" || fail "$flow does not create/update notification_delivery_logs"
  grep -Fq 'markNotificationSent' "$flow" || fail "$flow does not mark successful deliveries"
  grep -Fq 'markNotificationFailed' "$flow" || fail "$flow does not persist provider failures"
done

grep -Fq 'claim_birthday_notification_deliveries' "$birthday" || fail 'birthday worker does not claim central delivery logs'
grep -Fq 'finalize_birthday_notification_delivery' "$birthday" || fail 'birthday worker does not finalize central delivery logs'
grep -Fq 'fail_birthday_notification_delivery' "$birthday" || fail 'birthday worker does not persist central delivery failures'

grep -Fq 'beginNotificationDelivery' "$admin_notifications" || fail 'admin test-send does not create a central delivery log'
grep -Fq 'isTest: true' "$admin_notifications" || fail 'admin test-send is not marked as test evidence'
grep -Fq 'markNotificationSent' "$admin_notifications" || fail 'admin test-send does not mark successful delivery'
grep -Fq 'markNotificationFailed' "$admin_notifications" || fail 'admin test-send does not persist provider failure'

# Auth convergence is intentionally deferred. Lock the boundary so this Etapa 2
# cannot silently change Supabase Auth sender/template behavior.
grep -Fq 'senderForScope' "$auth" || fail 'Auth sender boundary changed unexpectedly'
if grep -Fq 'notificationSenderForScope' "$auth"; then
  fail 'Auth was converged into the notification platform before its dedicated stage'
fi

echo 'Unified notification platform invariant: OK'
