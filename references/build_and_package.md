# Building and Packaging a Connector

## Contents
- Framework choice
- Project layout
- Gradle build (primary path)
- Reading the official samples first
- Scaffolding a project
- Maven (best-effort)
- Dependency rules
- Class loading
- Packaging requirements
- Current versions

## Framework choice

| Situation | Framework |
|---|---|
| REST API with JSON | REST framework (`connector-sdk-rest`) — the most common choice |
| OpenAPI 3.0 spec available and simple | OpenAPI DSL (Gradle only) — specs over ~10k lines or with deep self-referential definitions cause platform timeouts; fall back to the REST framework |
| SOAP | SOAP framework (`connector-sdk-ws`) |
| Anything else (binary protocols, JDBC, complex auth) | Base classes (`BaseConnector` / `BaseOperation`) |

## Project layout

```
my-connector/
├── build.gradle
└── src/
    ├── main/
    │   ├── java/com/example/connector/...
    │   └── resources/
    │       ├── META-INF/connector-descriptor.xml
    │       └── schemas/*.json       (optional operation input/output schemas)
    └── test/java/...
```

Package convention: `com.boomi.connector.<name>` or your own domain. One Connector class per connector; its fully qualified name goes in `connector-config.xml`.

## Gradle build (primary path)

The `com.boomi.connector` Gradle plugin registers the SDK repository, generates `connector-config.xml`, packages the archive with strict class loading, and provides the `connectorArchive` task.

```gradle
plugins {
    id 'com.boomi.connector' version '0.5.1'
}

version = "1.0.0"

repositories {
    mavenCentral()
}

java.sourceCompatibility = 1.8
java.targetCompatibility = 1.8

connector {
    sdkVersion "2.30.1"
    className "com.example.connector.MyConnector"
}

dependencies {
    // REST framework; omit if using base classes only
    api "com.boomi.connsdk:connector-sdk-rest:${connector.sdkVersion.get()}"
    api "com.boomi.connsdk:connector-sdk-util"
}

jar { archiveBaseName = "my-connector" }
connectorArchive { archiveBaseName = "my-connector" }
```

Two Java versions are in play and they are not the same one: the JDK the build **runs on** is a separate choice from the bytecode it **emits**.

The bytecode is fixed at Java 8, because that is what the runtimes execute. `source/targetCompatibility = 1.8` sets it and the template carries it; targeting Java 11 instead needs Boomi's approval.

For the build JDK, Boomi's packaging guidance is to compile with any version, and its setup instructions install JDK 8. JDK 8 builds the template and emits Java 8 bytecode.

What does constrain the choice is the **pairing**: a JDK is only usable with a Gradle new enough to support it. Gradle 7.0 is the documented minimum for a connector project. Gradle 7.6.4 cannot build on JDK 21 — it fails compiling `settings.gradle` with `Unsupported class file major version 65`, an error that names the build script rather than the JDK. Pin a wrapper rather than relying on a rolling system install; the template pins Gradle 8.14.5, and 9.0.0 also builds.

The archive lands under `build/` — `distributions/` with the current plugin, `connector-upload/` with older ones.

`scripts/connectordev-doctor.sh` checks the three things that most often break a first build — JDK discovery, the Gradle/JDK pairing, and whether the JVM can reach the plugin portal and the SDK repository. Run it before scaffolding.

Two environment traps are not Boomi-specific but both block the build. If `java` is not on `PATH` (Homebrew JDKs are not symlinked into `/Library/Java/JavaVirtualMachines`, so `/usr/libexec/java_home` also fails), set `JAVA_HOME` explicitly, or pin `org.gradle.java.home` in `gradle.properties`. If dependency resolution fails with `PKIX path building failed`, check `JAVA_TOOL_OPTIONS` before suspecting corporate SSL inspection — a machine-global `-Djavax.net.ssl.trustStore` replaces the JVM's default trust store for every build. It cuts both ways, so establish which way before changing anything: `connectordev-doctor.sh` runs its TLS probe with and without the variable and reports whether it is the cause or the fix.

**It breaks the build** when the override resolves to an unusable keystore. On JDK 21 the override has to resolve to a readable keystore to take effect: a path that does not exist falls back to the default `cacerts` and TLS keeps working, while an empty keystore fails every TLS peer, including the SDK repository, with `InvalidAlgorithmParameterException: the trustAnchors parameter must be non-empty`. That is the case to run without:

