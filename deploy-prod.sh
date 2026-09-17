#!/bin/bash
set -euo pipefail

# Schrijft het log van een container weg voordat hij wordt vervangen, en houdt de
# laatste tien over. Bewust platte bestanden en geen logdienst: dit is een
# eenmansopstelling, en een bestand dat je met `less` kunt lezen is op het
# verkeerde moment meer waard dan een dashboard dat ook onderhouden moet worden.
BUNK_LOG_DIR="${BUNK_LOG_DIR:-/var/log/bunk}"

bewaar_log() {
  naam="$1"
  docker inspect "$naam" >/dev/null 2>&1 || return 0

  # Aanmaken mag mislukken en schrijven mag mislukken: dit script draait zowel
  # als root (handmatige uitrol) als onder de runner-gebruiker, en de map kan
  # door de ander zijn aangemaakt. Een uitrol mag NOOIT stukgaan op een logje
  # dat niet weggeschreven kan worden -- en dat is precies wat er gebeurde: de
  # map bestond, de runner mocht er niet in, en de uitrol stopte halverwege met
  # de migraties al gedraaid.
  #
  # Group-writable bij het aanmaken, zodat beide partijen erin kunnen.
  ( umask 002; mkdir -p "$BUNK_LOG_DIR" ) 2>/dev/null || true
  if [ ! -w "$BUNK_LOG_DIR" ]; then
    echo "let op: $BUNK_LOG_DIR is niet beschrijfbaar; het log van $naam gaat verloren" >&2
    return 0
  fi

  docker logs --timestamps "$naam" > "$BUNK_LOG_DIR/$naam-$(date +%Y%m%d-%H%M%S).log" 2>&1 || true
  # Opruimen: tien bestanden per container is genoeg om een dag terug te kijken.
  ls -1t "$BUNK_LOG_DIR/$naam-"*.log 2>/dev/null | tail -n +11 | xargs -r rm -f
  return 0
}
# De map waar deze scripts en de broncode staan. Overschrijfbaar zodat een
# GitHub Actions-runner ze vanuit zijn eigen checkout kan draaien; standaard de
# map waar dit script zelf in staat, zodat een handmatige aanroep vanaf /opt
# blijft werken zoals hij deed.
ROOT="${BUNK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# De secrets staan bewust NIET in de repo en niet in GitHub: ze liggen op de
# machine zelf. Een uitrol leest ze daar, waar ze al waren.
ENV_FILE="${BUNK_ENV_FILE:-/opt/bunk-fleet/.env.prod}"
NET=bunkfleet
PGNAME=bf-prod-pg
CPNAME=bf-prod-cp
IMG=bunk-fleet-cp:latest

# Dezelfde stempel als in de agentbinary: build-prod.sh schrijft hem hiernaast
# weg. Hieraan leest de uitrol af welke nodes nog op een oudere agent draaien.
BUNK_BUILD_VERSION="$(cat "$ROOT/.build-version" 2>/dev/null || echo "")"

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
PHX_HOST=app.bunkhosting.nl
PUBLIC_URL=https://app.bunkhosting.nl
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
  # mktemp -d (not -u): -u only reserves a NAME, so a pre-planted file/symlink at
  # that guessable /tmp path could make ssh-keygen prompt "Overwrite?" (hanging
  # the deploy) or follow the symlink. A 0700 dir removes both. ed25519 > RSA-2048.
  TMPD=$(mktemp -d)
  TMPK="$TMPD/key"
  ssh-keygen -t ed25519 -N '' -C bunk-console -f "$TMPK" >/dev/null
  {
    echo "CONSOLE_SSH_PRIVATE_KEY=$(base64 -w0 "$TMPK")"
    echo "CONSOLE_SSH_PUBLIC_KEY=$(base64 -w0 "${TMPK}.pub")"
    echo "CONSOLE_SSH_USER=root"
  } >> "$ENV_FILE"
  rm -rf "$TMPD"
  echo "GENERATED console SSH key"
fi

set -a; . "$ENV_FILE"; set +a
DATABASE_URL="ecto://bunkfleet:${DB_PASSWORD}@${PGNAME}/control_plane"

