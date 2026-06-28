#!/bin/bash
# Build + (re)deploy the Next.js customer frontend container, durably.
set -euo pipefail
ROOT=/opt/bunk-fleet
NET=bunkfleet
NAME=bunk-frontend
IMG=bunk-frontend:latest
docker build -t "$IMG" "$ROOT/frontend"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --network "$NET" --restart unless-stopped \
  -p 3001:3000 \
  -e BUNK_API_URL=http://bf-prod-cp:4000 \
  "$IMG" >/dev/null
echo "STARTED $NAME (:3001 -> :3000, restart=unless-stopped)"
for i in $(seq 1 20); do
  code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:3001/login 2>/dev/null || echo 000)
  [ "$code" = "200" ] && { echo "FRONTEND_OK (/login -> 200)"; break; }
  sleep 2
done
