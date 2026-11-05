#!/usr/bin/env bash
# Deploy gate. For each service: wait until ArgoCD has synced the current commit and
# reports Healthy, then watch for crashes for a while. If anything fails:
#   1. the SRE agent writes an RCA (emailed to Mailpit)
#   2. the deploy commit is reverted in Git, so ArgoCD rolls back (skip with --no-rollback)
#
#   ./tier1/scripts/verify.sh product-service [--no-rollback]
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

rollback=true
targets=()
for arg in "$@"; do
  case "$arg" in
    --no-rollback) rollback=false ;;
    *) targets+=("$arg") ;;
  esac
done
[ ${#targets[@]} -gt 0 ] || die "usage: $0 <service>... [--no-rollback]"

SYNC_TIMEOUT="${VERIFY_SYNC_TIMEOUT:-300}"
SOAK_SECONDS="${VERIFY_SOAK_SECONDS:-45}"
rev="$(git -C "$REPO_ROOT" rev-parse HEAD)"

ns_of() { case "$1" in sre-agent|mailpit) echo ai-agent ;; *) echo apps ;; esac; }
restarts() { kc -n "$(ns_of "$1")" get pods -l "app=$1" -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.restartCount}{"\n"}{end}{end}' | awk '{s+=$1} END {print s+0}'; }

check() {
  local svc="$1" ns state deadline before after bad
  ns="$(ns_of "$svc")"

  echo "  waiting for ArgoCD to sync $svc at ${rev:0:7}..."
  kc -n argocd annotate application "$svc" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  deadline=$(( $(date +%s) + SYNC_TIMEOUT ))
  while true; do
    state="$(kc -n argocd get application "$svc" -o jsonpath='{.status.sync.revision} {.status.sync.status} {.status.health.status}')"
    case "$state" in
      "$rev Synced Healthy") break ;;
      "$rev Synced Degraded"*) FAIL_REASON="ArgoCD reports $svc Degraded after syncing ${rev:0:7}"; return 1 ;;
      "$rev Synced"*)
        # Fail fast instead of waiting for the full timeout when a new pod is clearly broken.
        bad="$(kc -n "$ns" get pods -l "app=$svc" -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.waiting.reason}{"\n"}{end}{end}' \
               | grep -E 'CrashLoopBackOff|ErrImageNeverPull|ImagePullBackOff|CreateContainerConfigError|CreateContainerError' | head -1 || true)"
        if [ -n "$bad" ]; then FAIL_REASON="$svc pod is in $bad after deploying ${rev:0:7}"; return 1; fi
        ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      FAIL_REASON="$svc did not become Synced+Healthy at ${rev:0:7} within ${SYNC_TIMEOUT}s (last state: $state)"
      return 1
    fi
    sleep 5
  done

  if ! kc -n "$ns" rollout status "deploy/$svc" --timeout=120s >/dev/null; then
    FAIL_REASON="rollout of $svc did not complete"; return 1
  fi

  echo "  synced and healthy; watching $svc for ${SOAK_SECONDS}s..."
  before="$(restarts "$svc")"
  sleep "$SOAK_SECONDS"
  after="$(restarts "$svc")"
  if [ "$after" -gt "$before" ]; then
    FAIL_REASON="$svc restarted $((after - before)) time(s) within ${SOAK_SECONDS}s of deploying ${rev:0:7}"
    return 1
  fi

  if [ "$svc" != "mailpit" ] && ! kc -n "$ns" exec "deploy/$svc" -- python -c \
       'import urllib.request; urllib.request.urlopen("http://127.0.0.1:8000/healthz", timeout=5)' >/dev/null 2>&1; then
    FAIL_REASON="$svc /healthz smoke test failed"; return 1
  fi
  return 0
}

say "Verifying deployment of ${targets[*]} at ${rev:0:7}"
failed=()
reasons=()
for svc in "${targets[@]}"; do
  FAIL_REASON=""
  if check "$svc"; then
    ok "$svc is healthy"
  else
    warn "$FAIL_REASON"
    failed+=("$svc")
    reasons+=("$FAIL_REASON")
  fi
done

[ ${#failed[@]} -eq 0 ] && { ok "Deployment verified."; exit 0; }

say "Deployment failed - asking the SRE agent for an RCA"
kc -n "$(ns_of "${failed[0]}")" get pods -l "app=${failed[0]}" || true
question="A GitOps deployment at commit ${rev:0:7} failed verification: ${reasons[*]}. \
Check ArgoCD's recent deploys, the failing pods' status, events and previous logs, and explain the root cause."
run_rca "$question" || warn "Could not get an RCA (is the sre-agent itself the failing service?)."

if $rollback && ! git -C "$REPO_ROOT" log -1 --format=%s | grep -q '^deploy('; then
  warn "HEAD isn't a deploy commit made by ci.sh, so it won't be reverted automatically."
  rollback=false
fi

if $rollback; then
  say "Rolling back: reverting ${rev:0:7} in Git"
  ensure_gitea
  git -C "$REPO_ROOT" revert --no-edit HEAD >/dev/null
  git_gitea push -q gitea main
  ok "pushed revert $(git -C "$REPO_ROOT" rev-parse --short HEAD); waiting for ArgoCD to restore the previous version"
  rev="$(git -C "$REPO_ROOT" rev-parse HEAD)"
  for svc in "${failed[@]}"; do
    FAIL_REASON=""
    if check "$svc"; then ok "$svc restored"; else warn "Rollback of $svc needs attention: $FAIL_REASON"; fi
  done
fi
exit 1
