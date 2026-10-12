# Testing a Connector

## Contents
- Unit and functional tests — ConnectorTester
- When a local Runtime is worth it
- Archive download and side-loading
- Remote debugging
- Logs
- Listener connectors

## Unit and functional tests — ConnectorTester

`connector-sdk-test-util` provides `ConnectorTester` for exercising a connector without a runtime:

```java
ExampleConnector connector = new ExampleConnector();
ConnectorTester tester = new ConnectorTester(connector);
tester.setOperationContext(OperationType.GET, null, null, "SomeType", null);
List<SimpleOperationResult> expectedResults = ...;
tester.testExecuteGetOperation("37", expectedResults);
```

The package also covers browse, query, listen, and auth testing — see the `com.boomi.connector.testutil` Javadoc.

Drive **every** operation type the descriptor declares, not only the one under development. The example above drives a single GET; a suite shaped like it leaves a missing factory-method override on any other declared type to fail on that type's first execution, with every earlier checkpoint green (sdk_architecture.md, Connector class).

Pass `new ArrayList<>(...)` to every `execute*Operation` call. `ConnectorTester` takes ownership of the `List<InputStream>` — and of the `List<String>` of ids a delete is given — and mutates it while closing the response, so a fixed-size or immutable list fails from inside the utility. `Arrays.asList(...)` and `Collections.singletonList(...)` both fail, surfacing as `UnsupportedOperationException` or as `ConcurrentModificationException` out of `SimpleOperationResponse.finishInput`.

Either is thrown while the response closes and names only platform frames, so either can mask a genuine connector failure raised earlier in the same call — a missing factory-method override reads as a broken test utility.

A missing `finishPartialResult` throws nothing: the input's result becomes `FAILURE` with `input was lost during operation execution` and zero payloads. Assert the result status, not the absence of an exception.

Browse calls need `--add-opens java.base/java.lang=ALL-UNNAMED` when the test JVM is JDK 16 or later. `browseTypes()` and `browseProfiles(...)` serialize their results through JAXB, whose optimized accessor injects into `java.lang`; JDK 11 permits that by default, and JDK 16 made denial the default. Without the flag the first call throws `ExceptionInInitializerError` from `AccessorInjector.prepare`, caused by `InaccessibleObjectException`, and every later call in the same JVM degrades to `NoClassDefFoundError: Could not initialize class com.sun.xml.bind.v2.runtime.reflect.opt.Injector` — which points at the archive's `lib/` rather than at the test JVM's module flags (gotchas.md, Missing classes).

```groovy
test {
    jvmArgumentProviders.add({
        javaLauncher.get().metadata.languageVersion.canCompileOrRun(9) ? ["--add-opens", "java.base/java.lang=ALL-UNNAMED"] : []
    } as CommandLineArgumentProvider)
}
```

Keep the gate. A JDK 8 test JVM does not recognize the option and will not start: `:test` fails with `Unrecognized option: --add-opens` and `Process 'Gradle Test Executor 1' finished with non-zero exit value 1`, and reports no individual test, browse or not. The gate reads the test task's launcher, not `JavaVersion.current()` — that is the JVM Gradle itself runs on, which a toolchain can set apart from the test JVM.

The flag is test-harness only. The Runtime executes Java 8 bytecode with no module system, so nothing about the shipped connector changes.

`ObjectDefinition` content types serialize lowercase in browse output — `inputType="json"`, not the `ContentType` enum name — so an assertion written against the enum name fails. This is `ObjectDefinition`'s serialized attribute, unrelated to the descriptor's `inputType` (descriptor.md, `inputType` and `outputType`).

Distinct from the platform UI's process Test mode, which a human runs against a process and which this page does not cover. Test mode cannot run a listener process at all. For tracked-property values missing from its Connection Data pane, see gotchas.md, Tracked properties.

### Large responses

`SimpleOperationResponse` copies every output payload into a `byte[]` and keeps it, so a test whose output outgrows the heap OOMs inside the harness however well the connector streams — sometimes reported from `SimpleOperationResponse.close`, masking the original. To test streaming, subclass `SimpleOperationResponse`, drain each payload to a counter and pass `null` to super, which skips a null payload but still enforces the result contract. Then drive it through `executeOperation`:

```java
@Override
public void addPartialResult(TrackedData data, OperationStatus status, String code, String msg, Payload payload) {
    bytes += drain(payload);   // read payload.readFrom() to EOF, or payload.writeTo(counter) when that returns null
    super.addPartialResult(data, status, code, msg, null);
}
```

```java
SimpleTrackedData td = new SimpleTrackedData(0, inputStream);
response.addTrackedData(td);
tester.executeOperation(new SimpleUpdateRequest(new ArrayList<>(Collections.singletonList(td))), response, OperationType.EXECUTE);
```

Override `addResult` the same way for passthrough. Run the test JVM with a capped heap (`test { maxHeapSize = "64m" }`) and serve a response several times that size, generated lazily. A fixture in the test JVM shares that heap, and when the connector OOMs the fixture dies too and the test hangs on its socket, so run the fixture in a child JVM.

## When a local Runtime is worth it

ConnectorTester plus publishing covers an EXECUTE or QUERY connector against a reachable API. What a local **basic** Runtime (Atom) adds — the debugging and side-loading material below was established against that type, not a Molecule or Runtime Cloud:

