#!/usr/bin/env bash
# Build-toolchain preflight: JDK, Gradle, and JVM TLS reachability; optionally a
# source scan for calls that buffer a stream or payload.
# connectordev-env-check.sh covers .env and API auth; both can pass while the
# build toolchain is broken, because the scripts use curl's trust path and
# Gradle uses the JVM's.

source "$(dirname "$0")/connectordev-common.sh"

# Hosts a Gradle build must reach: the plugin portal and the SDK repository.
PORTAL_HOST="plugins.gradle.org"
SDK_HOST="boomisdk.s3.amazonaws.com"
PORTAL_URL="https://plugins.gradle.org/m2/com/boomi/connector/com.boomi.connector.gradle.plugin/maven-metadata.xml"
SDK_URL="https://boomisdk.s3.amazonaws.com/releases/com/boomi/connsdk/connector-sdk-api/maven-metadata.xml"

usage() {
  cat <<'EOF'
Usage: connectordev-doctor.sh [<project-dir>] [--skip-network]

Reports on the build toolchain: JDK discovery, Gradle version, and whether the
JVM can reach the plugin portal and the SDK repository.

  <project-dir>    also scan its src/main/java for calls that buffer a whole
                   stream or payload in memory (warnings only)
  --skip-network   run the JDK and Gradle checks only

Exits non-zero if any check fails. Does not read .env.
EOF
}
help_requested "$@"

skip_network=0
project_dir=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-network) skip_network=1; shift;;
    -*) echo "Unknown arg: $1" >&2; usage >&2; exit 1;;
    *)
      [[ -z "$project_dir" ]] || { echo "Unexpected arg: $1" >&2; usage >&2; exit 1; }
      project_dir="$1"; shift;;
  esac
done

failures=0
probe_unchecked=0
pass() { echo "  PASS  $1"; }
warn() { echo "  WARN  $1"; }
fail() { echo "  FAIL  $1"; failures=$(( failures + 1 )); }

# --- JDK ---

echo "JDK"
java_ver=""
java_major=""
# Every capture below tolerates no match: a java that resolves but reports no
# version is a case this check reports, not a reason to stop.
java_raw=$(java -version 2>&1 || true)
java_ver=$(printf '%s\n' "$java_raw" | grep -m1 'version "' || true)

if ! command -v java >/dev/null 2>&1; then
  fail "java is not on PATH"
  echo "        A Homebrew openjdk is keg-only and is not linked into PATH. Add its bin"
  echo "        directory, or pin org.gradle.java.home in gradle.properties."
elif [[ -z "$java_ver" ]]; then
  fail "java is on PATH but reports no version — $(printf '%s\n' "$java_raw" | head -1)"
  echo "        macOS ships a java stub that resolves even with no JDK installed. Install"
  echo "        a JDK, put its bin on PATH, or pin org.gradle.java.home in gradle.properties."
else
  pass "java on PATH — $java_ver"
fi

if [[ -n "$java_ver" ]]; then
  # 1.8.0_292 -> 8; 21.0.12 -> 21; "21" -> 21.
  java_major=$(printf '%s\n' "$java_ver" | sed -n 's/.*"1\.\([0-9][0-9]*\)\..*/\1/p')
  [[ -z "$java_major" ]] && java_major=$(printf '%s\n' "$java_ver" | sed -n 's/.*"\([0-9][0-9]*\)[-.".].*/\1/p')
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
  if /usr/libexec/java_home >/dev/null 2>&1; then
    pass "/usr/libexec/java_home resolves a JDK"
  else
    warn "/usr/libexec/java_home cannot see a JDK"
    echo "        It does not look in Homebrew's Cellar, so a working java on PATH can"
    echo "        still be invisible to it. Gradle's own discovery has the same blind"
    echo "        spot, and the resulting failure names a missing plugin rather than a"
    echo "        missing JVM. Pin org.gradle.java.home in gradle.properties."
  fi
fi

if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
  warn "JAVA_TOOL_OPTIONS is set — it applies to every JVM this build starts"
  echo "        A -Djavax.net.ssl.trustStore here replaces the default trust store. That"
  echo "        cuts both ways: it breaks the build when it points at an unusable keystore,"
  echo "        and it is what makes the build work when it supplies an intercepting root."
  if (( skip_network )); then
    echo "        --skip-network was passed, so which one applies here was not determined."
  else
    echo "        The network check below runs the probe with and without it."
  fi
fi

# --- Gradle ---

echo "Gradle"
gradle_ver=""
if ! command -v gradle >/dev/null 2>&1; then
  warn "gradle is not on PATH"
  echo "        Only needed to generate a wrapper (connectordev-init.sh). A project that"
  echo "        already has ./gradlew does not need it."
