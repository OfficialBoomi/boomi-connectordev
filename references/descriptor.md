# connector-descriptor.xml Reference

The descriptor defines the connector's UI (connection and operation screens) and capabilities. It lives at `src/main/resources/META-INF/connector-descriptor.xml` and is packaged into the archive. Two gates: `connectordev-descriptor-lint.sh` on the source file as you edit, then `connectordev-version.sh validate` on the **built** copy inside the archive, which is what gets uploaded.

The authoritative schema is `genericconnectordesc.xsd`, published only inside the SDK model jar — `https://boomisdk.s3.amazonaws.com/releases/com/boomi/connsdk/connector-sdk-model/<version>/connector-sdk-model-<version>.jar`, under `com/boomi/model/connector/`. `connectordev-descriptor-lint.sh` fetches and caches it; read it directly when a construct is undocumented.

`validate` is mostly structural, and answers *"is this correct?"* only in narrow places. Failures come back two ways: a **schema** failure is HTTP 400; a **semantic** failure is HTTP 2xx carrying an `errors` array of named messages that accumulate, so a 2xx status alone is not a pass. One mistake can surface as two messages — a wrongly-typed controller returns both the controller-type error and a boolean-values error against the same field — so read a multi-error response as one fault list, not as independent findings. A 2xx may instead carry `warnings` — accepted, but read them. The section count and id rules are enforced in the semantic tier. It does reject a `customTypeId` containing spaces, and `overrideable` on a connection-level field. It does **not** reject a `customTypeId` on a non-EXECUTE operation, two indistinguishable EXECUTE operations, `overrideable` on a wrongly-scoped field, a `fieldSelectionLevels` above the documented maximum, a `fieldSelectionNone` that `allowFieldSelection="false"` renders inert, a `valueCondition` naming a field that does not exist **on an operation field** (at connection scope it is rejected), or a QUERY operation with no `<queryFilter>` — which is guaranteed to fail in the GUI rather than merely being latent (see Operations). The component push, the deploy, and the runtime are no stricter — a descriptor can validate, upload, activate, deploy and execute while being semantically wrong. `version upload` is the one exception: it re-runs the same descriptor validation and fails the upload with HTTP 500 `"Failed validating descriptor"`, which names nothing. Skipping `validate` therefore costs you the specific message, not the check.

## Contents
- Structure and element order
- Fields
- Allowed values and visibility
- Test connection
- Operations
- Downstream contract
- Document properties
- Type mappings
- Constraints
- Deprecated

## Structure and element order

Element order is schema-enforced; out-of-order elements fail with "Descriptor parsing failed". The root sequence is:

```
description?  →  section*  →  field*  →  profileTypeMappings?  →  testConnection?
  →  operation+  →  dynamicProperty*  →  trackedProperty*  →  trackedGroup*
```

A descriptor must declare at least one `<operation>`; every other child is optional:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<GenericConnectorDescriptor>
    <section id="auth" sectionType="page" title="Auth"/>  <!-- 1. sections -->
    <field id="url" label="Base URL" type="string"/>      <!-- 2. connection fields -->
    <testConnection method="CUSTOM"/>                     <!-- 3. testConnection -->
    <operation types="EXECUTE" supportsBrowse="false"/>   <!-- 4. operations -->
</GenericConnectorDescriptor>
```

Sections come before all connection fields — any section after the first field fails.

Root attributes: `requireConnectionForBrowse` (default `false`; see Operations, Choosing browse mode), `disableDefaultObjectTypeFilter` (hides the object-type filter field that dynamic types add; valid and supported).

Every structural error — bad order, unknown element, unknown attribute, an element that should be an attribute — returns the same `"Descriptor parsing failed, please check to make sure your connector descriptor is syntactically valid."`, naming no field, element or line. Do not debug that message: the lint names the element, the line, and what was expected instead. Bisecting from a minimal descriptor is the fallback for a parse failure the lint passes. Unknown attributes and elements are rejected at both tiers, so a clean result is evidence a construct is really in the schema. For a descriptor known to validate, `connector-sdk-rest-<version>.jar` carries Boomi's HTTP Client connector descriptor at its root.

A lint pass is not a `validate` pass. The XSD covers structure and enumerated attribute values; it does not carry the semantic tier (section count and id rules) and does not constrain the operation `types` vocabulary at all, so run both.

## Fields

```xml
<field id="apiKey" label="API Key" type="password" sectionId="auth" formatRegex="[0-9a-fA-F-]{36}">
    <helpText>Authentication key</helpText>
    <defaultValue>...</defaultValue>
