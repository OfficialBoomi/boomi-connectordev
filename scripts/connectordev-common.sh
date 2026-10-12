#!/usr/bin/env bash
# Shared utilities for boomi-connectordev CLI tools; sourced, not executed directly.

set -euo pipefail

# --- xtrace guard ---

# A caller's set -x would otherwise trace credential values.
_XTRACE_WAS_ON=0
xtrace_off() {
  case $- in *x*) _XTRACE_WAS_ON=1 ;; *) _XTRACE_WAS_ON=0 ;; esac
  set +x
}
xtrace_restore() {
  if (( _XTRACE_WAS_ON )); then set -x; fi
}

# --- Environment ---

# The .env keys these scripts read. Any other key in the file is ignored.
_ENV_KEYS="BOOMI_USERNAME BOOMI_API_TOKEN BOOMI_ACCOUNT_ID BOOMI_API_URL BOOMI_TIMEOUT BOOMI_VERIFY_SSL"

_env_key_wanted() {
  case " $_ENV_KEYS " in *" $1 "*) return 0 ;; esac
  return 1
}

# A value bash would leave alone: single-quoted, double-quoted carrying nothing
# it would expand, or bare and drawn only from characters that carry no meaning.
# Sets _ENV_VALUE to the unquoted text.
_ENV_VALUE=""
_env_value_literal() {
  local v="$1" inner
  case "$v" in
    \'*\')
      inner="${v#?}"; inner="${inner%?}"
      if [[ "$inner" != *\'* ]]; then _ENV_VALUE="$inner"; return 0; fi
      ;;
    \"*\")
      inner="${v#?}"; inner="${inner%?}"
      # Double quotes still expand $ and \, so a literal value carries neither.
      if [[ "$inner" != *[\"\$\\]* ]]; then _ENV_VALUE="$inner"; return 0; fi
      ;;
  esac
  if [[ "$v" != *[!A-Za-z0-9._:/@+=-]* ]]; then _ENV_VALUE="$v"; return 0; fi
  return 1
}

# Parses .env rather than sourcing it, so nothing in the file executes and no
# value is expanded. A key the scripts do not read is ignored, which is what
# makes a PATH or BASH_ENV line inert and leaves a .env shared with a sibling
# skill alone. Assigns without export, so no child inherits a credential.
# Reports a line number, never the line: values are credentials.
parse_env_file() {
  local _XTRACE_WAS_ON
  xtrace_off  # Protects the assignment below — printf -v expands a credential.
  local env_file="$1" line trimmed key value lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$(( lineno + 1 ))
    trimmed="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$trimmed" || "$trimmed" == '#'* ]] && continue
    case "$trimmed" in
      export[[:space:]]*)
        trimmed="${trimmed#export}"
        trimmed="${trimmed#"${trimmed%%[![:space:]]*}"}"
        ;;
    esac
    [[ "$trimmed" == *=* ]] || continue
    key="${trimmed%%=*}"
    _env_key_wanted "$key" || continue
    value="${trimmed#*=}"
    if ! _env_value_literal "$value"; then
      value="${value%%[[:space:]]#*}"              # drop a trailing # comment
      value="${value%"${value##*[![:space:]]}"}"   # and the space ahead of it
      if ! _env_value_literal "$value"; then
        _reject_env_file "$env_file" "line $lineno: $key needs single-quoting"
      fi
    fi
    printf -v "$key" '%s' "$_ENV_VALUE"
  done < "$env_file"
  xtrace_restore
}

_reject_env_file() {
  echo "ERROR: refusing to load $1: $2" >&2
  echo "  Expected blank lines, # comments, and KEY=value assignments." >&2
  echo "  Single-quote a value containing spaces or shell characters." >&2
  exit 1
}

load_env() {
  local _XTRACE_WAS_ON
  xtrace_off  # Protects the .env parse: it handles credential values.
  local env_file="./.env"
  if [[ ! -f "$env_file" ]]; then
    echo "ERROR: .env file not found in $(pwd)" >&2
    exit 1
  fi
  parse_env_file "$env_file"
  # Both land in the URL path, and .env is not a trusted source.
  if [[ -n "${BOOMI_ACCOUNT_ID:-}" ]]; then
    require_path_segment "$BOOMI_ACCOUNT_ID" BOOMI_ACCOUNT_ID
  fi
  if [[ -n "${BOOMI_API_URL:-}" ]]; then
    require_api_url
  fi
  xtrace_restore
}

require_env() {
  local _XTRACE_WAS_ON
  xtrace_off  # Protects ${!var} — expands a credential by name.
  local missing=()
  for var in "$@"; do
    if [[ -z "${!var:-}" ]]; then
      missing+=("$var")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required environment variables: ${missing[*]}" >&2
    echo "Check your .env file." >&2
    exit 1
  fi
  xtrace_restore
}

env_status() {
  local _XTRACE_WAS_ON
  xtrace_off  # Protects env-check's presence report.
  for var in "$@"; do
    if [[ -n "${!var:-}" ]]; then echo "  $var=SET"; else echo "  $var=UNSET"; fi
  done
  xtrace_restore
}

require_tools() {
  local missing=()
  for tool in "$@"; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: Missing required tools: ${missing[*]}" >&2
    exit 1
  fi
}

# --- Argument handling ---

# Pass the full arg vector before load_env so --help works after the subcommand.
help_requested() {
  local arg
  for arg in "$@"; do
    case "$arg" in --help|-h) usage; exit 0 ;; esac
  done
}

# Must exit (not return): shift-less callers loop forever otherwise.
reject_flags() {
  local arg
  for arg in "$@"; do
    case "$arg" in -*) echo "ERROR: unexpected option '$arg'" >&2; usage >&2; exit 1 ;; esac
  done
}

# --- Version ---

_skill_version() {
  cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null || echo "unknown"
}

# --- Constants ---

CONNECTORDEV_USER_AGENT="boomi-companion/boomi-connectordev/$(_skill_version)"

# --- JSON ---

# The escapes JSON names, without the refusal.
# Backslash first, so the backslashes the later substitutions insert are not doubled.
json_escape_chars() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"
  s="${s//$'\b'/\\b}"; s="${s//$'\f'/\\f}"
  s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

# Escapes a value for interpolation into a JSON string. A raw control character is
# illegal there, so one the escapes above do not cover is refused rather than sent.
json_escape() {
  local s what="${2:-value}"
  s=$(json_escape_chars "$1")
  if [[ -n "$(printf '%s' "$s" | LC_ALL=C tr -d '\40-\377')" ]]; then
    echo "ERROR: $what contains a control character that cannot be sent in JSON" >&2
    return 1
  fi
  printf '%s' "$s"
}

# --- URL builder ---

# Rejects a value before it is interpolated into a URL path: curl normalises the
# path before sending, so a separator or relative segment retargets the request.
require_path_segment() {
  local val="$1" what="${2:-argument}"
  if [[ -z "$val" || "$val" == "." || "$val" == ".." || "$val" != "${val//[^A-Za-z0-9._-]/}" ]]; then
    echo "ERROR: invalid $what: '$val'" >&2
    echo "  Expected a platform-issued identifier: letters, digits, '.', '_', '-'." >&2
    exit 1
  fi
}

# BOOMI_API_URL prefixes every request. An https host and nothing more.
require_api_url() {
  while [[ "$BOOMI_API_URL" == */ ]]; do BOOMI_API_URL="${BOOMI_API_URL%/}"; done
  if [[ ! "$BOOMI_API_URL" =~ ^https://[A-Za-z0-9._-]+(:[0-9]+)?$ ]]; then
    echo "ERROR: invalid BOOMI_API_URL: '$BOOMI_API_URL'" >&2
    echo "  Expected an https host only, e.g. https://api.boomi.com." >&2
    exit 1
  fi
}

# Connectors API URL (base path differs from the Platform API's /api/rest/v1).
connectordev_url() {
  local endpoint="$1"
  echo "${BOOMI_API_URL}/connector/api/rest/v1/${BOOMI_ACCOUNT_ID}/${endpoint}"
}

# --- Text editing ---

# In-place sed. BSD sed requires a backup suffix and GNU sed reads one as a file
# operand, so the same invocation cannot serve both.
sedi() {
  if sed --version 2>/dev/null | grep -q GNU; then sed -i "$@"; else sed -i '' "$@"; fi
}

# --- Local files ---

# Rejects a caller-supplied path before it is interpolated as curl's @path. The
# path itself is then passed to curl, so what was checked is what is sent.
require_local_file() {
  local path="$1" what="${2:-file}"
  case "$path" in
    -|/dev/stdin|/dev/fd/*|/proc/self/fd/*)
      echo "ERROR: invalid $what: '$path'" >&2
      echo "  Expected a file path. curl reads this one as stdin, which carries the auth config." >&2
      exit 1 ;;
  esac
  if [[ "$path" == *";"* || "$path" == *","* ]]; then
    echo "ERROR: invalid $what: '$path'" >&2
    echo "  Expected a path free of ';' and ',': curl reads both as separators in a multipart value." >&2
    exit 1
  fi
  if [[ ! -f "$path" ]]; then
    echo "ERROR: $what not found: '$path'" >&2
    exit 1
  fi
}

# --- API helper ---

# Emits a curl config file on stdout so credentials reach curl via stdin
# (curl -K -), never argv. Escapes \ and " — curl's config parser silently
# truncates values containing either, yielding an undiagnosable 401.
curl_cfg() {
  (( $# % 2 == 0 )) || { echo "ERROR: curl_cfg needs directive/value pairs" >&2; return 1; }
  # After the arity check, so the early return above needs no restore.
  local _XTRACE_WAS_ON
  xtrace_off  # Protects the directive values — a caller passes a credential here.
  local val
  while [[ $# -gt 1 ]]; do
    val="$2"
    val="${val//\\/\\\\}"
    val="${val//\"/\\\"}"
    printf '%s = "%s"\n' "$1" "$val"
    shift 2
  done
  xtrace_restore
}

# Sets RESPONSE_BODY and RESPONSE_CODE. Auth occupies stdin (-K -), so callers
# must never pipe data in or use @- / -T -; inline -d and --data-binary @file are fine.
# A caller-supplied body goes out under --data-raw: the other -d forms read a leading @ as a file.
RESPONSE_BODY=""
RESPONSE_CODE=""
connectordev_api() {
  local _XTRACE_WAS_ON
  xtrace_off  # Protects the curl auth argument.

  local ssl_flag=""
  [[ "${BOOMI_VERIFY_SSL:-true}" == "false" ]] && ssl_flag="-k"

  local tmpfile
  tmpfile=$(mktemp)

  # Run curl without errexit so connection failures return, not abort.
  local rc
  set +e
  RESPONSE_CODE=$(curl_cfg user "BOOMI_TOKEN.${BOOMI_USERNAME}:${BOOMI_API_TOKEN}" \
    | curl -s $ssl_flag \
    --max-time "${BOOMI_TIMEOUT:-60}" \
    -A "$CONNECTORDEV_USER_AGENT" \
    -K - \
    -o "$tmpfile" -w "%{http_code}" \
    "$@")
  rc=$?
  set -e
  RESPONSE_BODY=$(cat "$tmpfile")
  rm -f "$tmpfile"

  xtrace_restore

  if (( rc != 0 )) || [[ -z "$RESPONSE_CODE" || "$RESPONSE_CODE" == "000" ]]; then
    echo "ERROR: could not reach the Boomi API -- network or connection failure (curl exit ${rc})." >&2
    echo "  Likely a request timeout (BOOMI_TIMEOUT=${BOOMI_TIMEOUT:-60}s), DNS failure, refused" >&2
    echo "  connection, or no network. No HTTP response was received, so the request may or may" >&2
    echo "  not have reached the server." >&2
    return 1
  fi
  return 0
}

# Print response and exit on non-2xx; a 403 hint teaches the likely fixes.
require_success() {
  if (( RESPONSE_CODE < 200 || RESPONSE_CODE >= 300 )); then
    echo "ERROR: HTTP $RESPONSE_CODE" >&2
    echo "$RESPONSE_BODY" >&2
    if (( RESPONSE_CODE == 403 )); then
      echo "HINT: 403 here means bad credentials, wrong BOOMI_ACCOUNT_ID, or BOOMI_API_URL not" >&2
      echo "  matching your console region. Do not retry; run connectordev-env-check.sh first." >&2
    elif (( RESPONSE_CODE == 400 )); then
      echo "HINT: read the message above — a 400 from this API names what it rejected" >&2
      echo "  (a duplicate group name, a missing or unknown filter field, a malformed body)." >&2
      echo "  If the body is right, check account enablement: SDK Publisher Agreement, DEVELOPER privilege." >&2
    fi
    exit 1
  fi
}
