#!/usr/bin/env bash
# Start minikube on Docker, build the three images inside it, and deploy everything.
# Safe to re-run: it rebuilds the images and restarts the pods so code changes show up.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

say "Checking prerequisites"
need docker   "Install Docker Desktop (macOS/Windows) or Docker Engine (Linux)."
need minikube "See https://minikube.sigs.k8s.io/docs/start/"
need kubectl  "See https://kubernetes.io/docs/tasks/tools/"
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start Docker and try again."

if minikube -p "$PROFILE" status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
  say "minikube profile '$PROFILE' is already running"
else
  say "Starting minikube profile '$PROFILE' (driver=docker)"
  minikube start -p "$PROFILE" --driver=docker \
    --cpus="${MINIKUBE_CPUS:-2}" --memory="${MINIKUBE_MEMORY:-4096}"
fi

say "Enabling metrics-server (lets the agent see CPU/memory usage)"
minikube -p "$PROFILE" addons enable metrics-server >/dev/null

say "Building images inside minikube (no registry needed)"
for svc in product-service order-service sre-agent; do
  echo "  - local/$svc:dev"
  minikube -p "$PROFILE" image build -t "local/$svc:dev" "$REPO_ROOT/services/$svc" >/dev/null
done

say "Creating namespaces"
kc apply -f "$LOCAL_DIR/k8s/00-namespaces.yaml" >/dev/null

say "Creating agent-secrets"
existing_key="$(kc -n ai-agent get secret agent-secrets -o jsonpath='{.data.agent_api_key}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
AGENT_API_KEY="${AGENT_API_KEY:-$existing_key}"
if [ -z "$AGENT_API_KEY" ]; then
  AGENT_API_KEY="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  echo "  generated a new AGENT_API_KEY"
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  warn "ANTHROPIC_API_KEY is not set in local/.env - the agent will run in rule-based mode (no LLM)."
fi
kc -n ai-agent create secret generic agent-secrets \
  --from-literal=agent_api_key="$AGENT_API_KEY" \
  --from-literal=anthropic_api_key="${ANTHROPIC_API_KEY:-}" \
  --from-literal=agent_model="${AGENT_MODEL:-claude-sonnet-5-5}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

say "Deploying services, Mailpit and the SRE agent"
already_deployed=false
kc -n ai-agent get deploy sre-agent >/dev/null 2>&1 && already_deployed=true
kc apply -f "$LOCAL_DIR/k8s/" >/dev/null

if $already_deployed; then
  # Same image tag, so restart to pick up freshly built images and secret changes.
  kc -n apps rollout restart deploy/product-service deploy/order-service >/dev/null
  kc -n ai-agent rollout restart deploy/sre-agent >/dev/null
fi

say "Waiting for pods to become ready"
kc -n apps rollout status deploy/product-service --timeout=180s
kc -n apps rollout status deploy/order-service --timeout=180s
kc -n ai-agent rollout status deploy/mailpit --timeout=180s
kc -n ai-agent rollout status deploy/sre-agent --timeout=180s

cat <<EOF

All up. Next steps:
  1. In a second terminal:   ./local/scripts/forward.sh
       Agent API      http://localhost:${AGENT_PORT:-8080}/docs
       Latest report  http://localhost:${AGENT_PORT:-8080}/rca/latest
       Email inbox    http://localhost:${MAILPIT_PORT:-8025}
  2. Break something and get an RCA:
       ./local/scripts/chaos.sh oom-product
EOF