</field>
```

`formatRegex` is an attribute; as a child element it never validates. There is no `required` attribute — the schema rejects one. Children are a strict sequence — any other order fails:

```
helpText?  →  defaultValue?  →  allowedValue*  →  customPropertiesConfiguration?
  →  visibilityCondition*
```

Connection and operation fields share that sequence. A connection field may append one `oauth2FieldConfig` after `visibilityCondition`; an operation field adds no further children.

`<defaultValue>` on an operation field is a **design-time pre-fill only**. The GUI uses it to populate the field when the component carries no value; the runtime never applies it. If a component omits the field, the connector receives nothing for it — not the default — so connector code must supply its own fallback.

Types: `string`, `password` (encrypted), `integer`, `boolean`, `privatecertificate`, `publiccertificate`, `oauth`, `wssecurity`, `customproperties` (max 50 pairs). A `customproperties` field is configured by its `<customPropertiesConfiguration>` child — `keyLabel`, `valueLabel`, `addButtonLabel`, `allowValueEncryption` attributes, plus `<restrictedKey>` children naming keys the user may not define. For dropdowns use `string` with `displayType="list"` (or `radio`) plus `allowedValue` — the `enumeration` type is deprecated.

Connection sections (tabs): `<section id="advanced" sectionType="page" title="Advanced"/>`, referenced by fields via `sectionId`. All three attributes are required — there is no `type` attribute, an empty `title` is accepted where a missing one is not, and `id` cannot contain a space. `sectionType` is enumerated and case-sensitive; `page` is the only value known to validate (`PAGE` and `tab` both fail). Sections are connection scope only: a `sectionId` on an operation field fails.

Titles over 40 characters return the generic parse error. Three rules answer on the semantic tier with a named message instead: exceeding the section limit (`"Maximum 3 sections are allowed."`), duplicate section ids (`"Duplicate section id found."`), and a `sectionId` matching no declared section (`"Invalid section id found."`). A declared section that no field references is fine.

Field scope (operation-level fields only; connection fields are available at runtime, and during import only with `requireConnectionForBrowse="true"` — see Operations, Choosing browse mode):

| Scope | Rendered | Reaches the Browser at Import | Stored; reaches runtime |
|---|---|---|---|
| (none) / `operationOnly` | Operation screen — default | No | Yes |
| `browseOnly` | Import wizard | Yes | No |
| `both` | Both | Yes — the wizard value, which Import writes back to the operation | Yes |

An empty wizard field arrives as `""`, not absent.

`overrideable="true"` (Dynamic Operation Properties) works only on operation fields with scope `operationOnly` (the default) or `both`, and only for `string`, `boolean`, `integer`, `customproperties` types.

## Allowed values and visibility

```xml
<field id="format" type="string" displayType="radio">
    <allowedValue label="JSON"><value>json</value></allowedValue>
    <allowedValue label="XML"><value>xml</value></allowedValue>
</field>
<field id="apiKey" label="API Key" type="password">
    <visibilityCondition>
        <valueCondition fieldId="authType"><value>apikey</value></valueCondition>
    </visibilityCondition>
