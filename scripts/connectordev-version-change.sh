#!/usr/bin/env bash
# Set or cancel the active connector version for a classification (Connectors API).

source "$(dirname "$0")/connectordev-common.sh"

usage() {
  cat <<'EOF'
Usage: connectordev-version-change.sh <subcommand> [args]

Subcommands:
  set <classificationType> <versionId> [--notes <text>]   applies directly for PRIVATE visibility; PUBLIC starts an approval request
  cancel <classificationType>                              cancel a pending version change

Reads BOOMI_* from .env.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

sub="$1"; shift

load_env
require_env BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL
require_tools curl

case "$sub" in
  set)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <classificationType> <versionId>" >&2; exit 1; }
    ct="$1"; vid="$2"; shift 2
    notes=""
    [[ "${1:-}" == "--notes" ]] && { [[ -z "${2:-}" ]] && { echo "--notes needs a value" >&2; exit 1; }; notes="$2"; shift 2; }
    reject_flags "$@"
    ct=$(json_escape "$ct" classificationType) || exit 1
    vid=$(json_escape "$vid" versionId) || exit 1
    body="{\"classificationType\":\"${ct}\",\"versionId\":\"${vid}\""
    if [[ -n "$notes" ]]; then
      notes=$(json_escape "$notes" '--notes') || exit 1
      body+=",\"releaseNotes\":\"${notes}\""
    fi
    body+="}"
    connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      --data-binary "$body" "$(connectordev_url "ConnectorVersionChange")"
    ;;
  cancel)
    [[ -z "${1:-}" ]] && { echo "Need <classificationType>" >&2; exit 1; }
    ct=$(json_escape "$1" classificationType) || exit 1
    body="{\"classificationType\":\"${ct}\"}"
    connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      --data-binary "$body" "$(connectordev_url "ConnectorVersionChange/delete")"
    ;;
  *) usage >&2; exit 1;;
esac

require_success
echo "$RESPONSE_BODY"
