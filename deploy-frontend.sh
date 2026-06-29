#!/bin/bash
# Build the Next.js frontend image, then (re)deploy it behind the nginx edge.
set -euo pipefail
docker build -t bunk-frontend:latest /opt/bunk-fleet/frontend
bash /opt/bunk-fleet/deploy-edge.sh
