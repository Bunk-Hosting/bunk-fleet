#!/bin/bash
set -euo pipefail
ENV_FILE=/opt/bunk-fleet/.env.prod
NET=bunkfleet
PGNAME=bf-prod-pg
CPNAME=bf-prod-cp
IMG=bunk-fleet-cp:latest

# 1. Network (idempotent)
docker network inspect "$NET" >/dev/null 2>&1 || docker network create "$NET" >/dev/null

# 2. Secrets — generate once, reuse on redeploy (don't rotate tokens silently)
if [ ! -f "$ENV_FILE" ]; then
  umask 077
  DBPASS=$(openssl rand -hex 16)
  SKB=$(openssl rand -base64 64 | tr -d '\n')
  ADMTOK=$(openssl rand -hex 32)
  cat > "$ENV_FILE" <<EOF
DB_PASSWORD=$DBPASS
SECRET_KEY_BASE=$SKB
ADMIN_TOKEN=$ADMTOK
PHX_HOST=control.bunkhosting.nl
PUBLIC_URL=https://control.bunkhosting.nl
PORT=4000
EOF
  chmod 600 "$ENV_FILE"
  echo "GENERATED new $ENV_FILE"
else
  echo "REUSING existing $ENV_FILE"
fi
# Console SSH key — the in-browser console SSHes into VPSes with this; its public
# key is injected into every VPS via cloud-init. Generated once, base64 in the env.
if ! grep -q '^CONSOLE_SSH_PRIVATE_KEY=' "$ENV_FILE"; then
  TMPK=$(mktemp -u)
  ssh-keygen -t rsa -b 2048 -m PEM -N '' -C bunk-console -f "$TMPK" >/dev/null
  {
    echo "CONSOLE_SSH_PRIVATE_KEY=$(base64 -w0 "$TMPK")"
    echo "CONSOLE_SSH_PUBLIC_KEY=$(base64 -w0 "${TMPK}.pub")"
    echo "CONSOLE_SSH_USER=root"
  } >> "$ENV_FILE"
  rm -f "$TMPK" "${TMPK}.pub"
  echo "GENERATED console SSH key"
fi

set -a; . "$ENV_FILE"; set +a
DATABASE_URL="ecto://bunkfleet:${DB_PASSWORD}@${PGNAME}/control_plane"

# 3. Postgres (persistent volume)
if ! docker ps -a --format '{{.Names}}' | grep -qx "$PGNAME"; then
  docker run -d --name "$PGNAME" --network "$NET" --restart unless-stopped \
    -e POSTGRES_USER=bunkfleet -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=control_plane \
    -v bf-prod-pgdata:/var/lib/postgresql/data postgres:16-alpine >/dev/null
  echo "STARTED $PGNAME"
else
  docker start "$PGNAME" >/dev/null 2>&1 || true
  echo "PG already present"
fi
for i in $(seq 1 30); do docker exec "$PGNAME" pg_isready -U bunkfleet >/dev/null 2>&1 && break; sleep 2; done

# 4. Migrate (release eval) — runtime.exs evaluates the full prod config block on
# any release command, so it needs SECRET_KEY_BASE et al. even though eval doesn't
# boot the endpoint.
echo "=== migrating ==="
docker run --rm --network "$NET" \
  -e DATABASE_URL="$DATABASE_URL" \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e ADMIN_TOKEN="$ADMIN_TOKEN" \
  -e PHX_HOST="$PHX_HOST" -e PUBLIC_URL="$PUBLIC_URL" -e PORT=4000 \
  "$IMG" eval "ControlPlane.Release.migrate()" 2>&1 | tail -4

# 5. (Re)start the control-plane server
docker rm -f "$CPNAME" >/dev/null 2>&1 || true
docker run -d --name "$CPNAME" --network "$NET" --restart unless-stopped \
  -p 4000:4000 \
  -e PHX_SERVER=true \
  -e DATABASE_URL="$DATABASE_URL" \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e ADMIN_TOKEN="$ADMIN_TOKEN" \
  -e PHX_HOST="$PHX_HOST" \
  -e PUBLIC_URL="$PUBLIC_URL" \
  -e PORT=4000 \
  -e CONSOLE_SSH_PRIVATE_KEY \
  -e CONSOLE_SSH_PUBLIC_KEY \
  -e CONSOLE_SSH_USER \
  "$IMG" >/dev/null
echo "STARTED $CPNAME on :4000"

# 6. Health check
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/api/v1/auth/me 2>/dev/null || echo 000)
  [ "$code" = "401" ] && { echo "HEALTH_OK (auth/me -> 401 as expected)"; break; }
  sleep 2
done
echo "=== container status ==="
docker ps --filter name=bf-prod --format '{{.Names}}  {{.Status}}  {{.Ports}}'
