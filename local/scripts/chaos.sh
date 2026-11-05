#!/usr/bin/env bash
# Break a service on purpose, then ask the SRE agent for an RCA (emailed to Mailpit).
#
#   ./local/scripts/chaos.sh oom-product     # product-service exceeds its memory limit -> OOMKilled
#   ./local/scripts/chaos.sh crash-order     # order-service exits with code 1 -> restart
#   ./local/scripts/chaos.sh crash-product   # product-service exits with code 1 -> restart
#   ./local/scripts/chaos.sh db-error        # order-service logs a DB pool exhaustion error
#   ./local/scripts/chaos.sh rca-only        # no fault, just run an RCA now
#
# Optional 2nd argument: recipient address (default oncall@local.test; any address ends up in Mailpit).
#
# Everything runs through `kubectl exec`, so no port-forward is needed for this script.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

SCENARIO="${1:-}"
EMAIL_TO="${2:-oncall@local.test}"

# POST to a URL from inside a pod. Python is in every image, so no curl needed.
post_inside() {
  local ns="$1" deploy="$2" path="$3"
  kc -n "$ns" exec "deploy/$deploy" -- python -c '
import sys, urllib.request
try:
    urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:8000" + sys.argv[1], method="POST"), timeout=15)
except Exception as e:
    print(f"  (request ended: {type(e).__name__} - expected when the process dies)")
' "$path" || true
}

case "$SCENARIO" in
  oom-product)
    say "Making product-service allocate memory past its 128Mi limit"
    post_inside apps product-service /chaos/oom ;;
  crash-order)
    say "Crashing order-service (exit code 1)"
    post_inside apps order-service /chaos/crash ;;
  crash-product)
    say "Crashing product-service (exit code 1)"
    post_inside apps product-service /chaos/crash ;;
  db-error)
    say "Triggering a simulated DB connection pool exhaustion in order-service"
    post_inside apps order-service /chaos/db-error ;;
  rca-only)
    say "No fault injected" ;;
  *)
    sed -n '2,12p' "$0"; exit 1 ;;
esac

if [ "$SCENARIO" != "rca-only" ]; then
  say "Waiting 20s for the restart, events and logs to settle"
  sleep 20
  kc -n apps get pods
fi

say "Asking the SRE agent for an RCA (can take 1-3 minutes with the LLM)"
kc -n ai-agent exec deploy/sre-agent -- python -c '
import json, os, sys, urllib.request
body = json.dumps({
    "question": "Investigate recent failures or restarting pods in the apps namespace and produce an incident RCA.",
    "email_to": [sys.argv[1]],
}).encode()
req = urllib.request.Request(
    "http://127.0.0.1:8000/rca", data=body, method="POST",
    headers={"Content-Type": "application/json", "x-api-key": os.environ.get("AGENT_API_KEY", "")},
)
res = json.load(urllib.request.urlopen(req, timeout=600))
r = res["rca"]
print()
print("Title:       ", r.get("title"))
print("Severity:    ", r.get("severity"), "| Confidence:", r.get("confidence"))
print("Services:    ", ", ".join(r.get("affected_services", [])))
print("Root cause:  ", r.get("root_cause"))
print("Resolution:")
for step in r.get("resolution", []):
    print("   -", step)
print("Email:       ", (res.get("email_status") or {}).get("status"), "->", sys.argv[1])
' "$EMAIL_TO"

cat <<EOF

Full report:  http://localhost:${AGENT_PORT:-8080}/rca/latest   (needs ./local/scripts/forward.sh)
Email inbox:  http://localhost:${MAILPIT_PORT:-8025}
EOF
