#!/usr/bin/env bash
# Lays down a known-good connector project from the shipped template.

source "$(dirname "$0")/connectordev-common.sh"

# The Gradle the template pins; references/build_and_package.md owns the
# JDK/Gradle pairing.
GRADLE_PIN="8.14.5"

usage() {
  cat <<'EOF'
Usage: connectordev-init.sh <target-dir> [--name <artifact>] [--package <pkg>] [--class <Name>]

Copies the template project, renames it, and pins a Gradle wrapper.

  <target-dir>        created; must not already exist
  --name <artifact>   archive and jar base name          (default: the target dir's name)
  --package <pkg>     Java package                       (default: com.example.connector)
  --class <Name>      Connector class, without package   (default: ExampleConnector)

Needs gradle on PATH to generate the wrapper. Run connectordev-doctor.sh first.
EOF
}
[[ -z "${1:-}" ]] && { usage; exit 0; }
help_requested "$@"

target="$1"; shift
name=""; pkg="com.example.connector"; cls="ExampleConnector"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name|--package|--class)
      [[ $# -ge 2 ]] || { echo "ERROR: $1 needs a value" >&2; usage >&2; exit 1; }
      case "$1" in
        --name)    name="$2";;
        --package) pkg="$2";;
        --class)   cls="$2";;
      esac
      shift 2;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 1;;
  esac
done

[[ -e "$target" ]] && { echo "ERROR: already exists: $target" >&2; exit 1; }
[[ -z "$name" ]] && name="$(basename "$target")"
[[ -z "$pkg"  || "$pkg"  != "${pkg//[^A-Za-z0-9._]/}"  ]] && { echo "ERROR: invalid package: '$pkg'" >&2; exit 1; }
[[ -z "$cls"  || "$cls"  != "${cls//[^A-Za-z0-9_]/}"   ]] && { echo "ERROR: invalid class: '$cls'" >&2; exit 1; }
[[ -z "$name" || "$name" != "${name//[^A-Za-z0-9._-]/}" ]] && { echo "ERROR: invalid name: '$name'" >&2; exit 1; }

# The operation class is renamed alongside the connector, so no half-renamed
# source reaches the scaffold.
op_base="${cls%Connector}"
[[ -z "$op_base" ]] && op_base="$cls"
op_cls="${op_base}ExecuteOperation"

require_tools gradle

template="$(dirname "$0")/../templates/connector-project"
[[ -d "$template" ]] || { echo "ERROR: template not found: $template" >&2; exit 1; }

mkdir -p "$(dirname "$target")"
cp -R "$template" "$target"

# Move the sources into the requested package, then rewrite the references.
old_pkg_dir="$target/src/main/java/com/example/connector"
new_pkg_dir="$target/src/main/java/${pkg//.//}"
if [[ "$new_pkg_dir" != "$old_pkg_dir" ]]; then
  mkdir -p "$new_pkg_dir"
  mv "$old_pkg_dir"/*.java "$new_pkg_dir"/
  # Drop what the template's package left behind, without touching the new tree.
  find "$target/src/main/java/com" -depth -type d -empty -delete 2>/dev/null || true
fi

find "$target" -type f \( -name '*.java' -o -name '*.gradle' -o -name 'gradle.properties' \) -print0 \
  | while IFS= read -r -d '' f; do
      sedi \
        -e 's|ExampleExecuteOperation|@@OP@@|g' \
        -e 's|ExampleConnector|@@CLS@@|g' \
        -e 's|com\.example\.connector|@@PKG@@|g' \
        -e 's|my-connector|@@NAME@@|g' "$f"
      sedi \
        -e "s|@@OP@@|${op_cls}|g" \
        -e "s|@@CLS@@|${cls}|g" \
        -e "s|@@PKG@@|${pkg}|g" \
        -e "s|@@NAME@@|${name}|g" "$f"
    done
# Through temporaries, so a --class naming the template's other file cannot have
# one move clobber what the other still has to move.
mv "$new_pkg_dir/ExampleConnector.java"        "$new_pkg_dir/.conn.tmp"
mv "$new_pkg_dir/ExampleExecuteOperation.java" "$new_pkg_dir/.op.tmp"
mv "$new_pkg_dir/.conn.tmp" "$new_pkg_dir/${cls}.java"
mv "$new_pkg_dir/.op.tmp"   "$new_pkg_dir/${op_cls}.java"

chmod +x "$target/gw"

# $1: keep|clear — whether JAVA_TOOL_OPTIONS reaches the Gradle JVM.
gen_wrapper() {
  if [[ "$1" == "clear" ]]; then
    ( cd "$target" && env -u JAVA_TOOL_OPTIONS gradle --no-daemon --console=plain \
        wrapper --gradle-version "$GRADLE_PIN" 2>&1 )
  else
    ( cd "$target" && gradle --no-daemon --console=plain \
        wrapper --gradle-version "$GRADLE_PIN" 2>&1 )
  fi
}

# JAVA_TOOL_OPTIONS can break JVM TLS or be what makes it work, so it is cleared
# only when the wrapper generates without it and not with it.
jto_cleared=0
if ! wrapper_out=$(gen_wrapper keep); then
  if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]] && gen_wrapper clear >/dev/null; then
    jto_cleared=1
    sedi -e 's|^# unset JAVA_TOOL_OPTIONS$|unset JAVA_TOOL_OPTIONS|' "$target/gw"
  else
    echo "ERROR: could not generate the Gradle wrapper:" >&2
    printf '%s\n' "$wrapper_out" | sed 's/^/  /' >&2
    echo "  'Test of distribution url ... failed' above means the JVM could not fetch" >&2
    echo "  the Gradle distribution — most often a TLS trust failure, which that" >&2
    echo "  message does not name." >&2
    if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
      echo "  It failed with JAVA_TOOL_OPTIONS cleared too, so that variable is not the cause." >&2
    fi
    echo "  Run connectordev-doctor.sh to diagnose. Removing the partial project." >&2
    rm -rf "$target"
    exit 1
  fi
fi

echo "Created $target (gradle wrapper $GRADLE_PIN)"
if (( jto_cleared )); then
  echo "  note:   JAVA_TOOL_OPTIONS broke the JVM's TLS; the wrapper generated with it"
  echo "          cleared, and gw now unsets it for every build"
fi
echo "  build:  cd $target && ./gw connectorArchive"
echo "  pins:   connector plugin 0.5.1, SDK 2.31.0 — check for newer before shipping:"
echo "          https://plugins.gradle.org/plugin/com.boomi.connector"
echo "          https://boomisdk.s3.amazonaws.com/releases/com/boomi/connsdk/connector-sdk-api/maven-metadata.xml"
