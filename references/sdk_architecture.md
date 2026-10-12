# Connector SDK Architecture

## Contents
- Thread safety
- Connector class
- Operations
- Results
- Browser
- Context and properties
- Listen operations

## Thread safety

| Class | Thread-safe required | Lifecycle |
|---|---|---|
| Connector | **Yes** | Instantiated once (reflectively, via public no-arg constructor); shared across accounts and threads |
| Browser | No | Created per browse request |
| Operation | No | Created per execution, single-threaded |
| Connection | No | Created per operation |

Never cache account-specific state on the Connector; use `ConnectorContext` for user-specific caches.

## Connector class

Extend `BaseConnector` and override **one factory method per operation type the descriptor declares**. `createOperation` dispatches on `context.getOperationType()` to a separate factory per type, and every default factory throws a message-less `UnsupportedOperationException`:

| Factory method | Operation type | Request type |
|---|---|---|
| `createExecuteOperation` | EXECUTE | `UpdateRequest` |
| `createCreateOperation` | CREATE | `UpdateRequest` |
| `createUpdateOperation` | UPDATE | `UpdateRequest` |
| `createUpsertOperation` | UPSERT | `UpdateRequest` |
| `createGetOperation` | GET | `GetRequest` |
| `createDeleteOperation` | DELETE | `DeleteRequest` |
| `createQueryOperation` | QUERY | `QueryRequest` |
| `createBrowser` | (browse) | `BrowseContext` |

One operation class can back several factories — the four update-style types share `BaseUpdateOperation` and `UpdateRequest`, so a single class routing on `context.getOperationType()` is fine.

A missing override compiles, validates, uploads, activates and deploys with every checkpoint green, then throws from `BaseConnector.create<Type>Operation` on the first execution of that type. Only executing that type catches it — exercise every declared type under `ConnectorTester` (test_connector.md, Unit and functional tests).

LISTEN is absent from that dispatch and reaches `createOperation`'s own default — the same message-less exception, one frame higher, from `createOperation` rather than from a named factory. Listen connectors implement `ListenConnector.createListenOperation` instead (Listen operations, below).

`BaseConnector.createBrowser()` and `RestConnector.createBrowser()` both throw `UnsupportedOperationException` unconditionally — always override, and never call super. See rest_framework.md for the rest of that framework's contract.

Development order: descriptor → Connector class → Operations → Browser.

## Operations

| Type | Base class | Input | Loop pattern |
|---|---|---|---|
| EXECUTE/CREATE/UPDATE/UPSERT | `BaseUpdateOperation` | `ObjectData` | `for (ObjectData in : request)` |
| GET | `BaseGetOperation` | `ObjectIdData` | `request.getObjectId()` |
| DELETE | `BaseDeleteOperation` | `ObjectIdData` | `for (ObjectIdData in : request)` |
| QUERY | `BaseQueryOperation` | `FilterData` | `request.getFilter()` |
| LISTEN | `BaseListenOperation` | n/a | event-driven |

The two `ObjectIdData` rows are fed from different sources, and both drop their input silently when that source is wrong. See gotchas.md, Where GET and DELETE ids come from.

Store needed property values as instance fields in the constructor — accessing context later in the execution is unreliable:

```java
protected MyOperation(OperationContext context) {
    super(context);
    _apiKey = context.getConnectionProperties().getProperty("apiKey");
}
```

Operations that bind whole input documents to memory (`readTree(input.getData())`) should extend `SizeLimitedUpdateOperation` / implement `executeSizeLimitedUpdate` — the SDK then rejects oversized input documents as `APPLICATION_ERROR` before your code runs. It does not bound a response; see Large payloads, below.

## Results

| Method | Use |
|---|---|
| `addResult(input, status, code, msg, payload)` | One result per input |
| `addEmptyResult(input, status, code, msg)` | No payload (GET not found, DELETE success) |
| `addPartialResult(input, status, code, msg, payload)` | Multiple results per input (QUERY, a split response, pages) — MUST end with `finishPartialResult(input)`, or the input counts as lost and every partial payload is dropped |
| `addCombinedResult(inputs, status, code, msg, payload)` | One result covering a `List<ObjectData>` of inputs (first argument required) |

