#!/bin/bash
# Full verification gate: format, compile-with-warnings-as-errors and tests for
# both components, all inside containers.
#
# Why containers: the control plane is developed from a box with no Elixir and no
# Go toolchain, so `mix test` on the host is not an option. The top-level Makefile
# targets (test-control-plane etc.) assume a local toolchain and only work where
# one exists; this script is the version that runs anywhere Docker does.
#
# Run this BEFORE pushing. Everything it checks is cheap compared to discovering
# a syntax error part-way through a seven-minute production image build.
#
#   bash tools/check.sh            # everything
#   bash tools/check.sh elixir     # control plane only
#   bash tools/check.sh go         # agent only
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHAT="${1:-all}"

# The test database lives beside the production one on the shared docker network;
# MIX_ENV=test keeps it in control_plane_test, never control_plane.
NET="${BUNK_NET:-bunkfleet}"
DB_HOST="${BUNK_DB_HOST:-bf-prod-pg}"
DB_USER="${BUNK_DB_USER:-bunkfleet}"
DB_PASSWORD="${BUNK_DB_PASSWORD:-}"

fail() { echo "FAIL: $*" >&2; exit 1; }

check_elixir() {
  [ -n "$DB_PASSWORD" ] || fail "BUNK_DB_PASSWORD is required for the Elixir suite"

  echo "=== control plane: format + compile + test ==="
  docker run --rm --network "$NET" \
    -v "$ROOT/control_plane":/app -w /app \
    -e MIX_ENV=test \
    -e DB_HOST="$DB_HOST" -e DB_USER="$DB_USER" -e DB_PASSWORD="$DB_PASSWORD" \
    elixir:1.17-alpine sh -eu -c '
      mix local.hex --force >/dev/null
      mix local.rebar --force >/dev/null
      mix deps.get >/dev/null
      echo "--- mix format --check-formatted ---"
      mix format --check-formatted
      echo "--- mix compile --warnings-as-errors ---"
      mix compile --warnings-as-errors
      echo "--- mix test ---"
      mix test
    '
}

check_go() {
  echo "=== agent: gofmt + vet + test ==="
  docker volume create bunk-gocache >/dev/null 2>&1 || true
  docker run --rm \
    -v "$ROOT/agent":/src -w /src \
    -v bunk-gocache:/gocache \
    -e GOMODCACHE=/gocache/mod -e GOCACHE=/gocache/build \
    golang:1.23-alpine sh -eu -c '
      echo "--- gofmt ---"
      unformatted=$(gofmt -l .)
      [ -z "$unformatted" ] || { echo "unformatted files:"; echo "$unformatted"; exit 1; }
      echo "--- go vet ---"
      go vet ./...
      echo "--- go test ---"
      go test ./...
    '
}

case "$WHAT" in
  all)    check_elixir; check_go ;;
  elixir) check_elixir ;;
  go)     check_go ;;
  *)      fail "unknown target '$WHAT' (expected: all | elixir | go)" ;;
esac

echo "=== ALLES GROEN ==="
