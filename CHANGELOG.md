# Changelog

## 0.0.51

- The REST framework can back typed operations (GET, QUERY, ...) with framework auth via `getHttpClient()` + `getHttpContext()`; `getClient()` is EXECUTE-only.


## 0.0.50

- Bundled dependencies must be declared `api`; `implementation` jars are silently left out of the archive.


## 0.0.49

- `init` unsets `JAVA_TOOL_OPTIONS` in the project's `gw` when it breaks TLS; wrapper errors name the likely TLS cause.


## 0.0.48

- Document the `customPropertiesConfiguration` label length limits; say which built descriptor copy to validate.


## 0.0.47

- State that Gradle is the supported build path; mark Maven guidance best-effort and list the Gradle-only features.


## 0.0.46

- Stream large responses instead of buffering them; streaming template operation; `doctor <project-dir>` warns on buffering calls.


## 0.0.45

- Gate the browse `--add-opens` flag on the test JVM.


## 0.0.44

- Gate the ConnectorTester browse `--add-opens` flag so JDK 8 test runs start.


## 0.0.43

- Add an MCP scope boundary.


## 0.0.42

- Distinguish a failed static initializer from a missing class.


## 0.0.41

- Document the `CUSTOM` test connection probe for action-only APIs with no readable metadata surface.
- Publish one normalized output shape for a response that varies by input.


## 0.0.40

- Require driving every declared operation type under ConnectorTester.
- Add ConnectorTester harness traps: mutated input list, JDK 17 `--add-opens` for browse, lowercase content types.


## 0.0.39

- Correct the native GET step guidance: a `<parametervalue>` is required, a `parameter-profile` attribute is not.
- A parameter-less GET drops the document silently; it throws `Object IDs are required` only when the input is not well-formed XML.
- Empty `<parameters/>` and an absent `<parameters>` element are runtime-equivalent.
- Give the DELETE parameter-profile error its full message and execution-time timing.


## 0.0.38

- Correct the operation factory table: `createExecuteOperation` serves EXECUTE only; CREATE, UPDATE and UPSERT each have their own factory.
- Every operation type the descriptor declares needs its own factory override.
- Note that LISTEN is absent from `createOperation`'s dispatch.
- `RestConnector` adds no operation factory beyond `createExecuteOperation`.


## 0.0.37

- New `connectordev-descriptor-lint.sh` validates the descriptor against the SDK's XSD locally, ahead of the API's `validate`.
- Name the `connector-sdk-model` coordinate carrying `genericconnectordesc.xsd`.
- Fix the template descriptor's `required` attribute and `<operation type>`.
- Any `types` value outside the vocabulary, not just `"*"`, fails validation.


## 0.0.36

- Correct the build JDK: JDK 8 builds the template.
- Separate the JDK the build runs on from the Java 8 bytecode it emits.
- State the JDK/Gradle pairing in one place.
- Add a Gradle 7.0 floor to the toolchain preflight.
- Compile the preflight TLS probe so it runs on JDK 8.
- Probe `JAVA_TOOL_OPTIONS` both ways and name which way it cuts.
- Document the Keychain trust store setting on JDK 17 and its JDK 8 limit.
- Stop reporting a usable toolchain when JVM reachability went unchecked.
- Restore the `.env` parsing note and the `gw` allowlist entry in the skill README.


## 0.0.35

- Correct the `visibilityCondition` limit: one per field, not ten.
- Correct the `types` wildcard: `"*"` fails validation and cannot be uploaded.
- Scope the dangling-`fieldId` gap to operation fields; connection fields reject it.
- Add `wssecurity` to the field types.
- Document the `supportsBrowse` agreement rule across operations sharing a type.
- Warn that the `blacklistedKey` deprecation warning names an element that fails to parse.
- Name the semantic-tier message for each visibility rule.


## 0.0.34

- Document the `connectorSamples` and `connectorHelloWorldSource` Gradle tasks.
- Warn that a sample compiling in place may not compile once copied into a connector.
- Promote `javap` for confirming a signature against the resolved jars.
- Correct the `JsonPayloadUtil` note: 1.2.2 adds a coordinate; the older one is deprecated.


## 0.0.33

- Correct the doctor's remedy for a non-trust network failure.


## 0.0.32

- Ship `connectordev-init.sh` and a template project with a pinned Gradle wrapper and a `gw` launcher.
- Ship `connectordev-doctor.sh`, a JDK, Gradle and JVM-TLS preflight for the build toolchain.
- Correct the `JAVA_TOOL_OPTIONS` trap: on JDK 21 an empty keystore fails TLS, a missing path does not.


## 0.0.31