| Capability | Verdict | Why |
|---|---|---|
| Run a **listener** connector | self-serve only | a cloud needs a worker you must request |
| Breakpoints in your own code | preferred | needs a reachable JVM debug port |
| Read what the connector logged | preferred | it lands in the container log, not the process log |
| Side-load an archive | escape hatch | see below |

Install one from the platform: Manage → Runtime Management → New Runtime.

A local Runtime is not a substitute for running on a cloud before release (gotchas.md, Cloud runtime restrictions).

## Archive download and side-loading

Browsing the connector or running a process that uses it downloads the archive; deploying a process does not. It lands at `<atom_installation_directory>/connector/<classificationType>/connector-<classificationType>-<versionId×100>-car.zip` — the directory name is exactly the `classificationType`, and the version number is multiplied by 100 (version 2 → `-200-`).

If that directory never materializes after a browse or an execution, the process ran somewhere else. An account usually has several environments, and tooling defaults (a workspace `.env`'s test atom id, for instance) often point at a shared or cloud Runtime rather than the local one — confirm which Runtime executes the process before concluding anything from the directory's contents.

A newly activated version is not downloadable straight away: the first request for its archive returns **403**, clearing roughly half an hour later. A 403 on first browse or execution means wait and retry — not re-publish, and not a permissions problem.

Replacing that archive in place is **not** a working iteration loop. The Runtime serves an exploded copy under `work/connector/` keyed by version and never re-extracts once it exists, so swapping the archive changes nothing, and so does a restart on its own. All three steps are needed together:

1. replace `<atom_installation_directory>/connector/<classificationType>/connector-<classificationType>-<versionId×100>-car.zip`
2. delete the directory `<atom_installation_directory>/work/connector/connector-<classificationType>-<versionId×100>-car.zip/`
3. restart the Runtime

A containerized Runtime is side-loadable on the same terms when the atom directory is a host bind mount.

Uploading a new version is one command and needs no host access.

## Remote debugging

Set the debug option as a custom container property in the platform's Properties panel, Custom tab. This is the durable route: it needs no host access and restarts the container itself.

```
-Xrunjdwp:transport=dt_socket,server=y,suspend=n,address=5005
```

`<atom_installation_directory>/bin/atom.vmoptions` is **generated from that same property set** and carries a `DO NOT EDIT` header. A hand-edit survives only until the Runtime next regenerates the file — a container property update, an upgrade, or anyone saving a Custom property — and is then dropped with no warning. Read it to see current state; do not treat an edit there as permanent.

Boomi's page shows a four-line form (`-Xdebug`, `-Xnoagent`, `-Djava.compiler=NONE` alongside `-Xrunjdwp`); only `-Xrunjdwp` has any effect, and the other three are harmless if already present.

Attach with the Runtime's own `<atom_installation_directory>/jre/bin/jdb`, which is version-matched to the container JVM, or any IDE's remote-JVM configuration (host `localhost`, port 5005). The port binds to loopback and needs no privileges to attach, even when the container runs as root.

A basic Runtime runs browse and process execution in the **same JVM**, so one debug port reaches both: Browser breakpoints hit during a GUI Import wizard, Operation breakpoints during an execution.

## Logs

What the connector logs to the container logger appears in `<atom_installation_directory>/logs/YYYY_MM_DD.container.log`, written continuously — nothing is held back until an error occurs. That file is world-readable and needs no privileges.

A downloaded process log carries a different set of messages; gotchas.md, Logging has which of the three loggers reaches which destination. Host access matters here because `input.getLogger()` output reaches neither the downloaded process log nor Process Reporting's per-document view — on a cloud Runtime as well as a local one. The per-document view shows the connector's output payload and the shapes that handled it, not what the connector logged.

## Listener connectors

On a Runtime Cloud a custom SDK listener runs **inside an execution worker** — that is what the SDK's Implementing Listen page is describing. Where the listener starts, its instance is named after the worker hosting it (`atomNN[worker-<id>]`); where there is no worker, the instance is a bare `atomNN` and errors.

Two consequences:

- A Runtime Cloud **with** an active execution worker runs a custom SDK listener normally, multi-tenant and Boomi-hosted included. Without one it refuses: *"This type of connector listener requires an active execution worker but none are enabled for this cloud attachment."* EXECUTE operations on the same connector build run on that cloud normally — the condition is specific to LISTEN.
- A local basic Runtime starts one with no configuration at all, and no worker to provision.

So a local Runtime is the only **self-serve** way to develop a listener connector: test mode blocks listener processes outright, and on a Boomi-hosted cloud an execution worker is a request to Boomi rather than a setting you can toggle.

Workers recycle, so a listener hosted in one is not indefinitely durable. The default TTL is 24 hours (`com.boomi.container.worker.ttl`) and a cloud may retire a worker sooner when load drops. The platform documents a replacement starting *on the next request* — which a timer-driven listener never generates. Whether such a listener survives a recycle is untested; treat a long-running listener on a worker-enabled cloud as unproven rather than assured.

**Listener Startup Mode** (`com.boomi.container.startListeners`) gates listeners by tenancy but is settable only on Private Runtime Clouds, so it plays no part above — it does not apply to a Boomi-hosted cloud or a local Runtime. A Boomi-hosted cloud defaults to `MULTITENANT_ONLY`; what would disqualify a listener under it is undocumented, and on a cloud you do not own there is no operator remedy.

Full page: `https://developer.boomi.com/md/docs/Connectors/Testing_connector.md`
