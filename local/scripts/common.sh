# Shared settings for the local scripts. Sourced, not executed.
# shellcheck shell=bash

LOCAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$LOCAL_DIR/.." && pwd)"
export LOCAL_DIR REPO_ROOT

# Optional overrides live in local/.env (copy from .env.example).
if [ -f "$LOCAL_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$LOCAL_DIR/.env"
  set +a
fi

PROFILE="${MINIKUBE_PROFILE:-sre-lab}"

# Always talk to the minikube profile's context, never whatever kubectl points at.
kc() { kubectl --context "$PROFILE" "$@"; }

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[warn] %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31m[error] %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is not installed. $2"; }