</field>
```

- Descriptor dropdown options are static — they cannot change based on another field's value. Use separate fields with visibility conditions, or generate the field at Import as a `BrowseField` whose options come from a wizard field (sdk_architecture.md, Importable operation fields).
- `helpText` and `allowedValue` combine in either scope, `helpText` first. Help text renders only as an ⓘ hover icon beside the label, never inline, so put descriptions users need to see in the `allowedValue` labels.
- Visibility: one `<visibilityCondition>` per field, one or more `<value>` children per condition (any match satisfies it), no chaining (if A controls B, B cannot control C); the referenced field must be boolean or have list/radio displayType; `oauth` and WsSecurity fields cannot be conditional. Chaining and a wrongly-typed controller both answer by name: `"A conditional visibility field cannot be referenced by another conditional visibility rule at this time. This is to prevent circular conditions. (Field ID: <id>)."` names the *referencing* field rather than the middle field you would have to change; `"The field with ID: <controller> is involved in the visibility configuration rule for the field with ID: <dependent>, it must be of type boolean or have a list or radio display type."` names both.
- **One condition, one field.** A field may carry exactly one `<visibilityCondition>`, holding exactly one `<valueCondition>` — visibility can depend on one other field, never two, and never on two alternative conditions. Each limit has its own semantic-tier message: a second `<visibilityCondition>` returns `"Only 1 condition is supported for visibility at this time on field with ID: <id>."`; a second `<valueCondition>` returns `"Only 1 field value condition is supported for visibility at this time on field with ID: <id>."` A second `<valueCondition>` is rejected again by `version upload`. Eleven or more of *either* element fails the parse tier instead. Nothing here is silent. Use multiple `<value>` children to OR across one field's values, and accept that AND-ing two fields is unavailable.
- **A boolean controller accepts only `true`/`false`.** Any other value fails with `"The visibility condition for field <id> may only have the values true and false when referencing a boolean type field in the condition."`, naming the dependent field. This is a separate check from the `allowedValue` cross-check below — a boolean controller never consults an allowed-value list — and it folds case, so `TRUE` validates.

```xml
<field id="secret" label="Secret" type="string">
    <visibilityCondition>
        <valueCondition fieldId="authType">
            <value>apikey</value>
            <value>basic</value>
        </valueCondition>
    </visibilityCondition>
</field>
```

**Value matching folds case but does not trim.** `APIKEY` in a `<value>` matches an `allowedValue` of `apikey`, both when the descriptor is validated and when the GUI evaluates visibility; a leading space does not match. So case can never distinguish two allowed values, and a case mismatch between `<value>` and `<allowedValue>` is harmless rather than a latent bug — rule case out first when a conditional field misbehaves, then go looking for whitespace.

`validate` cross-references each `<value>` against the referenced field's `allowedValue` list and is strict about it: a near-miss or a leading space fails with `"The visibility condition value(s) you have provided for <id> is not in the allowed values for the referenced field with ID: <id>."` A `fieldId` naming a field that does not exist is **rejected at connection scope** with `"The visibility condition configured on field with ID: <id> must point to an existing configured field."` — but the same typo on an **operation** field validates clean, so the existence check is connection-scope only. The message names the referencing field, not the missing one. Declaration order is irrelevant: a controller declared later in the descriptor resolves fine.

**A value in a field that becomes invisible is blanked on the next GUI save.** The field is not removed — it stays declared with `value=""`. Nothing warns, and the save succeeds normally. Only conditional fields are affected — unconditional fields written in the same save keep their values. Anyone who toggles a controller field to inspect an alternative configuration and toggles back has silently destroyed the value behind it. Warn whoever maintains a connection whose credential fields are conditional.

## Test connection

Must sit after connection fields, before operations.

```xml
<testConnection method="GET_OBJECT_DEFINITIONS" objectType="Customer" operationType="GET">
    <fieldValue id="pageSize">10</fieldValue>  <!-- inert — see below -->