# 3. Postgres (persistent volume)
if ! docker ps -a --format '{{.Names}}' | grep -qx "$PGNAME"; then
  # Postgres wordt bij een uitrol NIET vervangen en draait dus maanden door:
  # zonder grens groeit zijn log tot de schijf vol is. Dat is de enige container
  # hier waar dat echt kan gebeuren.
  docker run -d --name "$PGNAME" --network "$NET" --restart unless-stopped \
    --cpu-shares 4096 \
    --log-opt max-size=50m --log-opt max-file=5 \
    -e POSTGRES_USER=bunkfleet -e POSTGRES_PASSWORD="$DB_PASSWORD" -e POSTGRES_DB=control_plane \
    -v bf-prod-pgdata:/var/lib/postgresql/data postgres:16-alpine >/dev/null
  echo "STARTED $PGNAME"
else
  docker start "$PGNAME" >/dev/null 2>&1 || true
  echo "PG already present"
fi
pg_ok=0
for i in $(seq 1 30); do docker exec "$PGNAME" pg_isready -U bunkfleet >/dev/null 2>&1 && { pg_ok=1; break; }; sleep 2; done
[ "$pg_ok" = 1 ] || { echo "FATAL: Postgres never became ready"; docker logs --tail 30 "$PGNAME"; exit 1; }

# 4. Migrate (release eval) — runtime.exs evaluates the full prod config block on
# any release command, so it needs SECRET_KEY_BASE et al. even though eval doesn't
# boot the endpoint.
echo "=== migrating ==="
# SMTP_* is passed even though migrations never send mail: runtime.exs evaluates
# the whole prod config block on any release command, and without these it prints
# its "SMTP_HOST is not set" warning on every single deploy — a false alarm that
# trains you to ignore the one message that matters when mail really is unset.
# De uitvoer gaat naar een bestand en niet door `tail`. Dat stond hier wel, en
# het kostte een avond: een migratie faalde, en omdat alleen de laatste vier
# regels werden getoond bleef er precies de stacktrace over ZONDER de regel die
# zegt wat er mis was. Een foutmelding afkappen op het aantal regels knipt altijd
# de belangrijkste eraf, want die staat bovenaan.
migratie_uitvoer=$(mktemp)
if docker run --rm --network "$NET" \
  -e DATABASE_URL="$DATABASE_URL" \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e ADMIN_TOKEN="$ADMIN_TOKEN" \
  -e PHX_HOST="$PHX_HOST" -e PUBLIC_URL="$PUBLIC_URL" -e PORT=4000 \
  -e SMTP_HOST -e SMTP_PORT -e SMTP_USERNAME -e SMTP_PASSWORD \
  -e MAIL_FROM_ADDRESS -e MAIL_FROM_NAME -e OPS_EMAIL \
  "$IMG" eval "ControlPlane.Release.migrate()" > "$migratie_uitvoer" 2>&1
then
  # Bij een geslaagde migratie is de staart genoeg: wat er is gedraaid.
  tail -4 "$migratie_uitvoer"
  rm -f "$migratie_uitvoer"
else
  echo "=== de migratie is mislukt; dit is de VOLLEDIGE uitvoer ==="
  cat "$migratie_uitvoer"
  # Ook op de machine zelf neerleggen: een workflowlog verloopt en is niet te
  # lezen zonder GitHub, en dit is het moment waarop je hem nodig hebt.
  if [ -w "$BUNK_LOG_DIR" ] 2>/dev/null; then
    cp "$migratie_uitvoer" "$BUNK_LOG_DIR/migratie-mislukt-$(date +%Y%m%d-%H%M%S).log" || true
    echo "(ook bewaard in $BUNK_LOG_DIR)"
  fi
  rm -f "$migratie_uitvoer"
  # De draaiende container is met opzet nog niet aangeraakt: een mislukte
  # migratie hoort de uitrol te stoppen mét de oude versie nog in de lucht.
  exit 1
fi

