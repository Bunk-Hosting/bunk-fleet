#!/bin/bash
# Edge proxy: the Cloudflare tunnel hits :3001 -> this nginx, which routes
# /ws + /api/v1 to the control plane (WebSockets need a real proxy; the Next
# rewrite can't carry them) and everything else to the Next.js frontend.
#
# Uitrollen zonder de site onderuit te halen. Dit script deed eerder
# `docker rm -f bunk-edge` gevolgd door `docker run`, en tussen die twee regels
# luisterde er niemand op poort 3001 -- precies de poort waar de Cloudflare-
# tunnel op uitkomt. Elke uitrol kostte daardoor tientallen seconden harde
# downtime, zichtbaar als een foutpagina van Cloudflare.
#
# Nu blijft nginx staan en wordt de frontend ernaast vervangen:
#   1. de nieuwe frontend start met dezelfde netwerkalias als de oude,
#   2. hij moet zelf antwoorden voordat er iets wordt weggehaald,
#   3. nginx herleest zijn configuratie in plaats van herstart te worden,
#   4. en pas daarna wordt de oude netjes gestopt, zodat lopende verzoeken
#      kunnen afmaken.
# In een proefopstelling op dezelfde machine gaf dat 200 van de 200 verzoeken
# tijdens de wissel; de oude volgorde gaf tientallen seconden niets.
set -euo pipefail

# Zie deploy-prod.sh: `docker rm -f` gooit het log weg, en dat is het log waarin
# staat waarom je aan het uitrollen was.
BUNK_LOG_DIR="${BUNK_LOG_DIR:-/var/log/bunk}"

bewaar_log() {
  naam="$1"
  docker inspect "$naam" >/dev/null 2>&1 || return 0
  mkdir -p "$BUNK_LOG_DIR" 2>/dev/null || return 0
  docker logs --timestamps "$naam" > "$BUNK_LOG_DIR/$naam-$(date +%Y%m%d-%H%M%S).log" 2>&1 || true
  ls -1t "$BUNK_LOG_DIR/$naam-"*.log 2>/dev/null | tail -n +11 | xargs -r rm -f
}

# Eén vaste map voor wat deze uitrol buiten de checkout nodig heeft: het slot en
# de nginx-configuratie. Beide moeten door root (handmatige uitrol) en door de
# Actions-runner (gebruiker gha) gedeeld worden, anders betekenen ze niets.
CONF_DIR="${BUNK_EDGE_CONF_DIR:-/etc/bunk}"
mkdir -p "$CONF_DIR" 2>/dev/null || true

# One at a time. deploy-frontend.sh ends by calling this script, so running both
# concurrently is easy to do by accident — and the result is not a slow deploy but
# a down site: the two runs interleave `docker rm -f` and `docker run`, and the
# loser deletes the container the winner just started.
#
# Het slot lag in /tmp en dat werkte niet meer: de kernel (fs.protected_regular)
# laat root een world-writable bestand van een andere gebruiker in een sticky map
# als /tmp niet openen om te schrijven. Een handmatige uitrol liep daardoor stuk
# op het slot dat de runner had achtergelaten -- en een slot dat alleen voor de
# ene partij werkt beschermt niets. Vandaar een gewone map die van beiden is.
LOCK="${BUNK_LOCK_FILE:-$CONF_DIR/deploy-edge.lock}"
if ! ( umask 000; : >> "$LOCK" ) 2>/dev/null; then
  echo "kan het slot $LOCK niet openen; controleer de rechten op $CONF_DIR" >&2
  exit 1
fi
exec 9>>"$LOCK"
flock 9

# De map waar deze scripts en de broncode staan. Overschrijfbaar zodat een
# GitHub Actions-runner ze vanuit zijn eigen checkout kan draaien; standaard de
# map waar dit script zelf in staat, zodat een handmatige aanroep vanaf /opt
# blijft werken zoals hij deed.
ROOT="${BUNK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
NET=bunkfleet
# De naam waar nginx op proxyt. Oud en nieuw dragen hem allebei tijdens de
# wissel, zodat er geen moment is waarop hij nergens heen wijst.
ALIAS=bunk-frontend-live
NIEUW=bunk-frontend-nieuw

# Eén vaste plek voor de nginx-configuratie. Een reload herleest het bestand
# waarmee de container ooit is gestart, en een handmatige uitrol (vanaf
# /opt/bunk-fleet) en de Actions-runner (vanuit zijn eigen checkout) hebben niet
# hetzelfde pad. Zonder deze vaste plek zou elke wisseling tussen die twee de
# edge opnieuw moeten opzetten -- precies de onderbreking die hier vermeden
# wordt. Lukt schrijven niet, dan mounten we alsnog vanaf de checkout; dat werkt,
# het kost alleen die ene herstart.
# Let op: IN PLAATS schrijven, niet vervangen. De container heeft dit ene bestand
# als bind-mount, en die wijst naar een inode. `install` en `mv` maken een nieuw
# bestand aan; de container blijft dan naar het oude kijken en `nginx -s reload`
# herlaadt trouw de configuratie van vóór de wijziging -- zonder een woord.
# Precies dat is hier gebeurd: de nieuwe location stond in /etc/bunk/edge.conf en
# niet in de container. `cat >` kapt hetzelfde bestand af en vult het opnieuw.
if cat "$ROOT/edge.conf" > "$CONF_DIR/edge.conf" 2>/dev/null; then
  chmod 0644 "$CONF_DIR/edge.conf" 2>/dev/null || true
  CONF="$CONF_DIR/edge.conf"