Rules:
- Update-style operations must add exactly one result per input document — no silent skips.
- `OperationStatus`: `SUCCESS`, `APPLICATION_ERROR` (business error), `FAILURE` (technical).
- **Scope the failure before choosing how to report it.** Throw `ConnectorException` (with the HTTP status and response body) only for failures that invalidate the whole execution — authentication, unreachable host, invalid configuration. For a failure attributable to one document, call `addResult(input, APPLICATION_ERROR|FAILURE, code, msg, payload)` and continue the loop. **Do not throw.**
- Never swallow a failure *silently* — always record it against its document. That is a different instruction from "always throw".

Throwing on a per-document error is worse than it looks. On a 3-document batch failing at index 1:

| Approach | Documents entered | Documents out |
|---|---|---|
| `addResult(..., FAILURE)` | all 3 | **2** (1 failed, 2 succeeded) |
| `throw ConnectorException` | only 0 and 1 | **0** |

Index 2 is never presented to the connector at all, and the SUCCESS result already recorded for index 0 is discarded. The shape reports `Unexpected error executing process`. A one-document problem becomes a zero-documents-out process failure.

Violating the one-result-per-document rule produces one of two errors:

| Mistake | Error | Raised as | Shape status |
|---|---|---|---|
| **No result** for a document | `Input was lost during operation execution` | no Java exception; detected after the loop completes | `Shape executed with errors` |
| **Two results** for a document | `Input <id> was not outstanding (already marked as finished)` | `java.lang.IllegalArgumentException`, at the second call | `Shape executed successfully` |

The duplicate case is the more deceptive: the connector shape reports success, and the failure surfaces only in the execution's document-error tally.

### Large payloads

Emit each record or page as it is read; never collect a response, or its pages, before emitting. The splitters in `com.boomi.util.json.splitter` stream a JSON array one element at a time. Adapted from the `SplitJsonResponseOperation` sample (`./gw connectorSamples`):

```java
for (ObjectData input : request) {
    InputStream inputData = input.getData();
    JsonSplitter splitter = null;
    try {
        InputStream outputData = /* HTTP response entity stream, unread */;
        splitter = new JsonRootArraySplitter(outputData);
        for (Payload payload : splitter) {
            response.addPartialResult(input, OperationStatus.SUCCESS, "OK", "Success", payload);
        }
    } catch (Exception e) {
        input.getLogger().log(Level.SEVERE, "unable to process input", e);
        // keeps every SUCCESS document already added
        response.addPartialResult(input, OperationStatus.APPLICATION_ERROR, "-1", "unable to process input", null);
    } finally {
        IOUtil.closeQuietly(inputData, splitter);   // closing the splitter closes the response stream
    }
    response.finishPartialResult(input);
}
```

- `JsonRootArraySplitter` — the body is an array. Anything else throws `An array was expected at the root of the document.`
- `JsonArraySplitter(stream, "data")` — an array that is a field of the root object. The argument is a field name, not a path or pointer, and an array nested deeper is not found. A missing field throws `Field <name> with the content array was not found in the document` from the first `hasNext()`, after the whole body has been read. The five-argument constructor's `failIfArrayFieldNotFound=false` turns that into zero documents and no error.
- A malformed, truncated, or dropped response throws from `hasNext()` inside the `try`, so the catch above records it and the documents already emitted survive.
- **Paging:** one `addPartialResult` per page, or split each page's stream as above, then a single `finishPartialResult`. Collecting pages in a list OOMs once their total outgrows the heap. A page buffered as a `String` costs several times its size, so cap pages with the API's page-size parameter or split them.
- **Passthrough** (one document per response): `addResult(input, SUCCESS, code, msg, PayloadUtil.toPayload(outputData))`, with `outputData` declared before the `try` and closed in `finally` (the official `DirectInputStreamSampleOperation`).
- The splitters ship in `boomi-json-util`, not `connector-sdk-util`, and need Jackson bundled (build_and_package.md, Dependency rules).
- ConnectorTester keeps every output payload in memory, so a large-response test needs a draining response (test_connector.md).