# 5. (Re)start the control-plane server
# The -e list below is an ALLOW-LIST, not a pass-through: a variable added to
# .env.prod and not added here never reaches the container, and the app behaves
# as if it were unset. That is deliberate — a stray variable in the env file
# should not silently change production — but it means this list has to be
# extended whenever a new one is introduced. ControlPlane.SecurityPosture prints
# at boot which optional protections it found switched off, which is what catches
# the mistake.
# Wat de oude container heeft gezegd, bewaren voordat hij verdwijnt.
#
# `docker rm -f` gooit het logbestand weg, en dat is precies het log waarin
# staat waaróm je aan het uitrollen bent. Na een mislukte uitrol stond je
# tot nu toe met lege handen: de nieuwe container heeft niets meegemaakt en de
# oude bestaat niet meer.
bewaar_log "$CPNAME"
docker rm -f "$CPNAME" >/dev/null 2>&1 || true
# Gewicht ten opzichte van alles wat er verder op deze machine draait. Het is
# geen limiet en geen reservering: het telt alleen als er om CPU gevochten
# wordt, en dan wint productie. Dat is hier nodig omdat de CI-runner op
# DEZELFDE twee cores bouwt. Tijdens zo'n build liep de loadaverage van 2 naar
# 34, antwoordde /healthz een derde van de keren met 504 (nginx kapt af op 5s,
# Ecto op 2), en was de machine acht minuten lang niet eens te bevragen. Een
# klant hoort niets te merken van het feit dat wij aan het uitrollen zijn.
docker run -d --name "$CPNAME" --network "$NET" --restart unless-stopped \
  --cpu-shares 4096 \
  --log-opt max-size=50m --log-opt max-file=5 \
  -p 127.0.0.1:4000:4000 \
  -e PHX_SERVER=true \
  -e BUNK_BUILD_VERSION="$BUNK_BUILD_VERSION" \
  -e DATABASE_URL="$DATABASE_URL" \
  -e SECRET_KEY_BASE="$SECRET_KEY_BASE" \
  -e ADMIN_TOKEN="$ADMIN_TOKEN" \
  -e PHX_HOST="$PHX_HOST" \
  -e PUBLIC_URL="$PUBLIC_URL" \
  -e PORT=4000 \
  -e CONSOLE_SSH_PRIVATE_KEY \
  -e CONSOLE_SSH_PUBLIC_KEY \
  -e CONSOLE_SSH_USER \
  -e CONSOLE_KEY_ENC \
  -e MOLLIE_API_KEY \
  -e SMTP_HOST \
  -e SMTP_PORT \
  -e SMTP_USERNAME \
  -e SMTP_PASSWORD \
  -e MAIL_FROM_ADDRESS \
  -e MAIL_FROM_NAME \
  -e OPS_EMAIL \
  -e TURNSTILE_SECRET_KEY \
  "$IMG" >/dev/null
echo "STARTED $CPNAME on :4000"

# 6. Health check — a crash-looping CP (bad migration, missing env) must FAIL
# the deploy, not fall through to a green "container status" summary.
health_ok=0
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:4000/api/v1/auth/me 2>/dev/null || echo 000)
  [ "$code" = "401" ] && { echo "HEALTH_OK (auth/me -> 401 as expected)"; health_ok=1; break; }
  sleep 2
done
[ "$health_ok" = 1 ] || { echo "FATAL: control plane never became healthy"; docker logs --tail 40 "$CPNAME"; exit 1; }
echo "=== container status ==="
docker ps --filter name=bf-prod --format '{{.Names}}  {{.Status}}  {{.Ports}}'

# 7. Reclaim disk — dangling images only, plus a BOUNDED build-cache trim.
#    NEVER prunes volumes or stops data containers, so customer/Postgres data is
#    never touched. Keeps the 20G disk from filling up on repeated rebuilds.
#
#    The unbounded `docker builder prune -f` that used to live here was actively
#    harmful: it deleted the entire BuildKit cache after every deploy (nothing is
#    "in use" once the build finished), so the next build re-ran apk, deps.get and
#    deps.compile from scratch — ~7 minutes instead of ~90 seconds. And it freed
#    almost nothing: measured on this host the build cache was 88MB while 5.6GB
#    sat in unused images. --keep-storage keeps the warm layers and still caps
#    growth; the dangling-image prune below is what actually reclaims space.
echo "=== reclaiming space (dangling images + capped build cache; volumes untouched) ==="
docker image prune -f >/dev/null 2>&1 || true
# --keep-storage was renamed to --reserved-space and now warns; try the current
# spelling first so this keeps working when the old flag is finally dropped.
# Both are bounded — never fall back to a bare `builder prune`, which is the
# unbounded form this replaced.
docker builder prune -f --reserved-space 2GB >/dev/null 2>&1 \
  || docker builder prune -f --keep-storage 2GB >/dev/null 2>&1 \
  || true
echo "disk: $(df -h / | awk 'NR==2{print $3" / "$2" ("$5")"}')"
