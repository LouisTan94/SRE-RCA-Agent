#!/usr/bin/env bash
# Open every UI on localhost. Leave it running; Ctrl+C stops all forwards.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

ARGOCD_PORT="${ARGOCD_PORT:-8090}"
AGENT_PORT="${AGENT_PORT:-8080}"
MAILPIT_PORT="${MAILPIT_PORT:-8025}"

pids=()
cleanup() { kill "${pids[@]}" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# Reconnect automatically when a pod is replaced (deploys, crash tests).
forward() {
  while true; do
    kc -n "$1" port-forward "$2" "$3" >/dev/null 2>&1 || true
    sleep 2
  done
}

forward argocd   svc/argocd-server "$ARGOCD_PORT:80"   & pids+=($!)
forward gitea    svc/gitea-http    "$GITEA_PORT:3000"  & pids+=($!)
forward ai-agent svc/sre-agent     "$AGENT_PORT:80"    & pids+=($!)
forward ai-agent svc/mailpit       "$MAILPIT_PORT:8025" & pids+=($!)

argo_pass="$(kc -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode 2>/dev/null || echo '?')"
gitea_user="$(tf_out gitea_admin_user || echo sdlc)"
gitea_pass="$(tf_out gitea_admin_password || echo '?')"

cat <<EOF
Forwarding (Ctrl+C to stop):

  ArgoCD       http://localhost:$ARGOCD_PORT      admin / $argo_pass
  Gitea        $GITEA_URL      $gitea_user / $gitea_pass
  SRE agent    http://localhost:$AGENT_PORT/docs   (latest report: /rca/latest)
  Mailpit      http://localhost:$MAILPIT_PORT      (RCA emails)
EOF
wait
