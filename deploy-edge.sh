#!/bin/bash
# Edge proxy: the Cloudflare tunnel hits :3001 -> this nginx, which routes
# /ws + /api/v1 to the control plane (WebSockets need a real proxy; the Next
# rewrite can't carry them) and everything else to the Next.js frontend.
set -euo pipefail

# One at a time. deploy-frontend.sh ends by calling this script, so running both
# concurrently is easy to do by accident — and the result is not a slow deploy but
# a down site: the two runs interleave `docker rm -f` and `docker run`, and the
# loser deletes the container the winner just started.
exec 9>/tmp/bunk-deploy-edge.lock
flock 9

NET=bunkfleet
# frontend: internal only now (nginx fronts it)
docker rm -f bunk-frontend >/dev/null 2>&1 || true
docker run -d --name bunk-frontend --network "$NET" --restart unless-stopped \
  -e BUNK_API_URL=http://bf-prod-cp:4000 \
  bunk-frontend:latest >/dev/null
# nginx edge on :3001
docker rm -f bunk-edge >/dev/null 2>&1 || true
docker run -d --name bunk-edge --network "$NET" --restart unless-stopped \
  -p 3001:80 \
  -v /opt/bunk-fleet/edge.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:1.27-alpine >/dev/null
sleep 2
echo "edge: $(docker inspect -f '{{.State.Status}}' bunk-edge)  frontend: $(docker inspect -f '{{.State.Status}}' bunk-frontend)"
for i in $(seq 1 15); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:3001/login 2>/dev/null || echo 000)
  [ "$code" = "200" ] && { echo "EDGE_OK (/login -> 200)"; break; }
  sleep 2
done
