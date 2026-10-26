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

`BaseConnector.createBrowser()` and `RestConnector.createBrowser()` both throw `UnsupportedOperationException` unconditionally — override whenever an operation is browse-enabled (`supportsBrowse` defaults to `true`) or `<testConnection>` is declared, and never call super. See rest_framework.md for the rest of that framework's contract.

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
| `addEmptyResult(input, status, code, msg)` | No document (GET not found, DELETE success). `addResult` with a `null` payload sends one empty document instead |
| `addPartialResult(input, status, code, msg, payload)` | Multiple results per input (QUERY, a split response, pages) — MUST end with `finishPartialResult(input)`, or the input counts as lost and every partial payload is dropped |
| `addCombinedResult(inputs, status, code, msg, payload)` | One result covering a `List<ObjectData>` of inputs (first argument required) |

`ResponseUtil` (`com.boomi.connector.util`) wraps these. `addResultWithHttpStatus`, `addEmptyResultWithHttpStatus` and `addPartialResultWithHttpStatus` derive the status from an HTTP code: 2xx `SUCCESS`, 300–499 `APPLICATION_ERROR`, anything else `FAILURE`. `addExceptionFailure(response, input, e)` records `FAILURE` with the exception's message and logs it to the operation logger.

A non-`SUCCESS` partial sets the status of the whole input: the `SUCCESS` partials already emitted for it fail with it and do not continue past the next shape. The exception is an `APPLICATION_ERROR` partial on an Operation with `returnApplicationErrors="true"`, which keeps them and adds the error partial as one more document (empty for a `null` payload).

Rules:
- Update-style operations must add exactly one result per input document — no silent skips.
- `OperationStatus`: `SUCCESS`, `APPLICATION_ERROR` (business error), `FAILURE` (technical).
- **Scope the failure before choosing how to report it.** Throw `ConnectorException` (with the HTTP status and response body) only for failures that invalidate the whole execution — authentication, unreachable host, invalid configuration. For a failure attributable to one document, record it against that document (`addResult` or the `ResponseUtil` helpers) and continue the loop. **Do not throw.**
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
| **Two results** for a document | `Input <id> was not outstanding (already marked as finished)` | logged at SEVERE by the platform; the second call returns normally, so the connector's `catch` never sees it | `Shape executed successfully` |

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
        response.getLogger().log(Level.SEVERE, "unable to process input", e);
        // FAILURE fails this input's earlier partials whatever returnApplicationErrors is (Results)
        response.addPartialResult(input, OperationStatus.FAILURE, "-1", "unable to process input", null);
    } finally {
        IOUtil.closeQuietly(inputData, splitter);   // closing the splitter closes the response stream
    }
    response.finishPartialResult(input);
}
```

- `JsonRootArraySplitter` — the body is an array. Anything else throws `An array was expected at the root of the document.`
- `JsonArraySplitter(stream, "data")` — an array that is a field of the root object. The argument is a field name, not a path or pointer, and an array nested deeper is not found. A missing field throws `Field <name> with the content array was not found in the document` from the first `hasNext()`, after the whole body has been read. The five-argument constructor's `failIfArrayFieldNotFound=false` turns that into zero documents and no error.
- A malformed, truncated, or dropped response throws from `hasNext()` inside the `try`, so the catch above records it against the input.
- **Paging:** stream each page's elements (the loop above, or the nested-array recipe below), then fetch the next page, then a single `finishPartialResult` after the last. Collecting pages in a list OOMs once their total outgrows the heap, and a page-size cap bounds one page, not the total. A page buffered as a `String` costs several times its size.
- **Output that needs every record** (a client-side sort, an aggregate; descriptor.md, Operations): enforce a record ceiling in code and fail past it with a message naming the ceiling.
- **A record built in code** (a `JsonNode` or a POJO) goes out as `JsonPayloadUtil.toPayload(record)`, which streams it to the output; pass your own `ObjectMapper` as the second argument if the POJO has non-public members. `toPayload(mapper.writeValueAsString(record))` holds the whole string and its encoded bytes first.
- **Passthrough** (one document per response): `addResult(input, SUCCESS, code, msg, PayloadUtil.toPayload(outputData))`, with `outputData` declared before the `try` and closed in `finally` (the official `DirectInputStreamSampleOperation`).
- The splitters and `JsonPayloadUtil` ship in `boomi-json-util`, not `connector-sdk-util`, and need Jackson bundled (build_and_package.md, Dependency rules).
- ConnectorTester keeps every output payload in memory, so a large-response test needs a draining response (test_connector.md).

An array below the root's first level — `data.orders.items`, and every GraphQL response — is out of the splitters' reach. Walk to it with a Jackson `JsonParser` and bind one element at a time. The two helpers are yours to write; they are not in the SDK or `boomi-json-util`:

```java
/**
 * Positions p on the START_ARRAY at path (field names from the root), skipping other fields with skipChildren();
 * false if a step is absent, null, or not an object, or the last is not an array.
 * A non-empty errorField at the root level (only) passed on the way throws.
 */