else
  # Tolerates no match for the same reason the JDK captures do: gradle --version
  # exits non-zero when it cannot find a JDK, which is a case this check reports.
  gradle_ver=$(gradle --version 2>/dev/null | sed -n 's/^Gradle \([0-9][0-9.]*\).*/\1/p' | head -1 || true)
  if [[ -z "$gradle_ver" ]]; then
    fail "gradle is on PATH but 'gradle --version' produced no version"
  else
    pass "gradle $gradle_ver"
    gradle_major="${gradle_ver%%.*}"
    gradle_minor="${gradle_ver#*.}"; gradle_minor="${gradle_minor%%.*}"
    [[ "$gradle_minor" == "$gradle_ver" ]] && gradle_minor=0
    # The constraint is the JDK/Gradle pairing, not the JDK alone. Gradle gained
    # JDK 21 support during 8.x, so that edge is a minor version.
    if (( gradle_major < 7 )); then
      warn "Gradle $gradle_ver is below 7.0, the minimum for a connector project"
    elif [[ -n "$java_major" ]] && (( java_major >= 21 )) \
       && { (( gradle_major < 8 )) || { (( gradle_major == 8 )) && (( gradle_minor < 5 )); }; }; then
      fail "Gradle $gradle_ver does not support JDK $java_major"
      echo "        It fails compiling settings.gradle with 'Unsupported class file major"
      echo "        version', which names the build script rather than the JDK."
      echo "        Use Gradle 8.5 or newer, or run the build on an older JDK."
    elif (( gradle_major > 9 )); then
      warn "Gradle $gradle_ver is newer than the connector plugin supports"
      echo "        Pin a wrapper rather than building against a rolling system install."
    fi
  fi
fi

# --- JVM network reachability ---

if (( skip_network )); then
  echo "Network: skipped"
  probe_unchecked=1
else
  echo "Network (JVM, not curl)"
  probe_dir=$(mktemp -d)
  trap 'rm -rf "$probe_dir"' EXIT
  cat > "$probe_dir/TlsProbe.java" <<'JAVA'
