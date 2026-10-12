#!/usr/bin/env bash
# Connector version upload, deletion, queries, and descriptor validation (Connectors API).

source "$(dirname "$0")/connectordev-common.sh"

usage() {
  cat <<'EOF'
Usage: connectordev-version.sh <subcommand> [args]

Subcommands:
  upload <zip-file> --group <groupType> [--changelog <text>]   multipart upload; response carries versionId
                                                               Checks the echoed changelog against what was sent; reports on stderr.
  delete <groupType> <versionId>                               blocked if the version is in use or under review
  query [<json-file>]                                          returns up to 100 per page; default body {} returns all
  query-more <queryToken>                                      next page for a prior query
  validate <descriptor-xml-file>                               validate connector-descriptor.xml; no side effects.
                                                               Validate the BUILT descriptor inside the archive, not the source file.
                                                               Exits non-zero on a rejected descriptor, including the 2xx form.
                                                               A warnings-only response passes; the warning goes to stderr.

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
    [[ -z "${1:-}" ]] && { echo "Need <zip-file>" >&2; exit 1; }
    require_local_file "$1" "zip-file"
    zip_file="$1"; shift
    group=""; changelog=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --group)     group="$2"; shift 2;;
        --changelog) changelog="$2"; shift 2;;
        *) echo "Unknown arg: $1" >&2; exit 1;;
      esac
    done
    [[ -z "$group" ]] && { echo "Need --group <groupType>" >&2; exit 1; }
    args=(-F "connectorVersionArchive=@${zip_file};type=application/zip" --form-string "groupType=${group}")
    # File-sourced -F: the only form that declares a charset and keeps ';', '@' and '<' literal.
    if [[ -n "$changelog" ]]; then
      changelog_file=$(mktemp)
      trap 'rm -f "$changelog_file"' EXIT
      printf '%s' "$changelog" > "$changelog_file"
      args+=(-F "changeLog=<${changelog_file};type=text/plain; charset=UTF-8")
    fi
    connectordev_api -X POST -H "Accept: application/json" "${args[@]}" \
      "$(connectordev_url "ConnectorVersion/upload")"
    ;;
  delete)
    [[ -z "${1:-}" || -z "${2:-}" ]] && { echo "Need <groupType> <versionId>" >&2; exit 1; }
    gt=$(json_escape "$1" groupType) || exit 1
    vid=$(json_escape "$2" versionId) || exit 1
    body="{\"groupType\":\"${gt}\",\"versionId\":\"${vid}\"}"
    connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      --data-binary "$body" "$(connectordev_url "ConnectorVersion/delete")"
    ;;
  query)
    body="{}"
    if [[ -n "${1:-}" ]]; then
      require_local_file "$1" "json-file"
      body="@$1"
    fi
    connectordev_api -X POST -H "Content-Type: application/json" -H "Accept: application/json" \
      --data-binary "$body" "$(connectordev_url "ConnectorVersionQuery/query")"
    ;;
  query-more)
    [[ -z "${1:-}" ]] && { echo "Need <queryToken>" >&2; exit 1; }
    # --data-raw is required here; do not normalise to --data-binary.
    connectordev_api -X POST -H "Content-Type: text/plain" -H "Accept: application/json" \
      --data-raw "$1" "$(connectordev_url "ConnectorVersionQuery/queryMore")"
    ;;
  validate)
    [[ -z "${1:-}" ]] && { echo "Need <descriptor-xml-file>" >&2; exit 1; }
    require_local_file "$1" "descriptor-xml-file"
    connectordev_api -X POST -H "Accept: application/json" -F "descriptor=@$1" \
      "$(connectordev_url "ConnectorDescriptorValidation/validate")"
    ;;
  *) usage >&2; exit 1;;
esac

require_success
echo "$RESPONSE_BODY"

# A 2xx says nothing about what was stored: look for the sent text, JSON-escaped, in the response.
if [[ "$sub" == "upload" && -n "${changelog:-}" ]]; then
  sent=$(json_escape_chars "$changelog")
  if [[ "$RESPONSE_BODY" != *"$sent"* ]]; then
    # A pure-printable-ASCII payload is comparable: this API escapes only non-ASCII as \uXXXX.
    if [[ "$RESPONSE_BODY" == *'\u'* && -n "$(printf '%s' "$sent" | LC_ALL=C tr -d '\40-\176')" ]]; then
      echo "NOTE: this response escapes non-ASCII as \\uXXXX, which the changelog cannot be" >&2
      echo "  compared against. Read the changeLog field above and check it yourself." >&2
    else
      echo "WARNING: the changelog text is not in the response as sent — it may have been altered." >&2
      echo "  Compare the changeLog field above against what you passed." >&2
    fi
  fi
fi

# A rejected descriptor can come back 2xx, so status alone reads as a pass; anything
# carrying no known marker is treated as a failure.
if [[ "$sub" == "validate" ]]; then
  if [[ "$RESPONSE_BODY" == *'"errors"'* ]]; then
    echo "ERROR: descriptor rejected — read the messages in the response above" >&2
    exit 1
  elif [[ "$RESPONSE_BODY" == *'"warnings"'* ]]; then
    echo "WARNING: descriptor accepted with warnings — read the response above" >&2
  elif [[ "$RESPONSE_BODY" != *'"success"'* ]]; then
    echo "ERROR: unrecognized validate response — treating as a failure" >&2
    exit 1
  fi
fi
