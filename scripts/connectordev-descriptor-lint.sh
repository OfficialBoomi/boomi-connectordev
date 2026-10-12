#!/usr/bin/env bash
# Local schema check of connector-descriptor.xml against the SDK's own XSD.
# connectordev-version.sh validate remains the pre-upload gate.

source "$(dirname "$0")/connectordev-common.sh"

SDK_METADATA_URL="https://boomisdk.s3.amazonaws.com/releases/com/boomi/connsdk/connector-sdk-model/maven-metadata.xml"
SDK_JAR_BASE="https://boomisdk.s3.amazonaws.com/releases/com/boomi/connsdk/connector-sdk-model"
# The root XSD's includes resolve as siblings, so the whole directory is extracted flat.
XSD_GLOB="com/boomi/model/connector/*.xsd"
ROOT_XSD="genericconnectordesc.xsd"
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/bc-connectordev/schema"

usage() {
  cat <<'EOF'
Usage: connectordev-descriptor-lint.sh <descriptor-xml> [--sdk-version <version>]

Validates connector-descriptor.xml against genericconnectordesc.xsd from the
connector-sdk-model jar.

  --sdk-version <version>   pin the SDK whose schema to use (default: latest release)

The schema is cached per version, so a pinned version runs offline after the
first fetch. Point this at the source descriptor as you edit; the built copy is
covered by connectordev-version.sh validate before upload.

Exits non-zero if the descriptor fails to validate. Does not read .env.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

descriptor="$1"; shift
sdk_version=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --sdk-version)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 needs a value" >&2; usage >&2; exit 1; }
      sdk_version="$2"; shift 2;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1;;
  esac
done

[[ -f "$descriptor" ]] || { echo "ERROR: descriptor not found: '$descriptor'" >&2; exit 1; }

require_tools curl unzip xmllint

# --- Schema ---

resolve_latest() {
  local meta
  meta=$(curl -sS --max-time 30 -f "$SDK_METADATA_URL" 2>/dev/null) || return 1
  printf '%s\n' "$meta" | sed -n 's|.*<release>\(.*\)</release>.*|\1|p' | head -1
}

if [[ -z "$sdk_version" ]]; then
  sdk_version=$(resolve_latest) || true
  if [[ -z "$sdk_version" ]]; then
    echo "ERROR: could not resolve the latest connector-sdk-model version" >&2
    echo "  $SDK_METADATA_URL is unreachable. Pass --sdk-version to use a cached schema," >&2
    echo "  or fall back to connectordev-version.sh validate, which needs only the API." >&2
    exit 1
  fi
fi

# A version reaches a URL path and the cache directory name, whether it came
# from the caller or from the metadata.
require_path_segment "$sdk_version" "sdk-version"

cache="$CACHE_ROOT/$sdk_version"

if [[ ! -f "$cache/$ROOT_XSD" ]]; then
  jar_url="$SDK_JAR_BASE/$sdk_version/connector-sdk-model-$sdk_version.jar"
  staging=$(mktemp -d) || { echo "ERROR: could not create a temp directory" >&2; exit 1; }
  trap 'rm -rf "$staging"' EXIT

  if ! curl -sS --max-time 60 -f -o "$staging/model.jar" "$jar_url" 2>/dev/null; then
    echo "ERROR: could not fetch the schema jar for SDK $sdk_version" >&2
    echo "  $jar_url" >&2
    echo "  Check the version against $SDK_METADATA_URL." >&2
    exit 1
  fi
  if ! unzip -q -j -o "$staging/model.jar" "$XSD_GLOB" -d "$staging/xsd" 2>/dev/null; then
    echo "ERROR: the jar for SDK $sdk_version carries no $XSD_GLOB" >&2
    exit 1
  fi
  [[ -f "$staging/xsd/$ROOT_XSD" ]] || { echo "ERROR: $ROOT_XSD is absent from the jar for SDK $sdk_version" >&2; exit 1; }

  mkdir -p "$CACHE_ROOT" && rm -rf "$cache" && mv "$staging/xsd" "$cache"
fi

# --- Validate ---

echo "Schema: $ROOT_XSD from connector-sdk-model $sdk_version"
xmllint --noout --schema "$cache/$ROOT_XSD" "$descriptor" || exit 1