## Browser

Extend `BaseBrowser`; implement `getObjectTypes()` and `getObjectDefinitions(objectTypeId, roles)`. Honor the requested `ObjectDefinitionRole` values (INPUT vs OUTPUT) when building definitions.

`ContentType` (`JSON`, `XML`, `BINARY`, `NONE`) is the dispatch key for which schema getter profile import reads — `JSON` → `setJsonSchema(String)`, `XML` → `setSchema(Element)` — so it must match the setter you called. Set the one matching the definition's role (`setInputType` for INPUT, `setOutputType` for OUTPUT); the other is ignored. Both **default to `xml`**, so a JSON schema with the content type left unset fails import with a message-less `java.lang.NullPointerException` and no profiles.

For a JSON schema `setElementName()` is **mandatory** (the Javadoc's "Optional" holds only for the XML path) and parsed as an RFC 6901 pointer — `/definitions/TypeName`, leading slash required. Unset → `NullPointerException: input cannot be null`; bare name → `illegal pointer: expected a slash to separate tokens`. There is no fallback to a root `$ref`, and the schema's root shape is otherwise irrelevant (root `$ref` and inline root produce identical profiles). The generated profile's root element name is the pointer's last segment, not the object type id.

Profile components are named `<connector displayName> <objectType label> <operationType> <Request|Response>`, suffixed ` 2`, ` 3` … on collision — repeated imports accumulate duplicates rather than replacing.

Packages differ and mismatches are compile errors: `BaseConnector`, `BaseBrowser`, `BaseUpdateOperation`, `ResponseUtil` in `com.boomi.connector.util`; `ObjectDefinition`, `ObjectDefinitionRole`, `ContentType`, `ObjectTypes` in `com.boomi.connector.api`.

For CUSTOM test connection, the Browser also implements `ConnectionTester.testConnection()` — returning normally is the only pass signal, throwing `ConnectorException` the only failure signal. For an API with no readable surface to probe, see descriptor.md, Test connection.

### Publish one output shape

One import binds one Response Profile, so an endpoint whose response varies by input — a different JSON shape per mode, or JSON for one caller and a stream for another — has no schema a profile can represent. Normalize the variants into a single shape in the connector and publish that shape from `getObjectDefinitions()`; downstream maps then bind once and keep working as the response varies.

Give the normalized shape a declared place for variants it does not recognize rather than dropping them. A variant that vanishes silently keeps API drift invisible until a map is already producing wrong output.

### Restricting QUERY field selection — `FieldSpecField`

`allowFieldSelection="true"` plus a browsed schema is **sufficient on its own** for a fully populated Fields tab, with every schema property filterable and sortable. Field specs do not populate that tab — the schema does. **Field specs RESTRICT it.** Declare none and everything is permitted; declare them and the panel narrows to exactly what you mark.

```java
FieldSpecField spec = new FieldSpecField();
spec.setName("message");
spec.setType("string");
spec.setFilterable(Boolean.TRUE);
spec.setSortable(Boolean.TRUE);
spec.setSelectable(Boolean.TRUE);

definition.withFieldSpecFields(spec, /* … */);   // omit entirely => everything permitted
```

Use the typed API, not a schema annotation — a `boomi_fieldSpec` annotation in the JSON schema has no effect. Requires `<operation types="QUERY" allowFieldSelection="true">` and a `<queryFilter>` ordered before `<browseConfiguration>` (descriptor.md, Operations). At runtime `OperationContext.getSelectedFields()` reports what the user chose.

## Context and properties

- `OperationContext` / `BrowseContext` / `ConnectorContext` carry configuration into constructors.
- `getConnectionProperties()` = connection screen values; `getOperationProperties()` = operation screen values.
- `PropertyMap` getters: `getProperty(key[, default])` (String), `getLongProperty(key, default)`, `getBooleanProperty(key, default)`. There is no `getIntegerProperty` / `getDoubleProperty` — use `getLongProperty` and cast. **`getProperty` is safe only for `string` and `password` fields**; every other declared type must be read with its typed getter. A `type="boolean"` field read with `getProperty` throws `java.lang.ClassCastException: class java.lang.Boolean cannot be cast to class java.lang.String`, and numeric fields behave the same. The presentation is the hazard: from a Browser this reaches the user as `Browse operation failed; Caused by: Connection Failed`, with the `ClassCastException` only in the third `Caused by` — which sends people debugging credentials and networking when the real cause is a getter mismatch in connector code.

  ```java
  boolean flag = getContext().getConnectionProperties()
          .getBooleanProperty("myFlag", Boolean.FALSE).booleanValue();
  ```
- `getCustomProperties(id)` reads a `customproperties` field; it returns an empty map, not null, when unset.

### Reading overrideable fields

For a field the descriptor marks `overrideable="true"`, read `input.getDynamicOperationProperties()` — it is pre-seeded with the component's static value and already reflects any per-document override from the process step. Reading `getOperationProperties()` instead returns the static component value only, silently ignoring every override.

The two APIs return different types, which is not guessable and fails to compile if assumed symmetric:

```java
DynamicPropertyMap dynOp  = input.getDynamicOperationProperties();  // overrideable operation fields
Map<String,String> dynDoc = input.getDynamicProperties();           // descriptor <dynamicProperty> values
```

`DynamicPropertyMap` does not extend `PropertyMap`. It declares only the String `getProperty` forms and `getCustomProperties` — no typed getters, and `getProperty` returns `String`, so the `ClassCastException` above does not apply. An overrideable `boolean` or `integer` field is parsed by hand; the two-argument form substitutes the default when the value is blank.

```java
boolean async   = Boolean.parseBoolean(dynOp.getProperty("async", "false"));
long    timeout = Long.parseLong(dynOp.getProperty("timeoutMs", "30000"));
```

### Validate your own inputs

The platform never checks component attributes against the descriptor — undeclared field ids, object type ids and custom operation types all arrive verbatim, and mismatches are invisible outside the Integration GUI. The connector is the only component positioned to catch them:

```java
String customType = getContext().getCustomOperationType();   // may be null; never valueOf() it
if (customType != null && !KNOWN_TYPES.contains(customType)) {
    throw new ConnectorException("Unknown operation type: " + customType);
}
```

Logging `getOperationProperties().keySet()` at operation start is the cheapest version of the same idea — it makes a misspelled field id visible in the process log instead of silent.

## Listen operations

- **Managed** (`BaseListenConnector` + `BaseListenManager`): the manager owns a shared expensive connection; operations register handlers against it.
- **Unmanaged** (`UnmanagedListenOperation`): the operation owns its connection.
- **Polling** (`BasePollingManager` + `BasePollingOperation`): `doPoll()` runs each interval; use `PersistedConnectorCache` (`getPersistedProperty`/`setPersistedProperty`) for watermarks that survive Atom restarts — it throws `UnsupportedOperationException` when persistence is disabled, so wrap defensively.
- **Singleton**: implement `SingletonListenOperation` and `isSingleton()` to run on one cluster node only.
- `stop()` MUST throw `ContainerStoppingException` (from `com.boomi.connector.api`) — otherwise the Atom hangs on shutdown waiting for the listener.
- Submit events via `listener.submit(payload[, SubmitOptions])`; check `listener.isStopping()` first. Batch with `listener.getBatch()` / `IndexedPayloadBatch`.

Javadoc for exact signatures: `https://boomisdkjavadoc.s3.amazonaws.com/javadoc/<sdk-version>/index.html`

For idiom rather than signatures, read the official samples first: `./gw connectorSamples` writes the official sample classes under `build/generated/src/connectorSamples/`, covering operations, browsers, listeners and polling. For a signature in the version you actually resolve, `javap -cp <jars> <class>` beats both — it is offline and cannot disagree with the build. Note that a sample compiling in place does not mean it compiles once copied into a connector: see build_and_package.md, Reading the official samples first.
