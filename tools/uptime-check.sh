#!/bin/bash
# Kijkt van BUITEN de stack of Bunk nog bereikbaar is, en mailt als dat niet zo
# is.
#
# Waarom buiten: een controle die op VM102 draait zegt niets als VM102 omvalt.
# Dit script hoort op de Proxmox-host te staan (of, beter nog, op een machine
# ergens anders). Het gaat bewust via de publieke URL en niet rechtstreeks naar
# de container: het meet wat een klant meet, inclusief de Cloudflare-tunnel, de
# edge en het control plane. Valt een van die drie weg, dan is de dienst stuk,
# ook al draait het proces nog.
#
# Wat het NIET is: een dead-man-switch. Als dit script zelf stopt met draaien
# merkt niemand het. Dat vraagt een dienst buiten ons netwerk die alarm slaat
# wanneer hij niets meer hoort (healthchecks.io, UptimeRobot); zet PING_URL en
# dit script klopt daar bij elke geslaagde controle aan.
#
# Installatie: zie docs/runbooks/uptime-check.md
set -uo pipefail

URL="${BUNK_HEALTH_URL:-https://app.bunkhosting.nl/healthz}"
STATE="${BUNK_HEALTH_STATE:-/var/lib/bunk-uptime}"
# Pas alarm slaan na dit aantal mislukkingen op rij. Eén mislukte poging is een
# pakketje dat verdwaalde; drie op rij is een storing.
DREMPEL="${BUNK_HEALTH_THRESHOLD:-3}"
# Waar een dead-man-switch bij aanklopt zodra de controle slaagt. Leeg = geen.
PING_URL="${BUNK_HEALTH_PING_URL:-}"

mkdir -p "$STATE"
TELLER="$STATE/mislukkingen"
GEMELD="$STATE/gemeld"

code=$(curl -fsS -o /dev/null -m 10 -w '%{http_code}' "$URL" 2>/dev/null || echo 000)

if [ "$code" = "200" ]; then
  # Hersteld? Dan dat ook melden -- een storingsmail zonder herstelmail laat
  # iemand onnodig lang in spanning.
  if [ -f "$GEMELD" ]; then
    /usr/local/bin/bunk-mail "Bunk is weer bereikbaar" \
      "$URL geeft weer 200. De storing duurde vanaf $(cat "$GEMELD")." || true
    rm -f "$GEMELD"
  fi
  rm -f "$TELLER"
  [ -n "$PING_URL" ] && curl -fsS -m 10 "$PING_URL" >/dev/null 2>&1
  exit 0
fi

aantal=$(( $( [ -f "$TELLER" ] && cat "$TELLER" || echo 0 ) + 1 ))
echo "$aantal" > "$TELLER"

if [ "$aantal" -ge "$DREMPEL" ] && [ ! -f "$GEMELD" ]; then
  date -Is > "$GEMELD"
  /usr/local/bin/bunk-mail "Bunk is niet bereikbaar" \
    "$URL gaf $aantal keer op rij geen 200 (laatste code: $code).

Wat te controleren, in deze volgorde:
  1. draait de control plane?   docker ps | grep bf-prod-cp
  2. draait de edge?            docker ps | grep bunk-edge
  3. staat de tunnel?           pct exec 103 -- systemctl status cloudflared
  4. logs van vóór de uitrol:   ls -t /var/log/bunk/ | head" || true
fi

exit 1