</testConnection>
```

Methods: `GET_OBJECT_TYPES` (calls `Browser.getObjectTypes()`), `GET_OBJECT_DEFINITIONS` (needs `objectType`), `CUSTOM` (Browser must implement `ConnectionTester`).

**The first two pass or fail as a side effect of retrieving metadata**, so they need a readable metadata surface. An action-only API — one path, one `POST`, where invoking it does real work and costs something — has none, and nothing safe to probe either.

`CUSTOM` is the method whose contract is purely pass/fail: have the tester send a request that is well-formed but deliberately invalid against the API's own schema, such as a body omitting a required field, and decide from the status class. An authentication or authorization refusal is the only failure; every other response is a pass.

The rejection **is** the healthy answer, so a tester written as "anything but 2xx throws" makes Test Connection permanently fail against a working connection. Keep the probe itself side-effect free — a probe that really invokes the operation spends quota or creates a record on every click.

`operationType` and `customOperationType` are optional and set the operation type the Browser sees during Test Connection. Each must name something the descriptor already declares — `customOperationType` pairs with an operation's `customTypeId`, which is how a `GET_OBJECT_DEFINITIONS` test is pointed at a custom-typed operation. It is delivered: with the attribute set, `BrowseContext.getCustomOperationType()` returns exactly that value during Test Connection.

**Undeclared, it returns `null` — not `""`.** A Browser doing `getCustomOperationType().equals(...)` therefore throws an NPE whenever the descriptor omits the attribute, which is the default state. Compare in the safe direction or null-check first.

Test Connection delivers operation *identity* even though it delivers no operation *field values* (see below).

`<fieldValue>` takes `id`, not `fieldId` — and then does not work. The value is **not delivered** to `getOperationProperties()` at Test Connection time, for any field scope (`both`, `browseOnly`, or the default): the Browser observes an empty `PropertyMap`, not a map missing one key, and `BrowseContext` exposes no other accessor it could arrive through. Multiple `<fieldValue>` children validate and are uniformly inert. A Browser needing configuration during `GET_OBJECT_DEFINITIONS` must read it from a **connection** field, which is delivered reliably.

## Operations

```xml
<operation types="QUERY" supportsBrowse="true" allowFieldSelection="true">
    <queryFilter sorting="unbounded" grouping="any">
        <operator id="eq" label="Equals"/>
        <operator id="between" label="Between" numArguments="2"/>
        <sortOrder id="asc" label="Ascending"/>
    </queryFilter>
