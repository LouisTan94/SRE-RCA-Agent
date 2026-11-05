#!/usr/bin/env bash
# Expose the agent, Mailpit and the two demo services on localhost. Ctrl+C stops all of them.
# (Port-forwarding works the same on macOS, Windows and Linux, unlike NodePorts with the docker driver.)
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

AGENT_PORT="${AGENT_PORT:-8080}"
MAILPIT_PORT="${MAILPIT_PORT:-8025}"
ORDER_PORT="${ORDER_PORT:-8081}"
PRODUCT_PORT="${PRODUCT_PORT:-8082}"

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Restart a forward if its pod is replaced (e.g. after a crash test).
forward() {
  local ns="$1" target="$2" ports="$3"
  while true; do
    kc -n "$ns" port-forward "$target" "$ports" >/dev/null 2>&1 || true
    sleep 2
  done
}

forward ai-agent svc/sre-agent       "$AGENT_PORT:80"          & pids+=($!)
forward ai-agent svc/mailpit         "$MAILPIT_PORT:8025"      & pids+=($!)
forward apps     svc/order-service   "$ORDER_PORT:8000"        & pids+=($!)
forward apps     svc/product-service "$PRODUCT_PORT:8000"      & pids+=($!)

cat <<EOF
Forwarding (Ctrl+C to stop):
  SRE agent API    http://localhost:$AGENT_PORT/docs
  Latest RCA       http://localhost:$AGENT_PORT/rca/latest
  Email inbox      http://localhost:$MAILPIT_PORT
  order-service    http://localhost:$ORDER_PORT/orders
  product-service  http://localhost:$PRODUCT_PORT/products
EOF
wait
