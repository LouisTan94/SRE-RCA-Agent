#!/usr/bin/env bash
# Break a running service, then ask the SRE agent for an RCA.
#
#   ./tier1/scripts/chaos.sh oom-product     # product-service exceeds 128Mi -> OOMKilled
#   ./tier1/scripts/chaos.sh crash-order     # order-service exits with code 1
#   ./tier1/scripts/chaos.sh crash-product   # product-service exits with code 1
#   ./tier1/scripts/chaos.sh db-error        # order-service logs a DB pool exhaustion
#   ./tier1/scripts/chaos.sh rca-only        # no fault, just run an RCA
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

post_inside() {
  kc -n apps exec "deploy/$1" -- python -c '
import sys, urllib.request
try:
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000" + sys.argv[1], method="POST"), timeout=15)
except Exception as e:
    print(f"  (request ended: {type(e).__name__} - expected when the process dies)")
' "$2" || true
}

case "${1:-}" in
  oom-product)   say "product-service: allocating past its memory limit"; post_inside product-service /chaos/oom ;;
  crash-order)   say "order-service: exit code 1";                         post_inside order-service /chaos/crash ;;
  crash-product) say "product-service: exit code 1";                       post_inside product-service /chaos/crash ;;
  db-error)      say "order-service: simulated DB pool exhaustion";        post_inside order-service /chaos/db-error ;;
  rca-only)      say "No fault injected" ;;
  *) sed -n '2,9p' "$0"; exit 1 ;;
esac

if [ "$1" != "rca-only" ]; then
  say "Waiting 20s for restarts, events and logs"
  sleep 20
  kc -n apps get pods
fi

say "Asking the SRE agent for an RCA (1-3 minutes with the LLM)"
run_rca "Investigate recent failures or restarting pods in the apps namespace and produce an incident RCA." "${2:-oncall@local.test}"