```bash
env -u JAVA_TOOL_OPTIONS JAVA_HOME=/path/to/jdk gradle connectorArchive
```

**It is load-bearing** when the override is what supplies the intercepting root; clearing it is then what causes the failure. `-Djavax.net.ssl.trustStoreType=KeychainStore` points the JVM at the macOS Keychain, which on an intercepted network holds the root curl already trusts. On JDK 17 that is enough to reach the plugin portal and the SDK repository, and clearing the variable fails both with `PKIX path building failed`.

On JDK 8 the same setting does not work. There the JVM needs an explicit truststore built from its own `cacerts` plus the intercepting chain, so the remedy can differ by JDK on one machine.

**A green `connectordev-env-check.sh` does not imply a working build toolchain** — the scripts use curl's trust store, Gradle uses the JVM's. These are separate trust paths and can disagree completely, and the disagreement is diagnostic: when curl reaches an artifact the JVM cannot, Gradle reports a **missing artifact** (`Plugin [com.boomi.connector] was not found`, `Could not resolve`) rather than a TLS error, and `--stacktrace` does not show one either.

Not every such failure is a trust failure. A peer that closes the connection instead of presenting an untrusted certificate produces `Remote host terminated the handshake`, which no truststore fixes; that shape points at egress being forced through a VPN or proxy tunnel, and comparing the address curl reports (`curl -so /dev/null -w '%{remote_ip}'`) against a public DNS answer for the same host tells you which.

## Reading the official samples first

The Gradle plugin ships two source-generating tasks. Run the first before writing any connector code — the samples show idiom, which the Javadoc does not.

| Task | Produces |
|---|---|
| `./gw connectorSamples` | the official sample classes (around 40) under `build/generated/src/connectorSamples/java/com/boomi/connector/sample/`, including `SizeLimitedJsonOperation`, `ImportableFieldsBrowser`, and full listen and polling examples |
| `./gw connectorHelloWorldSource` | a working starter connector, as a scaffolding reference |

The samples compile in place — `./gw compileConnectorSamplesJava` — because the plugin gives them their own classpath from `com.boomi.connsdk:connector-sdk-samples`, which carries `boomi-json-util` and Jackson on top of the usual SDK artifacts.

**A sample that compiles in place will not necessarily compile once copied into your own source tree**, because your connector's classpath is narrower. The `sample/json/` package is where this bites, along with `SampleClient`, which seven other samples import: between them they reference `com.boomi.util.json` and `com.fasterxml.jackson`, neither of which a connector resolves by default. `SizeLimitedJsonOperation` copied across fails with `package com.boomi.util.json does not exist` plus four Jackson errors, because `com.boomi.util.json.JsonPayloadUtil` lives in `boomi-json-util` and Jackson is not transitive from anything the connector already has.

Add `boomi-json-util` and Jackson as dependencies — see the note on `boomi-json-util` below, whose POM declares no dependencies at all. Substituting `com.boomi.connector.util.PayloadUtil` for the payload call is not an alternative here: it clears the `com.boomi.util.json` error alone and leaves the four Jackson ones, since these samples use `ObjectMapper` and `JsonNode` structurally. `PayloadUtil` is the right choice when writing your own payload code on the default classpath, not when porting one of these.

Confirm a signature against the jars you actually resolve rather than against a Javadoc page or a sample:

```bash
javap -cp connector-sdk-api.jar:connector-sdk-util.jar com.boomi.connector.api.OperationResponse
```

`javap` is authoritative for the version in the build, offline, and reports a class the classpath lacks as `class not found` — which is how the `JsonPayloadUtil` gap above surfaces before it becomes a compile error.

## Scaffolding a project

`scripts/connectordev-init.sh <target-dir> [--name <artifact>] [--package <pkg>] [--class <Name>]` lays down the template under `templates/connector-project/` — build files, a pinned Gradle wrapper, a minimal Connector and EXECUTE Operation, and the `META-INF` resource layout — then renames it. It needs `gradle` on `PATH` to generate the wrapper; a project that already has `./gradlew` does not.

