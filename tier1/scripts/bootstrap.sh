#!/usr/bin/env bash
# One-time setup (safe to re-run):
#   Terraform -> minikube + ArgoCD + Gitea -> push this repo to Gitea -> build images
#   -> ArgoCD deploys everything from Git.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

say "Checking prerequisites"
need docker    "Install Docker Desktop (macOS/Windows) or Docker Engine (Linux)."
need minikube  "See https://minikube.sigs.k8s.io/docs/start/"
need kubectl   "See https://kubernetes.io/docs/tasks/tools/"
need terraform "See https://developer.hashicorp.com/terraform/install"
need git       ""
need python3   ""
need curl      ""
docker info >/dev/null 2>&1 || die "Docker isn't running. Start it and try again."
[ "$(git -C "$REPO_ROOT" branch --show-current)" = "main" ] || die "Run this from the main branch (git checkout main)."
[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || die "Commit or stash your changes first: bootstrap pushes main to Gitea."
[ -n "${ANTHROPIC_API_KEY:-}" ] || warn "ANTHROPIC_API_KEY isn't set in tier1/.env: the SRE agent runs rule-based and the SDLC agent won't work."

say "Terraform: minikube cluster, ArgoCD, Gitea (first run takes 5-10 minutes)"
terraform -chdir="$TF_DIR" init -input=false -upgrade >/dev/null
terraform -chdir="$TF_DIR" apply -input=false -auto-approve
CLUSTER="$(tf_out cluster_name)"
load_gitea_creds

say "Creating the Gitea admin user '$GITEA_USER'"
kc -n gitea rollout status deploy/gitea --timeout=300s >/dev/null
if kc -n gitea exec deploy/gitea -- gitea admin user list \
     2>/dev/null | awk '{print $2}' | grep -qx "$GITEA_USER"; then
  ok "user exists"
else
  kc -n gitea exec deploy/gitea -- gitea admin user create --admin \
    --username "$GITEA_USER" --password "$GITEA_PASS" \
    --email "$GITEA_USER@local.test" --must-change-password=false >/dev/null
  ok "user created"
fi

say "Creating the '$GITEA_REPO' repo and pushing main"
ensure_gitea
gitea_api ensure-repo
ensure_gitea_remote
git_gitea push -q gitea main
git_gitea fetch -q gitea main
git -C "$REPO_ROOT" branch -q --set-upstream-to=gitea/main main
ok "pushed $(git -C "$REPO_ROOT" rev-parse --short HEAD)"

say "Building service images into minikube"
for svc in "${SERVICES[@]}"; do
  tag="$(sed -nE 's/^ *newTag: *//p' "$TIER1_DIR/gitops/$svc/kustomization.yaml")"
  echo "  - local/$svc:$tag"
  minikube -p "$CLUSTER" image build -t "local/$svc:$tag" "$REPO_ROOT/services/$svc" >/dev/null
done

say "Creating agent-secrets (kept out of Git)"
kc create namespace ai-agent --dry-run=client -o yaml | kc apply -f - >/dev/null
existing="$(kc -n ai-agent get secret agent-secrets -o jsonpath='{.data.agent_api_key}' 2>/dev/null | base64 --decode 2>/dev/null || true)"
agent_key="${AGENT_API_KEY:-$existing}"
[ -n "$agent_key" ] || agent_key="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
kc -n ai-agent create secret generic agent-secrets \
  --from-literal=agent_api_key="$agent_key" \
  --from-literal=anthropic_api_key="${ANTHROPIC_API_KEY:-}" \
  --from-literal=agent_model="${AGENT_MODEL:-claude-sonnet-5-5}" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null
kc -n ai-agent rollout restart deploy/sre-agent >/dev/null 2>&1 || true  # pick up secret changes on re-runs

say "Waiting for ArgoCD to deploy everything from Git"
kc -n argocd annotate application root argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
deadline=$(( $(date +%s) + 420 ))
for app in product-service order-service mailpit sre-agent; do
  while true; do
    state="$(kc -n argocd get application "$app" -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || true)"
    [ "$state" = "Synced/Healthy" ] && { ok "$app $state"; break; }
    [ "$(date +%s)" -lt "$deadline" ] || die "$app didn't become healthy (state: ${state:-not created yet}). Check: kubectl --context $CLUSTER -n argocd get applications"
    sleep 5
  done
done

cat <<EOF

Tier 1 is up.

  1. Open the UIs (leave running in a second terminal):
       ./tier1/scripts/forward.sh

  2. Ship a change through the agentic SDLC:
       ./tier1/scripts/sdlc.sh task "Add a GET /products/{id}/stock endpoint to product-service"
       # review the PR in Gitea, then:
       ./tier1/scripts/sdlc.sh ship <PR number>

  3. Break something and get an RCA:
       ./tier1/scripts/chaos.sh oom-product
EOF
