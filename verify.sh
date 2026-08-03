#!/usr/bin/env bash
# Post-deploy security checks. Run from a machine on the tailnet.
#
# The first two matter most: tailscale serve proxies over loopback, and
# 9router grants local requests privileged access. These assert that the
# loopback hop did not leak those privileges.
#
# Usage: ./verify.sh 9router.<your-tailnet>.ts.net

set -uo pipefail

HOST="${1:-}"
[ -z "$HOST" ] && { echo "usage: $0 <tailnet-hostname>"; exit 2; }

fails=0

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok    $label ($got)"
  else
    echo "  FAIL  $label: expected $want, got $got"
    fails=$((fails + 1))
  fi
}

code() { curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$1" 2>/dev/null || echo "000"; }

echo "checking https://$HOST"

# Unauthenticated LLM API must be rejected. If this returns 200, 9router
# thinks the request is local and your provider tokens are usable by anyone
# who can reach the node.
check "/v1/models without API key" 401 "$(code "https://$HOST/v1/models")"

# Local-only route: spawns child processes / reads host secrets.
check "/api/mcp/ blocked" 403 "$(code "https://$HOST/api/mcp/")"

# Deny-by-default on /api/*.
check "/api/settings unauthenticated" 401 "$(code "https://$HOST/api/settings")"

# Dashboard should redirect to login rather than render.
check "/dashboard redirects" 307 "$(code "https://$HOST/dashboard")"

echo
echo "on the VPS, confirm nothing is published to the host:"
echo "  ss -tlnp | grep -E '20128|8787'   # expect no output"

[ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed"
exit "$fails"