import javax.net.ssl.*;
import java.net.*;
public class TlsProbe {
    public static void main(String[] args) {
        int rc = 0;
        for (String spec : args) {
            String[] parts = spec.split("\\|", 2);
            try {
                HttpsURLConnection c = (HttpsURLConnection) new URL(parts[1]).openConnection();
                c.setConnectTimeout(15000);
                c.setReadTimeout(15000);
                int code = c.getResponseCode();
                System.out.println((code >= 200 && code < 400 ? "OK|" : "BAD|") + parts[0] + "|HTTP " + code);
            } catch (Exception e) {
                System.out.println("ERR|" + parts[0] + "|" + e.getClass().getSimpleName() + ": " + e.getMessage());
                rc = 1;
            }
        }
        System.exit(rc);
    }
}
JAVA
  probe_cls="$probe_dir/classes"
  mkdir -p "$probe_cls"   # JDK 8's javac will not create -d itself
  probe_ready=0
  if command -v javac >/dev/null 2>&1 \
     && javac -d "$probe_cls" "$probe_dir/TlsProbe.java" 2>/dev/null; then
    probe_ready=1
  fi

  # $1: keep|clear — whether JAVA_TOOL_OPTIONS reaches the probe JVM.
  # Compiled first, because a single-file source launch needs JDK 11+. The source
  # launch is the fallback whenever the compiled run yields nothing, which also
  # covers a javac and java that come from different JDKs.
  # Spelled out rather than built as an argv array: under set -u, bash 3.2 (the
  # macOS system bash) treats an empty array expansion as an unbound variable.
  run_probe() {
    local out=""
    if (( probe_ready )); then
      if [[ "$1" == "clear" ]]; then
        out=$(env -u JAVA_TOOL_OPTIONS java -cp "$probe_cls" TlsProbe \
          "$PORTAL_HOST|$PORTAL_URL" "$SDK_HOST|$SDK_URL" 2>/dev/null) || true
      else
        out=$(java -cp "$probe_cls" TlsProbe \
          "$PORTAL_HOST|$PORTAL_URL" "$SDK_HOST|$SDK_URL" 2>/dev/null) || true
      fi
      if [[ -n "$out" ]]; then
        printf '%s\n' "$out"
        return 0
      fi
    fi
    if [[ "$1" == "clear" ]]; then
      env -u JAVA_TOOL_OPTIONS java "$probe_dir/TlsProbe.java" \
        "$PORTAL_HOST|$PORTAL_URL" "$SDK_HOST|$SDK_URL" 2>/dev/null || true
    else
      java "$probe_dir/TlsProbe.java" \
        "$PORTAL_HOST|$PORTAL_URL" "$SDK_HOST|$SDK_URL" 2>/dev/null || true
    fi
  }

  # A host line is only good when it is OK: the probe reports BAD for an HTTP >= 400
  # as well as ERR for an exception, and either one blocks dependency resolution.
  all_hosts_ok() {
    local line
    [[ -n "$1" ]] || return 1
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      [[ "$line" == "OK|"* ]] || return 1
    done <<< "$1"
    return 0
  }

  probe_out=$(run_probe keep)
  cleared_out=""
  if [[ -n "${JAVA_TOOL_OPTIONS:-}" ]]; then
    cleared_out=$(run_probe clear)
  fi

  # Resolved before the per-host advice, so that advice can defer to it.
  jto_verdict=""
  if [[ -n "${JAVA_TOOL_OPTIONS:-}" && -n "$probe_out" && -n "$cleared_out" ]]; then
    if all_hosts_ok "$probe_out"; then
      if all_hosts_ok "$cleared_out"; then jto_verdict=benign; else jto_verdict=loadbearing; fi
    elif all_hosts_ok "$cleared_out"; then
      jto_verdict=cause
    else
      jto_verdict=irrelevant
    fi
  fi

  if [[ -z "$probe_out" ]]; then
    warn "could not run the JVM TLS probe — reachability is unchecked, not broken"
    echo "        A compiled run and a source launch both produced no output. Check that"
    echo "        javac and java on PATH come from the same JDK."
    probe_unchecked=1
  else
    while IFS='|' read -r status host detail; do
      [[ -z "$status" ]] && continue
      if [[ "$status" == "OK" ]]; then
        pass "JVM reaches $host ($detail)"
      else
        fail "JVM cannot reach $host — $detail"
        # curl and the JVM use different trust paths and can disagree completely;
        # which one fails is what names the cause.
        if curl -s -o /dev/null --max-time 20 -f "$([[ "$host" == "$PORTAL_HOST" ]] && echo "$PORTAL_URL" || echo "$SDK_URL")" 2>/dev/null; then
          echo "        curl reaches the same URL. A TLS problem the JVM alone has surfaces"
          echo "        in Gradle as a MISSING ARTIFACT — 'Plugin was not found', 'Could not"
          echo "        resolve' — never as a TLS error, and --stacktrace does not show one."
          case "$detail" in
            *PKIX*|*SunCertPathBuilder*|*trust*|*Trust*)
              if [[ "$jto_verdict" == "cause" ]]; then
                echo "        This one is a trust failure, and JAVA_TOOL_OPTIONS is causing it — see"
                echo "        below. Do not build a truststore before trying it cleared."
              else
                echo "        This one is a trust failure. Build a project-local truststore from the"
                echo "        JDK cacerts plus the intercepting root, and set it in BOTH"
                echo "        org.gradle.jvmargs (gradle.properties) and GRADLE_OPTS (./gw) — the"
                echo "        daemon and the wrapper launcher read different ones."
              fi
              ;;
            *)
              echo "        The JVM never got as far as an untrusted certificate, so a truststore"
              echo "        will not fix this one. Check whether egress is"
              echo "        being forced through a VPN or proxy tunnel: compare the address curl"
              echo "        reports (curl -so /dev/null -w '%{remote_ip}') against a public DNS"
              echo "        answer for the same host."
              ;;
          esac
        else
          echo "        curl cannot reach it either, so this is ordinary connectivity rather"
          echo "        than a JVM-specific trust problem."
        fi
      fi
    done <<< "$probe_out"

    case "$jto_verdict" in
      loadbearing)
        pass "JAVA_TOOL_OPTIONS is what lets the JVM reach these hosts — leave it set"
        echo "        Cleared, the probe fails. Do not run the build with"
        echo "        'env -u JAVA_TOOL_OPTIONS', and make sure whatever shell runs Gradle"
        echo "        exports it — a -Djavax.net.ssl.trustStoreType=KeychainStore here"
        echo "        supplies an intercepting root the JDK cacerts does not have."
        ;;
      cause)
        warn "JAVA_TOOL_OPTIONS is the cause of the failure above — the probe passes without it"
        echo "        Run the build with it cleared: uncomment 'unset JAVA_TOOL_OPTIONS' in"
        echo "        the project's gw, or prefix the command:"
        echo "          env -u JAVA_TOOL_OPTIONS ./gw connectorArchive"
        ;;
      irrelevant)
        warn "JAVA_TOOL_OPTIONS is not the cause — the probe fails with it cleared too"
        ;;
      benign)
        pass "JAVA_TOOL_OPTIONS does not affect reachability — both hosts reachable either way"
        ;;
    esac
  fi
fi

# --- Source ---

if [[ -n "$project_dir" ]]; then
  echo "Source"
  src_dir="$project_dir/src/main/java"
  if [[ ! -d "$src_dir" ]]; then
    warn "no $src_dir — source not scanned"
  else
    hits=$(grep -rnE --include='*.java' \
      'EntityUtils\.toString|toByteArray\(|readAllBytes\(|ByteArrayOutputStream|readTree\(|toPayload\(.*writeValueAsString\(' \
      "$src_dir" || true)
    if [[ -z "$hits" ]]; then
      pass "no buffering calls in $src_dir"
    else
      warn "calls that hold a whole stream or payload in memory"
      printf '%s\n' "$hits" | sed 's/^/        /'
      echo "        Each needs a bound the connector enforces; how small the data is today is not one."
      echo "        Stream responses; send a record built in code as an output document with JsonPayloadUtil.toPayload: references/sdk_architecture.md, Large payloads."
    fi
  fi
fi

echo
if (( failures > 0 )); then
  echo "$failures check(s) failed."
  exit 1
fi
if (( probe_unchecked )); then
  echo "Toolchain looks usable, but JVM reachability was not checked."
else
  echo "Toolchain looks usable."
fi
