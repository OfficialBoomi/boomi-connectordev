#!/usr/bin/env bash
# Connector group and classification operations (Connectors API).

source "$(dirname "$0")/connectordev-common.sh"

usage() {
  cat <<'EOF'
Usage: connectordev-group.sh <subcommand> [args]

Subcommands:
  create <json-file>                          POST /ConnectorGroup (groupName, CreateConnectorClassification, optional ConnectorVendor)
  get <groupType>                             group with its classifications and versions
  delete <groupType>                          classifications must be deleted first
  query [<json-file>]                         returns up to 20 per page; default body {} returns all
  query-more <queryToken>                     next page for a prior query
  classification-add <json-file>              POST /ConnectorClassification (classification, displayName, groupType, optional version)
  classification-delete <classificationType>  only if unused

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
  create)
    [[ -z "${1:-}" ]] && { echo "Need <json-file>" >&2; exit 1; }
    require_local_file "$1" "json-file"
    connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      --data-binary "@$1" "$(connectordev_url "ConnectorGroup")"
    ;;
  get)
    [[ -z "${1:-}" ]] && { echo "Need <groupType>" >&2; exit 1; }
    require_path_segment "$1" groupType
    connectordev_api -H "Accept: application/json" "$(connectordev_url "ConnectorGroup/$1")"
    ;;
  delete)
    [[ -z "${1:-}" ]] && { echo "Need <groupType>" >&2; exit 1; }
    require_path_segment "$1" groupType
    connectordev_api -X DELETE -H "Accept: application/json" "$(connectordev_url "ConnectorGroup/$1")"
    ;;
  query)
    body="{}"
    if [[ -n "${1:-}" ]]; then
      require_local_file "$1" "json-file"
      body="@$1"
    fi
    connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      --data-binary "$body" "$(connectordev_url "ConnectorGroupQuery/query")"
    ;;
  query-more)
    [[ -z "${1:-}" ]] && { echo "Need <queryToken>" >&2; exit 1; }
    # --data-raw is required here; do not normalise to --data-binary.
    connectordev_api -X POST -H "Content-Type: text/plain" -H "Accept: application/json" \
      --data-raw "$1" "$(connectordev_url "ConnectorGroupQuery/queryMore")"
    ;;
  classification-add)
    [[ -z "${1:-}" ]] && { echo "Need <json-file>" >&2; exit 1; }
    require_local_file "$1" "json-file"
    connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      --data-binary "@$1" "$(connectordev_url "ConnectorClassification")"
    ;;
  classification-delete)
    [[ -z "${1:-}" ]] && { echo "Need <classificationType>" >&2; exit 1; }
    require_path_segment "$1" classificationType
    connectordev_api -X DELETE -H "Accept: application/json" "$(connectordev_url "ConnectorClassification/$1")"
    ;;
  *) usage >&2; exit 1;;
esac

require_success
echo "$RESPONSE_BODY"