else
  echo "kan $CONF_DIR/edge.conf niet schrijven; edge mount vanaf $ROOT" >&2
  CONF="$ROOT/edge.conf"
fi

draait() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }

# 1. De nieuwe frontend ernaast.
docker rm -f "$NIEUW" >/dev/null 2>&1 || true
docker run -d --name "$NIEUW" --network "$NET" --network-alias "$ALIAS" \
  --restart unless-stopped \
  --log-opt max-size=50m --log-opt max-file=5 \
  -e BUNK_API_URL=http://bf-prod-cp:4000 \
  bunk-frontend:latest >/dev/null

# 2. Hij moet zelf antwoorden voordat de oude weggaat. Dit is het verschil
#    tussen een mislukte uitrol en een offline site: een kapotte build laat
#    vanaf hier de draaiende versie gewoon staan.
if ! docker run --rm --network "$NET" nginx:1.27-alpine sh -c \
  "for i in \$(seq 1 60); do wget -q -O- http://$NIEUW:3000/login >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"; then
  echo "de nieuwe frontend werd niet gezond; de draaiende versie blijft staan" >&2
  docker logs --tail 40 "$NIEUW" >&2 || true
  docker rm -f "$NIEUW" >/dev/null 2>&1 || true
  exit 1
fi

# 3. nginx eerst laten herlezen, en pas daarna de oude weghalen. Andersom zou er
#    een moment zijn waarop de oude al weg is terwijl nginx nog naar zijn adres
#    wijst -- juist het gat dat dit script hoort te dichten.
#
#    Een reload herleest het bestand waarmee de container ooit is gestart, niet
#    het bestand dat híér naast dit script ligt. Wijken die af, dan zou een
#    reload andermans configuratie toepassen en deze uitrol stilzwijgend
#    overslaan; in dat geval wordt de edge opnieuw opgezet.
MOUNT=$(docker inspect bunk-edge \
  --format '{{range .Mounts}}{{if eq .Destination "/etc/nginx/conf.d/default.conf"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)

if draait bunk-edge && [ "$MOUNT" = "$CONF" ]; then
  # `nginx -t` eerst: een fout in de configuratie mag een draaiende edge niet
  # meeslepen. Hij blijft dan gewoon op zijn oude configuratie staan.
  # Ziet de container wel wat wij denken te sturen? Zo niet heeft hij een oude
  # inode te pakken en zou een reload stilzwijgend niets doen -- dan liever hem
  # opnieuw opzetten dan doorgaan met een configuratie die we niet kennen.
  bron=$(sha256sum "$CONF" | cut -d" " -f1)
  in_container=$(docker exec bunk-edge sha256sum /etc/nginx/conf.d/default.conf 2>/dev/null | cut -d" " -f1)

  if [ "$bron" != "$in_container" ]; then
    echo "edge: de container ziet een andere edge.conf dan wij schrijven; opnieuw opzetten" >&2
    bewaar_log bunk-edge
    docker rm -f bunk-edge >/dev/null 2>&1 || true
    docker run -d --name bunk-edge --network "$NET" --restart unless-stopped \
      --log-opt max-size=50m --log-opt max-file=5 \
      -p 3001:80 \
      -v "$CONF":/etc/nginx/conf.d/default.conf:ro \
      nginx:1.27-alpine >/dev/null
  elif docker exec bunk-edge nginx -t >/dev/null 2>&1; then
    docker exec bunk-edge nginx -s reload
    echo "edge: configuratie herladen"
  else
    echo "edge.conf is ongeldig; de draaiende edge blijft op zijn oude configuratie" >&2
    docker exec bunk-edge nginx -t >&2 || true
    docker rm -f "$NIEUW" >/dev/null 2>&1 || true
    exit 1
  fi
else
  bewaar_log bunk-edge
  docker rm -f bunk-edge >/dev/null 2>&1 || true
  docker run -d --name bunk-edge --network "$NET" --restart unless-stopped \
    --log-opt max-size=50m --log-opt max-file=5 \
    -p 3001:80 \
    -v "$CONF":/etc/nginx/conf.d/default.conf:ro \
    nginx:1.27-alpine >/dev/null
  echo "edge: opnieuw opgezet (draaide niet, of stond op een ander edge.conf)"
fi

# 4. Pas nu de oude weg. Netjes stoppen: verzoeken die al onderweg zijn mogen
#    af, en pas daarna verdwijnt dat adres achter de alias.
if draait bunk-frontend; then
  docker stop -t 10 bunk-frontend >/dev/null
fi
bewaar_log bunk-frontend
docker rm -f bunk-frontend >/dev/null 2>&1 || true
docker rename "$NIEUW" bunk-frontend

echo "edge: $(docker inspect -f '{{.State.Status}}' bunk-edge)  frontend: $(docker inspect -f '{{.State.Status}}' bunk-frontend)"
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001/login 2>/dev/null || echo 000)
  [ "$code" = "200" ] && { echo "EDGE_OK (/login -> 200)"; exit 0; }
  sleep 2
done
echo "EDGE NIET OK: /login gaf $code" >&2
exit 1
