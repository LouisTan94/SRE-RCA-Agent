#!/usr/bin/env bash
# Destroy the Tier 1 environment (cluster, ArgoCD, Gitea and everything in it).
# To pause instead and keep everything: minikube stop -p sre-tier1
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

say "Destroying Tier 1 (cluster '$CLUSTER'). The Gitea repo inside it is deleted too;"
echo "    your local git clone (including the commits the agents made) is kept."
terraform -chdir="$TF_DIR" destroy -auto-approve
git -C "$REPO_ROOT" remote remove gitea 2>/dev/null || true
ok "Done."
