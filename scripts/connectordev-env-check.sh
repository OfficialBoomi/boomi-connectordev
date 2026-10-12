#!/usr/bin/env bash
# Verify .env vars and reach the Connectors API with one cheap authenticated query.

source "$(dirname "$0")/connectordev-common.sh"

usage() {
  cat <<'EOF'
Usage: connectordev-env-check.sh [--help]

Checks the BOOMI_* variables in .env, then queries connector groups (read-only).
Success also lists the account's existing groupTypes. Fails with exit 1 if any
variable is missing or the API call does not return 2xx.
EOF
}
[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && { usage; exit 0; }

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

echo "=== Connectors API ==="
env_status BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL

url="$(connectordev_url "ConnectorGroupQuery/query")"
echo "  POST $url"
# Tolerate connection failure so the FAIL line reports it.
connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
  --data-binary "{}" "$url" || true

if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
  echo "  HTTP $RESPONSE_CODE — FAIL" >&2
  echo "  Response: $RESPONSE_BODY" >&2
  if (( RESPONSE_CODE == 403 )); then
    echo "  Check: credentials, BOOMI_ACCOUNT_ID, and that BOOMI_API_URL matches your console region." >&2
  elif (( RESPONSE_CODE == 400 )); then
    echo "  Check: the account has a signed SDK Publisher Agreement and your user has the" >&2
    echo "  DEVELOPER privilege (Connectors API access requirements)." >&2
  fi
  exit 1
fi
echo "  HTTP $RESPONSE_CODE — OK"
groups=$(printf '%s' "$RESPONSE_BODY" | grep -o '"groupType"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*:[[:space:]]*"\(.*\)"/\1/') || true
if [[ -n "$groups" ]]; then
  echo "  Existing connector groups (groupType) — includes soft-deleted groups:"
  echo "$groups" | sed 's/^/    /'
else
  echo "  No connector groups exist on this account yet."
fi