When `JAVA_TOOL_OPTIONS` is set and wrapper generation fails, init retries once with it cleared. If that succeeds, the variable was breaking TLS, and init uncomments the `unset JAVA_TOOL_OPTIONS` line in the project's `gw` so every build runs without it. If generation succeeds with the variable set, it is left alone — it may be what makes TLS work.

The template ships a `gw` launcher wrapper. A Gradle build runs two JVMs and only one of them reads `gradle.properties`:

| JVM | Does | Reads |
|---|---|---|
| Gradle daemon | resolves dependencies, runs the build | `org.gradle.jvmargs` in `gradle.properties` |
| Wrapper launcher | downloads the distribution zip | `GRADLE_OPTS` only |

So a truststore set only in `gradle.properties` fixes dependency resolution and leaves the distribution download failing — a second failure, with a different message (`SunCertPathBuilderException` against `gradle-<version>-bin.zip`), from the same cause. `gw` exports `GRADLE_OPTS` and `JAVA_HOME` before delegating to `./gradlew`, so both JVMs get the same settings. Set a truststore in both places or neither.

## Maven (best-effort)

Gradle is the supported build path. Boomi's docs "highly recommend" Gradle and note that Maven "doesn't generate any sample connector code". Several things on this page exist only through the Gradle plugin:

- `connectorArchive` — archive packaging, `connector-config.xml` generation, strict class loading
- `connectorHelloWorldSource` and `connectorSamples` — the starter connector and the official samples
- the OpenAPI DSL

This section provides no `pom.xml` or assembly descriptor. A Maven project has to reproduce the archive layout under Packaging requirements and the `connector-config.xml` below by hand; beyond the repository coordinates, treat it as best-effort.

The SDK artifacts resolve from the same repository:

```xml
<repositories>
  <repository>
    <id>boomisdk</id>
    <url>https://boomisdk.s3.amazonaws.com/releases</url>
  </repository>
</repositories>
```

Without the Gradle plugin, `connector-config.xml` is hand-maintained:

```xml
<GenericConnector sdkApiVersion="2.30.1" strictClassLoading="true">
    <connectorClassName>com.example.connector.MyConnector</connectorClassName>
</GenericConnector>
```

The `sdkApiVersion` must match the SDK version of the bundled JARs. **Omitting it defaults to `1.0.0`**, which the upload response reports back as `"connectorSDKVersion":"1.0.0"`. The platform guards this, but the guard rides on `strictClassLoading`: with strict mode `true` the upload is rejected outright (HTTP 500, *"Strict mode class loading must be utilized with a Connector SDK version of 2.23.1 and above…"*); with strict mode `false` the upload is accepted and silently recorded as `1.0.0`. So the silent downgrade is reachable only from a hand-maintained config that also opts out of strict class loading — Gradle users cannot hit it, since the plugin hard-codes `strictClassLoading="true"` and always emits `sdkApiVersion`. A `1.0.0` connector loads and executes normally; the downgrade announces itself nowhere at runtime.

## Dependency rules

The SDK groupId is `com.boomi.connsdk` — not `com.boomi.connector` (that is the Gradle plugin id).

| Artifact | Bundle in archive? |
|---|---|
| `connector-sdk-api` | **Never** — always provided by the runtime; bundling causes class-loading conflicts |
| `connector-sdk-util` | Yes — not on the runtime classpath; omitting it fails at the first execution |
| `com.boomi.util:boomi-util` | **Yes** — arrives transitively from `connector-sdk-util`; do not exclude it |
| `connector-sdk-rest` / `connector-sdk-ws` | Yes, when used |
| Third-party JARs | Yes — strict class loading requires all third-party dependencies packaged |

**Declare every bundled dependency as `api`.** The connector plugin packages only `api` dependencies into `lib/`. One declared as `implementation`, the usual Gradle idiom, is left out of the archive with no warning: it is still on the compile and test classpath, so the build and local tests pass, and the gap surfaces only at first execution on a Runtime.

Do not include multiple versions of the same JAR. (Maven equivalent, best-effort: `<scope>provided</scope>` on `connector-sdk-api` alone, default scope for util/rest/ws.)

