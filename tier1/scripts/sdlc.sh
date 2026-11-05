#!/usr/bin/env bash
# The agentic SDLC loop.
#
#   ./tier1/scripts/sdlc.sh task "Describe the change you want"
#       Claude (orchestrator + coder / tester / reviewer subagents) implements it on a
#       new branch and opens a pull request in Gitea. Nothing is deployed.
#
#   ./tier1/scripts/sdlc.sh prs
#       List open pull requests.
#
#   ./tier1/scripts/sdlc.sh ship <PR number>
#       Your approval: merge the PR, then CI builds, ArgoCD deploys, verify.sh checks
#       health. On failure the SRE agent writes an RCA and the deploy is rolled back.
#
#   ./tier1/scripts/sdlc.sh status
#       ArgoCD application status.
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

AGENT_VENV="$TIER1_DIR/.venv-agent"

agent_python() {
  if [ ! -x "$AGENT_VENV/bin/python" ]; then
    say "Setting up the agent virtualenv (one time)"
    python3 -m venv "$AGENT_VENV"
    "$AGENT_VENV/bin/pip" install -q --disable-pip-version-check -r "$TIER1_DIR/agents/requirements.txt"
  fi
  "$AGENT_VENV/bin/python" "$@"
}

case "${1:-}" in
  task)
    shift
    [ $# -gt 0 ] || die 'usage: sdlc.sh task "what to change"'
    [ -n "${ANTHROPIC_API_KEY:-}" ] || die "Set ANTHROPIC_API_KEY in tier1/.env first."
    ensure_gitea
    ensure_gitea_remote
    sync_main
    agent_python "$TIER1_DIR/agents/sdlc_agent.py" "$*"
    ;;

  prs)
    ensure_gitea
    gitea_api list-prs
    ;;

  ship)
    pr="${2:-}"
    [ -n "$pr" ] || die "usage: sdlc.sh ship <PR number>"
    ensure_gitea
    ensure_gitea_remote
    sync_main
    before="$(git -C "$REPO_ROOT" rev-parse HEAD)"

    say "Merging PR #$pr"
    gitea_api merge-pr "$pr"
    git_gitea fetch -q gitea main
    git -C "$REPO_ROOT" merge -q --ff-only gitea/main

    # Which services did this PR touch?
    changed=()
    for svc in "${SERVICES[@]}"; do
      if ! git -C "$REPO_ROOT" diff --quiet "$before" HEAD -- "services/$svc"; then changed+=("$svc"); fi
    done

    if [ ${#changed[@]} -gt 0 ]; then
      say "Services changed: ${changed[*]}"
      "$TIER1_DIR/scripts/ci.sh" "${changed[@]}"
    elif ! git -C "$REPO_ROOT" diff --quiet "$before" HEAD -- tier1/gitops; then
      say "Only deployment manifests changed - ArgoCD applies them directly"
      apps=()
      for app in product-service order-service mailpit sre-agent; do
        git -C "$REPO_ROOT" diff --quiet "$before" HEAD -- "tier1/gitops/$app" || apps+=("$app")
      done
      if [ ${#apps[@]} -gt 0 ]; then
        "$TIER1_DIR/scripts/verify.sh" --no-rollback "${apps[@]}"
      else
        ok "ArgoCD Application definitions changed; check them with: ./tier1/scripts/sdlc.sh status"
      fi
    else
      ok "No services or manifests changed - nothing to deploy."
    fi
    ;;

  status)
    kc -n argocd get applications
    ;;

  *)
    sed -n '2,19p' "$0"
    exit 1
    ;;
esac