- Refuse a file path that curl reads as stdin, or that carries the `-F` separators `;` and `,`.


## 0.0.30

- Send the `query-more` token with `--data-raw`, so a token beginning with `@` is sent as given rather than read as a local file.


## 0.0.29

- Parse `.env` instead of executing it, ignoring keys the scripts do not read.
- Validate `BOOMI_ACCOUNT_ID` and `BOOMI_API_URL` after loading, and trim trailing slashes from the latter.


## 0.0.28

- Documented the `fieldSelectionNone` operation attribute.
- Documented the `testConnection` `operationType` and `customOperationType` attributes.
- Corrected `outputType` — it does not remove the Response Profile selector.
- Documented the one-`valueCondition` limit per visibility condition.


## 0.0.27

- Documented that same-`types` siblings can hide a bare operation from the Connector Action dropdown.


## 0.0.26

- Corrected the `trackedDocument` values to include `user`.


## 0.0.25

- Documented that `supportsBrowse` defaults to `true`.
- Documented that a browse-enabled operation opens the Import wizard, not the operation form.


## 0.0.24

- Guarded `curl_cfg` against xtrace.
- Documented the caller-side guard and capture rules for `curl_cfg`.
- Validated identifiers interpolated into URL paths.


## 0.0.23

- Document element order for the descriptor root, fields, operations and browse configuration.
- Document the request/response profile, tag-restriction and custom-properties descriptor elements.
- Correct the connection-vs-operation field children and the `restrictedKey` deprecation target.


## 0.0.22

- Added a REST framework reference.
- Documented that `<fieldValue>` takes `id`, and is not delivered to the Browser at Test Connection time.
- Documented that a visibility condition takes one or more values.
- Documented that a conditional field's value is blanked once it becomes invisible.
- Scoped the failure-reporting rule to whole-execution vs per-document failures.
- Named the two input-acknowledgement errors and how each surfaces.
- Documented that `getProperty` is safe only for string and password fields.
- Documented `inputType`/`outputType`, and that `<queryFilter>` is mandatory and precedes `<browseConfiguration>`.
- Documented that field specs restrict QUERY field selection, via the typed API.
- Documented that omitting `sdkApiVersion` defaults to 1.0.0.
- Added the cookie-scope credential omission and the fields a GUI save materializes.


## 0.0.21

- Documented execution worker recycling and the scope of Listener Startup Mode.


## 0.0.20

- The echoed-changelog check no longer warns on a backspace or formfeed.
- A plain-ASCII changelog mismatch is no longer reported as unverifiable.


## 0.0.19

- Corrected the listener runtime requirement: an execution worker is the condition, not the runtime class.


## 0.0.18

- Corrected the local Runtime testing and remote debugging guidance.


## 0.0.17

- Values interpolated into JSON request bodies are now escaped.


## 0.0.16

- `upload --changelog` now sends the text intact as declared UTF-8, and reports an echoed changelog that differs.


## 0.0.15

- Scoped each xtrace guard's saved state to its own function.


## 0.0.14

- Corrected the GET/DELETE object-id model: GET reads the step parameter, DELETE reads the input documents.
- Split the three connector loggers by destination.


## 0.0.13

- `validate` now exits non-zero on a rejected descriptor, including the 2xx form, and flags warnings.


## 0.0.12

- Correct the section example and document section placement, attributes and limits.
- Document validate's two response tiers: a 2xx carrying `errors` is not a pass.


## 0.0.11

- groupType carries an account-id prefix; read it back rather than deriving it.


## 0.0.10

- DynamicPropertyMap has no typed getters; overrideable booleans and integers parse by hand.


## 0.0.9

- Class loading: what strict mode hides, and the Overrides file for non-strict conflicts.
- boomi-json-util 1.2.x: no POM dependencies, and JsonPayloadUtil moved packages.
- Missing-class triage: the two error shapes, and finding a class's origin.


## 0.0.8

- Tracked properties: process Test mode shows no values; how to confirm one instead.
- Sharpen cross-reference pointers to name the target section.


## 0.0.7

- Keep credentials out of shell trace output in the environment check.


## 0.0.6

- Correct descriptor field rules: helpText/allowedValue ordering, formatRegex is an attribute.
- Document the generic descriptor parse error.
- Document ContentType dispatch and setElementName requirements for profile import.


## 0.0.5

- Documented handoff when a custom connector moves to Integration process building


## 0.0.4

- Corrected build, descriptor and API guidance


## 0.0.3

- Documented the descriptor's contract with Integration connection and operation components


## 0.0.2

- Initial boomi-connectordev skill: Connectors API deployment scripts and connector build/test references

