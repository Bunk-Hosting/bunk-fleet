#!/bin/bash
# Runs when the backup fails. Wired in as systemd `OnFailure=`, because a backup
# timer that quietly stops working is how backups actually fail: nobody finds out
# until the day they are needed.
#
# The alert goes out through the control plane's own mailer — the same relay that
# already sends confirmation emails, so there is no second thing to configure and
# keep working. When the control plane is the thing that is broken, this will not
# send, and that is fine: a control plane that is down has louder symptoms.
set -uo pipefail

CP_CONTAINER="${BUNK_CP_CONTAINER:-bf-prod-cp}"
UNIT="${1:-bunk-backup.service}"

log="$(journalctl -u "$UNIT" -n 40 --no-pager 2>/dev/null || echo '(no journal available)')"
body="The nightly control-plane backup failed on $(hostname) at $(date -u +%Y-%m-%dT%H:%M:%SZ).

Until it succeeds again there is no recent copy of the customer database or of
.env.prod — which carries the console SSH key.

  systemctl status $UNIT
  journalctl -u $UNIT -n 50

Last log lines:

$log"

# The body goes in base64 so a log line containing a quote, a newline or a `#{`
# cannot break out of the Elixir expression — this text is failure output, which
# is exactly the text most likely to contain something awkward.
encoded="$(printf '%s' "$body" | base64 -w0)"

# rpc, not eval: eval boots a second node, which would fight the running one for
# the database connection pool.
docker exec "$CP_CONTAINER" /app/bin/control_plane rpc \
  "ControlPlane.Notifier.deliver_operational_alert(\"backup failed on $(hostname)\", Base.decode64!(\"$encoded\"))" \
  2>&1 || echo "could not reach the control plane to send the alert" >&2
