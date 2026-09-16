#!/bin/bash
# Build the Next.js frontend image, then (re)deploy it behind the nginx edge.
set -euo pipefail
# De map waar deze scripts en de broncode staan. Overschrijfbaar zodat een
# GitHub Actions-runner ze vanuit zijn eigen checkout kan draaien; standaard de
# map waar dit script zelf in staat, zodat een handmatige aanroep vanaf /opt
# blijft werken zoals hij deed.
ROOT="${BUNK_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
docker build -t bunk-frontend:latest "$ROOT/frontend"
BUNK_ROOT="$ROOT" bash "$ROOT/deploy-edge.sh"