</operation>
```

Attributes: `types` (pipe-separated to share one config, e.g. `"GET|DELETE"`; the wildcard `"*"` is **not usable** — see below), `customTypeId`/`customTypeLabel` (custom operations; `context.getCustomOperationType()` can return null — default defensively), `supportsBrowse` (default `true`), `allowFieldSelection`, `fieldSelectionLevels` (default 2, max 3), `fieldSelectionNone` (boolean, default `false` — see below), `inputType`/`outputType` (`none` | `binary`, lowercase only), `trackedDocument` (`request` | `response` | `user`, where `user` defers the tracking direction to the user; defaults: request for CREATE/UPDATE/UPSERT/DELETE/EXECUTE, response for GET/QUERY; LISTEN is always response and cannot be changed).

Operation types: `EXECUTE`, `CREATE`, `UPDATE`, `UPSERT`, `DELETE`, `GET`, `QUERY`, `LISTEN`. Any other value — the wildcard `"*"` or a plain typo — fails validation with HTTP 400 `"Exception occurred while validating descriptor %s."`, an unsubstituted placeholder, so `version upload` rejects it too. The lint does not catch it.

Every type declared here obliges the Connector class to override that type's own factory method — `BaseConnector`'s defaults throw, and only executing that type catches the omission (sdk_architecture.md, Connector class).

Update-style operations (EXECUTE/CREATE/UPDATE/UPSERT) receive their input document as sent, in any format. GET and DELETE instead work from object ids, reaching them by two different routes — GET from the connector step's parameter, DELETE from ids the platform parses out of the input documents — and a wrong route fails silently. See gotchas.md, Where GET and DELETE ids come from.

`EXECUTE` is a current, valid type — the platform's "Supported operations (actions)" list omits it because that list enumerates user-facing action semantics, not legal `types` values. But a bare `types="EXECUTE"` reaches users as an action named literally "EXECUTE". Prefer the natural CRUD type; where EXECUTE fits the semantics, name it with `customTypeId` (NCName — no spaces) plus `customTypeLabel`, which is the label the GUI shows and falls back to the id when absent.

**A bare operation can be shadowed by its same-`types` siblings.** A bare `<operation types="EXECUTE">` declared alongside several `<operation types="EXECUTE" customTypeId="…">` validates, uploads and activates cleanly, and then does not appear in the GUI's Connector Action dropdown — nothing reports the omission at any checkpoint. The same operation, alone in the descriptor, appears and renders normally. One more reason to give every EXECUTE operation a `customTypeId`.

**Name operations from the first published version** — this is a versioning constraint, not a style preference. The GUI resolves a component's action as its `customOperationType` when present and its bare `operationType` otherwise. So adding a `customTypeId` to an operation that previously had none is not additive: every Operation component built against the old descriptor stops matching a declared operation the moment the new version is activated. Their forms collapse (see Downstream contract) with no warning at upload or activation, and the damage appears only when someone opens one. Existing integrations keep executing correctly, which makes the state especially confusing.

`supportsBrowse` is an attribute, not a child element, and **it defaults to `true`** — omitting it browse-enables the operation, which then opens the Import wizard rather than the operation form. The wizard's own fields (Connector Action, Runtime, Filter) are distinct from the operation's declared fields. Set `supportsBrowse="false"` on any operation that does not browse. Operations covering the same type must **agree** on it: declaring the type twice is fine, but a conflict fails with `"<TYPE> operation is configured with supportsBrowse=true and supportsBrowse=false"` (no trailing period, and the type is templated in — this is not QUERY-specific). The pipe-separated form expands for this check, so `"QUERY|GET"` collides with a bare `"QUERY"`.

**Choosing browse mode.** Two independent settings:

- **Object types** — static: `<browseConfiguration><objectTypes>` (below); `getObjectTypes()` output is not used, `getObjectDefinitions()` still runs. Dynamic: omit `<objectTypes>`; `getObjectTypes()` supplies the list, and the wizard adds an object-type filter field.
- **Connection** — decided by `requireConnectionForBrowse` alone. Omitted or `"false"`: the Import wizard offers no Connection selector, and during import both Browser methods see empty connection properties — no `<defaultValue>` substitution. `"true"`: a Connection is required and its values reach the Browser. Set it only when a Browser method needs credentials or connection settings; static object types do not make a Connection available.

Static object types (replace `getObjectTypes()`) — `<browseConfiguration>` is a child of `<operation>`, and the `<objectTypes>` wrapper is required; omitting it fails with "Descriptor parsing failed":

```xml
<browseConfiguration>
    <objectTypes>
        <object id="customer" label="Customer"/>
    </objectTypes>
</browseConfiguration>
```

Child order inside `<browseConfiguration>` is:

```
objectTypes?  →  inputProfile?  →  outputProfile?
```

`<inputProfile>` and `<outputProfile>` name the operation's Request and Response Profile selectors. Each takes a `label` and `selectable` (default `false`), and holds `helpText?` followed by up to two `<profileType>` children (`xml` | `json`).

```xml
<browseConfiguration>
    <inputProfile label="Request Profile (Optional)" selectable="true"/>
    <outputProfile label="Response Profile (Optional)" selectable="true">
        <helpText>The structure of the response the connector returns.</helpText>
        <profileType>json</profileType>
    </outputProfile>
