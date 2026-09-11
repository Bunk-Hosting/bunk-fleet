#!/bin/bash
# Builds the control-plane image with the worker agent binary bundled into its
# static dir (served at /dist/bunk-worker for the install wizard). Run before
# deploy-prod.sh:  bash build-prod.sh && bash deploy-prod.sh
set -euo pipefail
ROOT=/opt/bunk-fleet

echo "=== 1/2 building worker agent binary (linux/amd64, static) ==="
mkdir -p "$ROOT/control_plane/priv/static/dist"
# Persist the Go module + build cache across runs. This is a plain `docker run`,
# not a layered build, so without a volume every invocation re-downloads govmomi
# and x/crypto and recompiles the world — about a minute of pure waste per build.
docker volume create bunk-gocache >/dev/null 2>&1 || true
docker run --rm \
  -v "$ROOT/agent":/src \
  -v "$ROOT/control_plane/priv/static/dist":/out \
  -v bunk-gocache:/gocache \
  -e GOMODCACHE=/gocache/mod -e GOCACHE=/gocache/build \
  -w /src golang:1.23-alpine \
  sh -c 'CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /out/bunk-worker ./cmd/bunk-agent \
    && cd /out && sha256sum bunk-worker > bunk-worker.sha256'
ls -la "$ROOT/control_plane/priv/static/dist/bunk-worker" "$ROOT/control_plane/priv/static/dist/bunk-worker.sha256"
cat "$ROOT/control_plane/priv/static/dist/bunk-worker.sha256"

echo "=== 2/2 building control-plane image ==="
docker build -t bunk-fleet-cp:latest "$ROOT/control_plane"
echo "BUILT bunk-fleet-cp:latest (worker binary bundled at /dist/bunk-worker)"
