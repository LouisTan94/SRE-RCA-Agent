#!/usr/bin/env bash
# Local CI/CD for one or more services:
#   test -> build image into minikube -> bump the tag in tier1/gitops -> push to Gitea
#   -> ArgoCD deploys -> verify.sh (RCA + automatic rollback if it fails)
#
#   ./tier1/scripts/ci.sh product-service
#   ./tier1/scripts/ci.sh --all
#   ./tier1/scripts/ci.sh order-service --no-verify
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

verify=true
targets=()
for arg in "$@"; do
  case "$arg" in
    --no-verify) verify=false ;;
    --all) targets+=("${SERVICES[@]}") ;;
    -*) die "unknown option $arg" ;;
    *) is_service "$arg" || die "unknown service '$arg'"; targets+=("$arg") ;;
  esac
done
[ ${#targets[@]} -gt 0 ] || die "usage: $0 <service>... | --all [--no-verify]"

ensure_gitea
ensure_gitea_remote
sync_main

say "Running tests"
"$TIER1_DIR/scripts/test.sh" "${targets[@]}" || die "Tests failed. Nothing was built or deployed."

tag="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
changed=()
for svc in "${targets[@]}"; do
  kfile="$TIER1_DIR/gitops/$svc/kustomization.yaml"
  if grep -qE "^ *newTag: *$tag *$" "$kfile"; then
    ok "$svc is already at $tag, skipping"
    continue
  fi
  say "Building local/$svc:$tag into minikube"
  minikube -p "$CLUSTER" image build -t "local/$svc:$tag" "$REPO_ROOT/services/$svc" >/dev/null
  # Portable in-place edit (GNU and BSD sed).
  sed -i.bak -E "s/^( *newTag: *).*/\1$tag/" "$kfile" && rm -f "$kfile.bak"
  changed+=("$svc")
done

if [ ${#changed[@]} -eq 0 ]; then
  ok "Nothing to deploy."
  exit 0
fi

say "Committing the new image tags and pushing to Gitea"
for svc in "${changed[@]}"; do git -C "$REPO_ROOT" add "tier1/gitops/$svc/kustomization.yaml"; done
git -C "$REPO_ROOT" commit -q -m "deploy(${changed[*]}): $tag"
git_gitea push -q gitea main
ok "pushed $(git -C "$REPO_ROOT" rev-parse --short HEAD) - ArgoCD will roll it out"

if $verify; then
  "$TIER1_DIR/scripts/verify.sh" "${changed[@]}"
fi