Avoid vendor Java SDKs (Stripe, AWS, ...) as dependencies: they typically use reflection internally, and a cloud runtime denies `setAccessible` with `ReflectPermission "suppressAccessChecks"`. Make HTTP calls directly. See gotchas.md, Cloud runtime restrictions, for the cloud denials.

`com.boomi.util:boomi-json-util` 1.2.x requires Jackson 2.10+, but its published POM declares no dependencies at all — Gradle and Maven both resolve it with no Jackson and no warning. Bundle Jackson explicitly: declare `jackson-databind` as `api`, which brings `jackson-core` and `jackson-annotations`. Every JSON splitter needs all three at runtime, `JsonRootArraySplitter` included, because `JsonSplitter`'s constructor initializes an `ObjectMapper`. Compilation passes with none of them, and the gap surfaces at first execution as a `NoClassDefFoundError`, which escapes `catch (Exception)`.

`boomi-json-util`'s `JsonPayloadUtil` gained a second coordinate at 1.2.2: through 1.2.1 it ships `com.boomi.connector.api.JsonPayloadUtil` alone, and from 1.2.2 that class and `com.boomi.util.json.JsonPayloadUtil` ship side by side. The older one still resolves, so a sample or snippet importing it compiles, but it carries `@Deprecated` — prefer `com.boomi.util.json` in new code.

## Class loading

Under `strictClassLoading="true"` the connector class loader serves the archive's `lib/` plus the runtime-provided `connector-sdk-api` — **nothing else on the runtime's shared classpath is reachable**, including every entry on the platform's "Third-Party Artifacts Provided by Boomi Runtime" list. Bundle everything; that list applies only in non-strict mode.

`boomi-util` is the case that catches people, because the docs describe it as runtime-provided and non-overridable. Excluding it passes the build, descriptor validation, upload, activation and deploy, then fails at the first execution with `NoClassDefFoundError: com/boomi/util/Args` thrown from inside an SDK base class the connector never referenced. The Gradle plugin bundles it by default; leave that alone.

Never take a runtime-provided library's version from that list. If a version matters, bundle it and pin it explicitly.

Non-strict mode is reachable only from a hand-maintained `connector-config.xml`; the Gradle plugin hard-codes `strictClassLoading="true"` and exposes no lever. Delegation there is parent-first, so for any class the runtime already provides, the runtime's copy wins and the bundled one is ignored — silently, with build, upload, activation and deploy all clean. To win that conflict, add `META-INF/com.boomi.Overrides`, one package prefix per line (`com.fasterxml.jackson.`); the runtime then loads exactly those prefixes child-first.

## Packaging requirements

- `.zip` containing `lib/**` (the connector jar and its bundled dependencies) and `META-INF/connector-config.xml`
- 40 MB maximum (larger needs Boomi approval)
- Target Java 8 bytecode — a separate choice from the build JDK; see the Gradle build section
- Strict class loading (`strictClassLoading="true"`) is the recommended mode for new connectors and handled automatically by the current Gradle plugin

Check archive contents before upload: `connector-sdk-api.jar` must NOT appear; `connector-sdk-util.jar`, `boomi-util.jar` (and `-rest`/`-ws` if used) MUST appear, and so must every third-party jar you declared. A missing third-party jar usually means it was declared as `implementation` rather than `api`.

## Current versions

Resolve current versions before scaffolding — do not trust pins found in older projects:

- SDK: `https://boomisdk.s3.amazonaws.com/releases/com/boomi/connsdk/connector-sdk-api/maven-metadata.xml` — read `<latest>`; the `<versions>` list is not sorted, so the last entry is not the newest
- Gradle plugin: `https://plugins.gradle.org/plugin/com.boomi.connector`
- SDK changelog: `https://developer.boomi.com/md/docs/Changelog/ConnectorsSDK/Changelog_connector_sdk.md`
- Packaging details and runtime-provided artifacts: `https://developer.boomi.com/md/docs/Connectors/GettingStartedWithConnectorDevelopment/Packaging_connector.md`
- Javadoc: `https://boomisdkjavadoc.s3.amazonaws.com/javadoc/<sdk-version>/index.html`; class pages are `.../javadoc/<sdk-version>/com/boomi/connector/api/<ClassName>.html`. Doc pages defer to the Javadoc for enum values without linking the class pages, so construct the URL.
