#!/usr/bin/env bash
# Syncs the Go agent source from this monorepo (agent/) into the split-out
# bunk-worker repo, rewriting the module path. bunk-fleet/agent is the single
# source of truth; bunk-worker adds only packaging (Dockerfile, deploy/,
# .github/, README.md, .gitignore), which this script never touches.
#
# Usage:
#   tools/sync-worker.sh [--check] [path-to-bunk-worker]
#
#   --check   Verify the worker copy matches (exit 1 + diff on drift), write nothing.
#             Run this in CI / before releasing bunk-worker.
#
# The default worker path assumes the sibling checkout ../bunk-worker.
set -euo pipefail

FLEET_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_DIR="$FLEET_ROOT/agent"

CHECK=0
WORKER_DIR=""
for arg in "$@"; do
  case "$arg" in
    --check) CHECK=1 ;;
    *) WORKER_DIR="$arg" ;;
  esac
done
WORKER_DIR="${WORKER_DIR:-$FLEET_ROOT/../bunk-worker}"

[ -d "$AGENT_DIR" ] || { echo "FATAL: agent dir not found: $AGENT_DIR"; exit 1; }
[ -f "$WORKER_DIR/go.mod" ] || { echo "FATAL: not a bunk-worker checkout: $WORKER_DIR"; exit 1; }

FLEET_MOD="github.com/Bunk-Hosting/bunk-fleet/agent"
WORKER_MOD="github.com/Bunk-Hosting/bunk-worker"

# Rewrites the module path and strips line-terminal CRs: git stores these files
# with LF; CRLF in a working tree is a checkout artifact (Windows autocrlf), not
# real drift, so comparisons must be line-ending-agnostic.
rewrite() { sed -e "s#$FLEET_MOD#$WORKER_MOD#g" -e 's/\r$//' "$1"; }
normalize() { sed -e 's/\r$//' "$1"; }

# The shared Go source: everything under cmd/ and internal/ (packaging files in
# the worker repo — Dockerfile, deploy/, .github/, README — are its own).
drift=0
while IFS= read -r -d '' src; do
  rel="${src#"$AGENT_DIR"/}"
  dst="$WORKER_DIR/$rel"

  if [ "$CHECK" = 1 ]; then
    if [ ! -f "$dst" ] || ! diff -q <(rewrite "$src") <(normalize "$dst") >/dev/null 2>&1; then
      echo "DRIFT: $rel"
      [ -f "$dst" ] && diff <(rewrite "$src") <(normalize "$dst") | head -20 || true
      drift=1
    fi
  else
    mkdir -p "$(dirname "$dst")"
    rewrite "$src" > "$dst"
    echo "synced: $rel"
  fi
done < <(find "$AGENT_DIR/cmd" "$AGENT_DIR/internal" -type f -name '*.go' -print0)

# Files present in the worker's shared tree but gone from the source of truth.
while IFS= read -r -d '' dst; do
  rel="${dst#"$WORKER_DIR"/}"
  if [ ! -f "$AGENT_DIR/$rel" ]; then
    if [ "$CHECK" = 1 ]; then
      echo "DRIFT (stale, no longer in agent/): $rel"
      drift=1
    else
      rm "$dst"
      echo "removed stale: $rel"
    fi
  fi
done < <(find "$WORKER_DIR/cmd" "$WORKER_DIR/internal" -type f -name '*.go' -print0)

if [ "$CHECK" = 1 ]; then
  if [ "$drift" = 1 ]; then
    echo "FAIL: bunk-worker has drifted from bunk-fleet/agent — run tools/sync-worker.sh"
    exit 1
  fi
  echo "OK: bunk-worker matches bunk-fleet/agent"
else
  echo "DONE. Now run: cd $WORKER_DIR && go build ./... && go vet ./... && go test ./..."
fi
