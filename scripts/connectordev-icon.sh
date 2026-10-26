#!/usr/bin/env bash
# Connector icon upload and retrieval (Connectors API).

source "$(dirname "$0")/connectordev-common.sh"

usage() {
  cat <<'EOF'
Usage: connectordev-icon.sh <subcommand> [args]

Subcommands:
  upload <classificationType> <svg-file>   set the canvas icon, replacing any existing one; prints the API response
  get <classificationType>                 print the SVG to stdout; errors when no icon is set

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
  upload)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <classificationType> <svg-file>" >&2; exit 1; }
    require_path_segment "$1" classificationType
    require_local_file "$2" "svg-file"
    connectordev_api -X POST -H "Accept: application/json" \
      -F "connectorIcon=@$2;type=image/svg+xml" \
      "$(connectordev_url "ConnectorIcon/$1/upload")"
    ;;
  get)
    [[ -z "${1:-}" ]] && { echo "Need <classificationType>" >&2; exit 1; }
    require_path_segment "$1" classificationType
    connectordev_api -X GET "$(connectordev_url "ConnectorIcon/$1")"
    ;;
  *) usage >&2; exit 1;;
esac

require_success
# get: raw SVG, no added newline.
if [[ "$sub" == "get" ]]; then printf '%s' "$RESPONSE_BODY"; else echo "$RESPONSE_BODY"; fi