static boolean advanceTo(JsonParser p, String errorField, String... path) throws IOException;

/**
 * Reads on to the end of the document from wherever p stopped, at any depth; returns the named field's value,
 * matching only at the root level (getParsingContext().getParent().inRoot()), or null.
 */
static JsonNode rootFieldAfter(JsonParser p, String name) throws IOException;

// per page, inside the try of the loop above: holds one element, never the page
try (JsonParser p = MAPPER.getFactory().createParser(outputData)) {
    if (advanceTo(p, "errors", "data", "orders", "items")) {
        for (JsonToken t = p.nextToken(); t != JsonToken.END_ARRAY; t = p.nextToken()) {
            if (t != JsonToken.START_OBJECT) {
                p.skipChildren();
                continue;
            }
            JsonNode element = p.readValueAsTree();
            response.addPartialResult(input, OperationStatus.SUCCESS, "200", "OK", JsonPayloadUtil.toPayload(element));
        }
    }
    failOnErrors(rootFieldAfter(p, "errors"));   // throws ConnectorException on a non-empty array
}
```

- The error member — GraphQL's `errors` — can come before or after the data. One after the array throws only once the records are emitted, so the throw lands in the loop's catch, whose `FAILURE` partial fails them with it (Results). Pass `null` as `errorField` for an API with none.
- `advanceTo` returning `false` with no error covers an absent path and a `null` at any step. Decide which means "no records" for the API, and treat the rest as an error.
- Skip elements that are not objects, such as `null` items in a GraphQL list; a loop that stops at the first one drops every record after it.
- A filter the endpoint cannot apply is evaluated on `element` before emitting (descriptor.md, Operations).
- `JsonPayloadUtil` is `com.boomi.util.json.JsonPayloadUtil`, in `boomi-json-util` with the splitters.

## Browser

Extend `BaseBrowser`; implement `getObjectTypes()` and `getObjectDefinitions(objectTypeId, roles)`. Return one definition per requested role, in the order of `roles`. The platform binds `definitions[i]` to `roles[i]` by position and never checks: a reversed list imports cleanly with no profiles — or, when each definition sets both content types, with Request and Response silently swapped — and with one missing, the rest shift a slot and the last role gets no profile.

For DELETE the INPUT schema is ignored; the request profile is always the platform's (gotchas.md, Where GET and DELETE ids come from).

Past `AtomConfig.getMaxNumberObjectTypes()` (500) types, the browse does not fail as the Javadoc says: the wizard lists only the first 500 in returned order, with a warning. The wizard's Filter never reaches the Browser — the platform filters the returned labels itself — but a `browseOnly` operation field does reach `getObjectTypes()` (descriptor.md, Field scope).

`ContentType` (`JSON`, `XML`, `BINARY`, `NONE`) is the dispatch key for which schema getter profile import reads — `JSON` → `setJsonSchema(String)`, `XML` → `setSchema(Element)` — so it must match the setter you called. Set the one matching the definition's role (`setInputType` for INPUT, `setOutputType` for OUTPUT); the other is ignored. Both **default to `xml`**, so a JSON schema with the content type left unset fails import with a message-less `java.lang.NullPointerException` and no profiles.

For a JSON schema `setElementName()` is **mandatory** (the Javadoc's "Optional" holds only for the XML path) and parsed as an RFC 6901 pointer. Unset → `NullPointerException: input cannot be null`; bare name → `illegal pointer: expected a slash to separate tokens`. Two forms work:

- `/definitions/TypeName` — the pointed-to subschema supplies the content and the pointer's last segment names the profile root; the schema root (its `title`, properties, or `$ref`) is ignored.
- `""` (whole document) — the root must be an inline schema; the profile root takes its `title`, and with no `title` the root element's name is empty. A root that is only a `$ref` fails with `ProfileGeneratorException: … attempt to expand to child tree, would lose information`.

For inline-root schemas, `JSONUtil.newJsonDefinition(role, schemaNode)` (`boomi-json-util`) sets both the `""` pointer and the content type.

Profile components are named `<connector displayName> <objectType label> <operationType> <Request|Response>`, suffixed ` 2`, ` 3` … on collision — repeated imports accumulate duplicates rather than replacing.

Packages differ and mismatches are compile errors: `BaseConnector`, `BaseBrowser`, `BaseUpdateOperation`, `ResponseUtil` in `com.boomi.connector.util`; `ObjectDefinition`, `ObjectDefinitionRole`, `ContentType`, `ObjectTypes` in `com.boomi.connector.api`.

For CUSTOM test connection, the Browser also implements `ConnectionTester.testConnection()` — returning normally is the only pass signal, throwing `ConnectorException` the only failure signal. For an API with no readable surface to probe, see descriptor.md, Test connection.

### Importable operation fields — `BrowseField`

`getObjectDefinitions()` can add operation fields per object type with `definitions.getOperationFields().add(field)` (`com.boomi.connector.api.ui.BrowseField`). Their values arrive at execution in `OperationContext.getOperationProperties()`, like descriptor fields.

A BrowseField whose id matches a descriptor operation field replaces it, **including the Java type delivered at runtime**: a descriptor `string` replaced by an `integer` BrowseField arrives as `Long`, and `getProperty` throws `ClassCastException`.

This is how a dropdown's options can depend on user input: declare the controlling field with `scope="browseOnly"` or `"both"` (descriptor.md, Field scope), read it from `BrowseContext.getOperationProperties()`, and generate the BrowseField's allowed values from it. The options are fixed at Import; changing them takes a re-import.

### ObjectDefinition cookie

`definition.setCookie(String)` carries connector-internal metadata from browse to execution, read back per role with `OperationContext.getObjectDefinitionCookie(role)`. The cookie is captured at Import and stored in the Operation component: a new connector version sees the old cookie until the operation is re-imported, so keep parsing every format you have shipped.

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
- `start()` must return within seconds; run the listening on its own thread. The Runtime starts and undeploys all listeners on one thread that waits on `start()`, so a blocking `start()` stalls every other listener. After 15 minutes the platform fails the listener without calling `stop()`, leaking whatever `start()` acquired until the JVM restarts.
- `stop()` releases what `start()` acquired and returns normally.
- `listener.isStopping()` is true only during container shutdown, not undeploy, so `stop()` must not branch on it.
- Submit events via `listener.submit(payload[, SubmitOptions])`, with `SubmitOptions.withFailIfStopping(true)`: during container shutdown `submit` then throws `ContainerStoppingException`; catch it and stop submitting (the `ConfigurableSubmitListenOperation` sample). Without it, a submit during shutdown returns normally and its execution is discarded. Batch with `listener.getBatch()` / `IndexedPayloadBatch`.

Javadoc for exact signatures: `https://boomisdkjavadoc.s3.amazonaws.com/javadoc/<sdk-version>/index.html`

For idiom rather than signatures, read the official samples first: `./gw connectorSamples` writes the official sample classes under `build/generated/src/connectorSamples/`, covering operations, browsers, listeners and polling. For a signature in the version you actually resolve, `javap -cp <jars> <class>` beats both — it is offline and cannot disagree with the build. Note that a sample compiling in place does not mean it compiles once copied into a connector: see build_and_package.md, Reading the official samples first.
