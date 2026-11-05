#!/usr/bin/env bash
# Remove the deployment. Add --all to delete the whole minikube profile (cluster + images).
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

if [ "${1:-}" = "--all" ]; then
  say "Deleting minikube profile '$PROFILE'"
  minikube delete -p "$PROFILE"
  exit 0
fi

say "Removing namespaces apps and ai-agent, and the agent's cluster role"
kc delete namespace apps ai-agent --ignore-not-found
kc delete clusterrolebinding sre-agent-readonly --ignore-not-found
kc delete clusterrole sre-agent-readonly --ignore-not-found
echo "Cluster is still running. Use '$0 --all' to delete it, or 'minikube stop -p $PROFILE' to pause it."
