# Shared helpers for the Tier 1 scripts. Sourced, not executed.
# shellcheck shell=bash

TIER1_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$TIER1_DIR/.." && pwd)"
TF_DIR="$TIER1_DIR/terraform"
export TIER1_DIR REPO_ROOT TF_DIR

# Settings and secrets (ANTHROPIC_API_KEY etc.) live in tier1/.env.
if [ -f "$TIER1_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$TIER1_DIR/.env"
  set +a
fi

GITEA_PORT="${GITEA_PORT:-3000}"
GITEA_URL="http://localhost:$GITEA_PORT"
export GITEA_URL

SERVICES=(product-service order-service sre-agent)

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[ok] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed. $2"; }

tf_out() { terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null; }

# Cluster name comes from Terraform once it has run.
CLUSTER=""
if [ -f "$TF_DIR/terraform.tfstate" ]; then CLUSTER="$(tf_out cluster_name || true)"; fi
CLUSTER="${CLUSTER:-sre-tier1}"
export CLUSTER

# Always target this cluster's kubectl context.
kc() { kubectl --context "$CLUSTER" "$@"; }

is_service() {
  local s
  for s in "${SERVICES[@]}"; do [ "$s" = "$1" ] && return 0; done
  return 1
}

# ---------- Gitea access ----------------------------------------------------

load_gitea_creds() {
  [ -n "${GITEA_PASS:-}" ] && return 0
  GITEA_USER="$(tf_out gitea_admin_user)" || die "No Terraform state. Run tier1/scripts/bootstrap.sh first."
  GITEA_PASS="$(tf_out gitea_admin_password)"
  GITEA_REPO="$(tf_out gitea_repo)"
  export GITEA_USER GITEA_PASS GITEA_REPO
}

_FORWARD_PIDS=()
_cleanup_forwards() { [ ${#_FORWARD_PIDS[@]} -eq 0 ] || kill "${_FORWARD_PIDS[@]}" 2>/dev/null || true; }
trap _cleanup_forwards EXIT

# Make Gitea reachable on localhost for git push and API calls.
# Reuses forward.sh if it's already running, otherwise starts a temporary forward.
ensure_gitea() {
  load_gitea_creds
  if curl -fsS -m 3 "$GITEA_URL/api/healthz" >/dev/null 2>&1; then return 0; fi
  kc -n gitea port-forward svc/gitea-http "$GITEA_PORT:3000" >/dev/null 2>&1 &
  _FORWARD_PIDS+=($!)
  local _
  for _ in $(seq 1 30); do
    curl -fsS -m 2 "$GITEA_URL/api/healthz" >/dev/null 2>&1 && return 0
    sleep 1
  done
  die "Gitea isn't reachable on $GITEA_URL (is port $GITEA_PORT free?)."
}

# git with Gitea credentials passed per command, so no password is stored in .git/config.
git_gitea() {
  local auth
  auth="$(printf '%s:%s' "$GITEA_USER" "$GITEA_PASS" | base64 | tr -d '\n')"
  git -C "$REPO_ROOT" -c "http.extraHeader=Authorization: Basic $auth" "$@"
}

ensure_gitea_remote() {
  local url="$GITEA_URL/$GITEA_REPO.git"
  if git -C "$REPO_ROOT" remote get-url gitea >/dev/null 2>&1; then
    git -C "$REPO_ROOT" remote set-url gitea "$url"
  else
    git -C "$REPO_ROOT" remote add gitea "$url"
  fi
}

gitea_api() { python3 "$TIER1_DIR/scripts/gitea_api.py" "$@"; }

# Bring local main up to date with Gitea's main (fast-forward only).
sync_main() {
  [ "$(git -C "$REPO_ROOT" branch --show-current)" = "main" ] || die "Switch to the main branch first (git checkout main)."
  [ -z "$(git -C "$REPO_ROOT" status --porcelain)" ] || die "You have uncommitted changes. Commit or stash them first."
  git_gitea fetch -q gitea main
  git -C "$REPO_ROOT" merge -q --ff-only gitea/main || die "Local main has diverged from Gitea's main. Resolve it manually."
}

# ---------- SRE agent -------------------------------------------------------

# Ask the in-cluster SRE agent for an RCA. Runs through kubectl exec, so no port-forward needed.
run_rca() {
  local question="$1" email="${2:-oncall@local.test}"
  kc -n ai-agent exec deploy/sre-agent -- python -c '
import json, os, sys, urllib.request
body = json.dumps({"question": sys.argv[1], "email_to": [sys.argv[2]]}).encode()
req = urllib.request.Request("http://127.0.0.1:8000/rca", data=body, method="POST",
    headers={"Content-Type": "application/json", "x-api-key": os.environ.get("AGENT_API_KEY", "")})
res = json.load(urllib.request.urlopen(req, timeout=600))
r = res["rca"]
print("Title:      ", r.get("title"))
print("Severity:   ", r.get("severity"), "| Confidence:", r.get("confidence"))
print("Root cause: ", r.get("root_cause"))
print("Resolution:")
for step in r.get("resolution", []):
    print("   -", step)
print("Emailed to: ", sys.argv[2], "(open the Mailpit inbox)")
' "$question" "$email"
}