</browseConfiguration>
```

**What governs the profile selectors** is `supportsBrowse` plus `<browseConfiguration>` — not `inputType`/`outputType`, which are inert:

| Operation shape | Request / Response selectors |
|---|---|
| `supportsBrowse="false"` | **present**, generic, defaulting to Unstructured |
| `supportsBrowse="true"`, no `<browseConfiguration>` | **absent** — the wizard supplies the profiles |
| `supportsBrowse="true"` + `<inputProfile>`/`<outputProfile selectable="true">` | **present** |

To suppress a Response Profile selector on a browsable operation, omit `<outputProfile>` or leave its `selectable` at the default `false`.

**`<queryFilter>` is required for every QUERY operation, and must precede `<browseConfiguration>`.** Omitting it passes descriptor validation, uploads and activates cleanly, then fails the first time a human opens the operation: *"The query panel can not be rendered because this connector has not been configured properly…"*. Ordering it **after** `<browseConfiguration>` fails with the generic parse error instead. Child order inside `<operation>` is:

```
field*  →  queryFilter?  →  browseConfiguration?  →  availableForTags?
```

A browsable QUERY operation needs both `<queryFilter>` and `<browseConfiguration>`, so that is the default shape of a real QUERY connector.

`<availableForTags>` closes the operation. It wraps one or more `<value>` elements and restricts the operation to connectors carrying a matching tag.

`queryFilter` grouping: `none`, `any`, `noNestingImplicitOr`, `noNestingImplicitAnd`, `singleNestingImplicitOr`, `singleNestingImplicitAnd`. Sorting: `none`, `one`, `unbounded`.

**Declare only what the endpoint evaluates.** Whatever the endpoint cannot evaluate falls to the connector. A filter can still be evaluated per record as the response streams. A sort cannot: it needs every record in memory before the first is emitted. Match `operator`, `grouping` and `sorting` to what the API supports (`sorting="none"` when it has no sort), and narrow the filterable and sortable fields with `FieldSpecField` (sdk_architecture.md, Browser). Streaming: sdk_architecture.md, Large payloads.

`<queryFilter>` limits only the GUI. The panel offers just the declared operators and sort orders, and `sorting="none"` removes the Sorts tab, but `sorting="one"` still allows a second sort, and an edited Operation component delivers any operator, sort order or sort count to the connector unchanged. The connector validates each against its declaration and fails the query on anything else.

### `fieldSelectionNone`

`fieldSelectionNone="true"` opens the Import wizard's field-selection tree with **nothing** checked; the default (attribute absent) checks every field. It is an import-time default, not a live binding: the wizard bakes the result into the saved Operation component as `selected="true"`/`selected="false"` on each `<ConnectorField>`, and the attribute itself is not copied there. Changing it in a later connector version leaves existing Operation components alone.

It only sets the initial state of a list that `allowFieldSelection` decides exists at all — with `allowFieldSelection="false"` the wizard shows the object node and no fields beneath it, so `fieldSelectionNone` has nothing to act on. That combination validates without a warning.

An operation saved straight out of a `fieldSelectionNone="true"` wizard has every field `selected="false"`, and `getSelectedFields()` reports nothing selected at runtime. Forcing a deliberate choice is the point of the attribute, but nothing warns when the user makes no choice at all.

### `inputType` and `outputType`

Both accept exactly `none` and `binary`, enum-checked at validation (`BINARY` is rejected). They are **design-time only** — `OperationContext` exposes no accessor, so the connector never sees them — and neither has any observable effect on the operation form. `outputType="none"` does **not** remove the Response Profile selector and `inputType="none"` does **not** remove the Request Profile selector, in any combination of `supportsBrowse` and `<browseConfiguration>`. Profiles already default to Unstructured, so `binary` requests what you already have. To control the selectors, see What governs the profile selectors above.

Do not confuse these with `ObjectDefinition.getInputType()` / `getOutputType()`, which return a `ContentType` (`JSON`/`XML`/`BINARY`/`NONE`) and are the Browser's *outbound* declaration about a profile. Identical names, unrelated mechanisms, opposite directions.

## Downstream contract

Authoring the Connection and Operation components is boomi-integration skill territory — `references/components/custom_connector_connection_component.md`, `references/steps/custom_connector_step.md`, and — for the Operation component's `GenericOperationConfig` structure — `references/components/rest_connector_operation_component.md` in that skill. What the descriptor declares is what those components must name:

| Descriptor | Operation component (`GenericOperationConfig`) |
|---|---|
| `<operation types="EXECUTE">` | `operationType="EXECUTE"` |
| `customTypeId="X"` | `customOperationType="X"` — omit entirely when none is declared |
| operation-level `<field id="city">` | `<field id="city" type="string" value="…"/>` |
| `Browser.getObjectTypes()` id | `objectTypeId` |

Root-level `<field>` elements land in the Connection component's `GenericConnectionConfig` instead. Both components also carry the connector's `classificationType` as their `subType` — a value the descriptor does not contain, so it travels with the declarations.

**The platform never rejects a mismatch.** Nothing compares component attributes against the descriptor on the way in; undeclared values are passed to the connector verbatim, and every automated checkpoint stays green: the Java compiler, `validate`, the version upload, the component push, the deploy, and the runtime all pass, and the process executes successfully with plausible output. Ranked by how hard each mismatch is to notice:

| Mismatch | What happens |
|---|---|
| `<field id>` misspelled | The value never arrives; `<defaultValue>` does **not** substitute. No warning anywhere, and the GUI displays the default as if it were set. |
| Operation `subType` names another classification | That classification's connector build runs, with this connection's credentials. Visible only in the connector step's log prefix, or by comparing the connector subtitles on the two components in the GUI. |
| `objectTypeId` undeclared | Nothing at runtime — correct output. |
| `customOperationType` undeclared | Reaches the connector verbatim. The GUI operation form loses its object type and every declared field, with a banner naming the value. |

Author component attributes from the descriptor, not from a pulled example of another connector. And since the platform will not check, a connector that validates its own inputs — `getCustomOperationType()` against its known set, `getOperationProperties().keySet()` against its expected ids — is the only way to surface these outside the GUI. See sdk_architecture.md, Context and properties → Validate your own inputs.

**A `type="password"` connection field cannot survive a pull-then-push.** A pulled password field holds a 128-character hex token, not the secret, and a push stores whatever is in the `value` attribute — so pushing the pulled component back makes the token string itself the credential. Push, deploy, and execution all succeed; the only symptom is the connector's authentication being rejected by the target. Whoever maintains the connection has to edit it in the Boomi GUI rather than round-tripping the XML, and no tooling will stop them otherwise: boomi-integration's push guard rejects a pushed token for REST Client connections only, and a custom connector connection carrying the same token pushes without complaint. Its `references/guides/boomi_error_reference.md` Issue #38 is the full account.

## Document properties

```xml
<dynamicProperty id="recordId" label="Record ID" type="string"/>  <!-- connector reads from document -->
<trackedProperty id="responseCode" label="Response Code"/>         <!-- connector writes; visible in reporting -->
<trackedGroup id="responseHeaders" label="Response Headers"/>      <!-- keyed set of tracked values -->
```

All IDs across dynamic properties, tracked properties, and tracked groups must be unique.

The platform UI's process Test mode does not display `<trackedProperty>` values — see gotchas.md, Tracked properties.

## Type mappings

`profileTypeMappings` sets default XSD→Boomi type mappings for imported profiles (targets: `character`, `number`, `datetime`; optional `format`). Default datetime format is `yyyy-MM-dd'T'HH:mm:ss.SSSZZ`.

## Constraints

| Item | Limit |
|---|---|
| Custom connection sections | 3 |
| Section title | 40 chars |
| `customPropertiesConfiguration` `keyLabel` / `valueLabel` | 25 chars |
| `customPropertiesConfiguration` `addButtonLabel` | 12 chars |
| `customproperties` pairs | 50 per field |
| Static browse object types | 50 |
| `fieldSelectionLevels` | max 3 |
| `visibilityCondition` per field | 1 |
| `valueCondition` per `visibilityCondition` | 1 |

Case sensitivity is enum-checked but **not consistent across the two connector files**: `connector-descriptor.xml` wants lowercase (`sectionType="page"`, `inputType="binary"`; `PAGE`/`BINARY` rejected), while `connector-config.xml`'s `networkConfig/@cookieScope` wants uppercase (`GLOBAL`; `global` rejected).

## Deprecated

| Deprecated | Instead |
|---|---|
| `browsingType` attribute on the root | Remove — `cloud` validates with a retirement warning, any other value fails to parse |
| `enumeration` field type | `string` + `displayType="list"` + `allowedValue` |
| `blacklistedKey` in customproperties config | `restrictedKey` — **singular**. It is accepted with a deprecation warning that tells you to use "the restrictedKeys element"; `<restrictedKeys>` is not in the schema and fails the parse tier, which names nothing. Follow this table, not the warning. |

Full platform reference: `https://developer.boomi.com/md/docs/Connectors/GettingStartedWithConnectorDevelopment/ConnectorArchitecture/Connector_descriptor_file.md`
