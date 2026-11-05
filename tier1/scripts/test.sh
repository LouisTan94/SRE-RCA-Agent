#!/usr/bin/env bash
# Run a service's unit tests in a shared virtualenv (tier1/.venv-ci).
#   ./tier1/scripts/test.sh product-service [more services...]
#   ./tier1/scripts/test.sh --all
set -euo pipefail
# shellcheck source=common.sh
. "$(dirname "$0")/common.sh"

[ $# -gt 0 ] || die "usage: $0 <service>... | --all"
if [ "$1" = "--all" ]; then set -- "${SERVICES[@]}"; fi

VENV="$TIER1_DIR/.venv-ci"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"

status=0
for svc in "$@"; do
  is_service "$svc" || die "unknown service '$svc' (choose from: ${SERVICES[*]})"
  dir="$REPO_ROOT/services/$svc"
  # Reinstall only when the service's requirements change.
  stamp="$VENV/.req-$svc"
  want="$(cat "$dir/requirements.txt")"
  if [ ! -f "$stamp" ] || [ "$(cat "$stamp")" != "$want" ]; then
    "$VENV/bin/pip" install -q --disable-pip-version-check -r "$dir/requirements.txt" pytest httpx
    printf '%s' "$want" > "$stamp"
  fi
  say "Testing $svc"
  # Each service imports its own modules (main.py, agent.py...), so run them separately.
  (cd "$dir" && "$VENV/bin/python" -m pytest -q tests) || status=1
done
exit $status
