# Runtime Gotchas

## Contents
- Cloud runtime restrictions
- Missing classes
- Streams and memory
- Logging
- Operation pitfalls
- Where GET and DELETE ids come from
- Silent credential omission — API key in a cookie
- A GUI save materializes every declared field
- Tracked properties

## Cloud runtime restrictions

Cloud runtimes run under `com.boomi.security.ExtendedSecurityManager`:

| Attempt | Result |
|---|---|
| Write outside the runtime directory (e.g. `$HOME`) | DENIED — `java.io.FilePermission "…" "write"` |
| Write inside the runtime's `work/` | permitted |
| Read an environment variable | DENIED — `RuntimePermission "getenv.<name>"` |
| Spawn a process | DENIED — `FilePermission "<<ALL FILES>>" "execute"` |
| `setAccessible` on a non-public member | DENIED — `ReflectPermission "suppressAccessChecks"` |
| `Class.getProtectionDomain()` (to read a class's CodeSource) | DENIED — `RuntimePermission "getProtectionDomain"` |
| Walk past the connector class loader to its parent | DENIED — `RuntimePermission "getClassLoader"` |
| Open an outbound TCP socket on a non-HTTP port | permitted |
| Read the runtime install directory | permitted |
| REST-framework `getHttpClient()` executed without `getHttpContext()`, against a server that answers with a 401 challenge (the client falls back to system credentials) | DENIED — `NetPermission "requestPasswordAuthentication"`, thrown from `execute()`; locally the same code returns a plain 401 |

- **A local Runtime has no SecurityManager at all** — `System.getSecurityManager()` returns `null`, not a laxer policy, and the container may run as root. Every denial above passes locally, so local testing cannot surface any of them. Execute on a cloud runtime before release.
- **No vendor SDKs.** Third-party API SDKs (Stripe, AWS, ...) typically use reflection internally and hit the `setAccessible` denial above. Make HTTP calls directly instead.
- **Confine writes to the runtime's working directory.** Use `AccountConfig` for account-specific files; the configured temp directory may be used but must be cleaned up.
- **A denial is a catchable exception.** `AccessControlException` is an ordinary exception, so a broad `catch (Exception)` turns a policy violation into silently missing behavior and the execution still reports COMPLETE. Let it propagate, or log it explicitly.
- Full permission list: `https://developer.boomi.com/md/docs/Connectors/ConnectorDevelopmentReference/Connector_cloud_permissions.md`

## Missing classes

A dependency left out of the archive surfaces only at the first execution — build, descriptor validation, upload, activation and deploy all pass. The same missing JAR reports two different ways: `ClassNotFoundException` with a dotted name from a reflective lookup, `NoClassDefFoundError` with a slashed name from a compiled call site. Triage that keys on one misses the other.

`NoClassDefFoundError: Could not initialize class` followed by a dotted name is not a missing class. The class resolved, but its static initializer already threw earlier in the same JVM, and every later reference reports this instead of the original failure. Nothing in the archive's contents explains it — find the first `ExceptionInInitializerError` in the JVM's output; its cause is the real failure (test_connector.md, Unit and functional tests).

The message names only the class. The `... not visible from class loader ... ConnectorManager$ConnectorClassLoader@...` wording in the platform docs does not appear, so a class-loading failure is indistinguishable at a glance from an ordinary missing dependency. What to bundle is in build_and_package.md, Class loading.

To find out where a class actually came from, enumerate the connector class loader's own URLs — a class from the archive resolves through that loader, one from the runtime does not. A connector class reaching its own loader needs no permission; only reaching past it to the parent is denied. On a cloud runtime this is the only route: the two cheaper checks, `getProtectionDomain()` and walking to the parent loader, are both denied.

## Streams and memory

Any `InputStream` from `input.getData()` or an HTTP response goes to a splitter or `PayloadUtil.toPayload(InputStream)` — never to a `String`, a byte array, or a log statement. Handing the stream to a tree-binding parser does not stream: `readTree(entity.getContent())` OOMs on a large response exactly like `EntityUtils.toString`, before emitting a single document.

```java
// WRONG — whole body in heap
String body = EntityUtils.toString(entity);
byte[] bytes = EntityUtils.toByteArray(entity);
JsonNode tree = MAPPER.readTree(entity.getContent());

// RIGHT — stream straight through
Payload p = PayloadUtil.toPayload(entity.getContent());
```

Splitting a response into documents, paging, and passthrough: sdk_architecture.md, Large payloads. `connectordev-doctor.sh <project-dir>` flags buffering calls in `src/main/java`.

- `OutOfMemoryError` is an `Error`, not an `Exception`: it escapes `catch (Exception)`, so no per-document result is recorded and the whole execution fails.
- Close every stream in `finally` (`IOUtil.closeQuietly(...)`) or try-with-resources — an exception before `close()` leaks it. A leaked HTTP response stream keeps its pooled connection: Apache HttpClient 4.5 allows 2 per route by default, so the third request on that route blocks, indefinitely without a `connectionRequestTimeout`.
- Reuse a single `ObjectMapper` (static singleton); never `new ObjectMapper()` per call.

## Logging

- Never `System.out.println` or `e.printStackTrace()` — use one of the three `java.util.logging` loggers below.
- **Three loggers, three destinations, not interchangeable.** `input.getLogger()` (document log) is documented as surfacing in the Build tab's test-mode output; `OperationResponse.getLogger()` (operation log) is what a downloaded execution log carries; `Logger.getLogger(name)` goes to the container log. Do not rely on the document logger to reach the platform: its output is absent from a downloaded process log **and** from Process Reporting's per-document view, on cloud and local Runtimes alike — that view shows the connector's output payload and the shapes that handled it, not what the connector logged. Log to the operation logger whatever you expect to debug from a log you pull, and to the container log whatever you need when you have host access.
- Never log document content or credentials: it exposes customer data, and reading the stream consumes it.
- **Pre-format every message.** Boomi's process-log handler does not run `MessageFormat`, so `logger.log(level, "id={0}", value)` emits the literal `{0}` and drops the argument — no error, just a useless line. Concatenate or `String.format` instead. This one bites late: an ordinary local JUL handler substitutes normally, so the same code logs correctly off-platform and silently loses every value once deployed.

## Operation pitfalls

- `context.getCustomOperationType()` can return null even when the descriptor defines `customTypeId` (the operation component may omit it) — default defensively instead of calling `valueOf` on it.
- Update-style inputs (EXECUTE/CREATE/UPDATE/UPSERT) arrive in whatever format the process sends — JSON, XML, text, or binary — unconverted and unenforced; parse what your connector documents. GET and DELETE are the exception, below.
- Honor `ObjectDefinitionRole` (INPUT vs OUTPUT) when building object definitions, and set the role-matching `ContentType` on each. Profile import doesn't defend its inputs: an unset content type or missing `setElementName` throws a raw `NullPointerException` and creates nothing (sdk_architecture.md, Browser).

## Where GET and DELETE ids come from

GET and DELETE look symmetric in the SDK and are not. Neither takes its object id from the connector's own input document the way an update-style operation takes its payload, and both have a failure mode that emits nothing and reports success.

| | GET | DELETE |
|---|---|---|
| SDK input | `request.getObjectId()` — one `ObjectIdData` | `for (ObjectIdData in : request)` |
| Id source | the connector step's `<parametervalue>` | the input documents, parsed by the platform |
| Step parameters | required | rejected when no parameter profile is configured |
| No id resolved | dropped, execution green (throws if the document is not XML) | dropped, execution green |

**This describes native SDK operations** — plain `request.getObjectId()` or `ObjectIdData` iteration, not the REST or OpenAPI-DSL frameworks — taking a single id, with no request profile on the operation. Every failure below is thrown in platform frames before the connector is entered, so none of it varies with the target API.

**GET reads the step parameter and never opens the document.** The step needs a `<parametervalue>` carrying the id. A single `ObjectId` parameter needs no `parameter-profile` attribute — a plain `<parameters>` block is the whole of it, and the platform does not add one on save or on deploy. Authoring the step is boomi-integration territory (its `references/steps/custom_connector_step.md`); the shape is:

```xml
<connectoraction actionType="{customTypeId-or-operationType}" connectionId="{connection-guid}"
                 connectorType="{connector-type}" operationId="{operation-guid}">
  <parameters>
    <parametervalue elementToSetId="0" elementToSetName="ObjectId" key="0" valueType="static">
      <staticparameter staticproperty="{object-id}"/>
    </parametervalue>
  </parameters>
  <dynamicProperties/>
</connectoraction>
```

With the parameter set the document is never read, so its format is irrelevant: the same step completes identically on XML, JSON and plain text.

Omit it and the document is dropped — one in, zero out, execution green, and the operation never entered. An empty `<parameters/>` and no `<parameters>` element at all are indistinguishable at runtime; the platform stores whichever you write. A connector that appears dead on GET is usually a step missing its parameter, not connector code.

**A parameter-less GET throws only when the input is not well-formed XML.** With no id parameter the platform falls back to SAX-parsing the document looking for ids, so JSON dies in the parser and surfaces as `ConnectorException: Object IDs are required. To provide the ID, set ID parameters or use input documents.` with `Caused by: Content is not allowed in prolog` — named against the step and catchable.

What decides between that exception and the silent drop is the document, not the missing parameter: the same step fed well-formed XML goes green and emits nothing, whether or not the XML carries an id-shaped element. Treat a green GET step as unproven until a response document comes out of it. The message's second route is not one to follow — no document shape supplies an id to a GET, `<ObjectIds><ObjectId>id</ObjectId></ObjectIds>` included.

**DELETE parses ids out of the input documents, above the connector boundary.** Non-XML input throws before `executeDelete` runs — every frame in the trace is a platform class, none is the connector's:

```
com.boomi.connector.ConnectorException: Object IDs are required. To provide the ID, set ID parameters or use input documents.
	at com.boomi.connector.generic.GenericGetConnectorAction.parseIds
	at com.boomi.connector.generic.GenericDeleteConnectorAction$DeleteDataParser.parseData
```

So a DELETE cannot document a JSON id format, and the connector cannot catch or improve that failure. Well-formed XML clears the error but is not by itself sufficient: both `<ObjectIds><ObjectId>id</ObjectId></ObjectIds>` and a bare `<ObjectId>id</ObjectId>` parse cleanly, yield zero ids, and are dropped as silently as a parameter-less GET. Don't hand-write the shape — start from the request profile the Import wizard generates for the DELETE operation.

Giving a DELETE step the parameter block GET requires throws `Unable to invoke DELETE action for <operation name>, parameters have been defined but no parameter profile has been configured` — at execution time only; the push and the deploy both succeed. DELETE routes step parameters through `BaseConnectorAction.parametersToReadStore`, which needs the profile to interpret them, and GET never calls it. The profile therefore matters on DELETE only when the step carries parameters; a DELETE step with none needs no profile.

## Silent credential omission — API key in a cookie

REST framework, `apiKeyLocation=COOKIE` with no `cookieScope` connection field: the request goes out **with no API key** and the shape reports success. No error, no warning, no log line. Against a real API this presents as an inexplicable 401/403 with nothing pointing at `cookieScope`. Set `cookieScope` whenever `apiKeyLocation=COOKIE` (rest_framework.md).

Compounding this: with `returnApplicationErrors="true"` on the Operation component — a common setting — a 401 produces an **empty document on a green execution**, the shape logging "executed successfully". Set it to `false` while debugging authentication, or the failure is invisible.

## A GUI save materializes every declared field

A connection created over the API carries only the fields you specified. After one GUI save it carries **every field the descriptor declares**, and the platform supplies values for fields nobody touched — choosing the **first `<allowedValue>`** for any list field with no `<defaultValue>`. A connection pushed with five fields can come back carrying twelve, having silently gained entries like `apiKeyLocation="REQUEST_HEADER"` and `cookieScope="GLOBAL"`.

This interacts badly with the REST framework's blank-means-`NONE` rule: a connection deliberately left blank can acquire real authentication behavior just by being opened and saved. Design descriptors so the first `allowedValue` of every list field is the safe default. Browsing does not save the connection — only an explicit save does.

## Tracked properties

Test mode here is the platform UI's process Test mode, which a human runs against a process using the connector — not ConnectorTester (test_connector.md).

- **Its Connection Data pane does not populate tracked-property values.** The pane lists the `<trackedProperty>` labels with every row empty — expected rendering, not a failed `setTrackedProperty`. The values surface in Process Reporting.
- To confirm one is being set, have them read the same id as a document property in-process — Notify, Set Properties, or the Get Document Property map function — in the same Test-mode run. If it shows up there, the connector is fine.

If it doesn't show up there either, work through these in order:

- **id match** — `<trackedProperty id="...">` must match the Java constant character-for-character; a mismatch fails silently.
- **pattern** — `createMetadata()` → `setTrackedProperty()` → `toPayload(..., metadata)` → `addResult`.
- **metadata-carrying payload** — confirm the `toPayload` overload returns `ExtendedPayload`, not a plain `Payload`.
- **`trackedDocument`** — a red herring; the EXECUTE default is already `request` (descriptor.md, Operations).
