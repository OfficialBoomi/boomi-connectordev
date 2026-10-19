---
name: boomi-connectordev
description: Develops, tests, and publishes custom Boomi connectors built with the Connector SDK — Java connector projects, connector-descriptor.xml, ConnectorTester, and the Connectors API deployment lifecycle (connector groups, classifications, version upload, version change). Use when creating or modifying a custom connector. Distinct from configuring or using connectors inside integration processes, and from exposing processes as MCP tools (boomi-integration).
---

# boomi-connectordev

## Scope

In: building Connector SDK projects (Java + Gradle), authoring `connector-descriptor.xml`, local testing, and the Connectors API deployment lifecycle — groups, classifications, descriptor validation, version upload, version change.

Out: using a published connector inside processes (Connection and Operation components — `boomi-integration`); MCP — the Connector SDK has no MCP surface, and exposing a process as MCP tools is the MCP Server connector in `boomi-integration`; the Connector Management API governance surface (review submission, visibility, metadata, icon); Boomi Fabric Task Automation connectors (a different, C#-based product surface).

## Terminology

- The **Connectors API** base path is `{BOOMI_API_URL}/connector/api/rest/v1/{accountId}` — not the Platform API's `/api/rest/v1/{accountId}`. Platform API scripts do not work against it unmodified.
- **`groupType`** and **`classificationType`** are unique slug identifiers, not kinds. `classificationType` is always `<groupType>-<classification>`, but `groupType` itself is assigned by the API and **cannot be derived** — read it back from the `group create` or `group get` response. The API prefixes the account id: `<accountId>-<slug>`, and the dev classification `<accountId>-<slug>-dev`. A soft-deleted group keeps its slug while releasing its name, so a name that looks free can still be taken. **`classification`** is the tier label within a group (`dev`/`qa`/`prod` by convention); `classificationType` is also what an Integration Connection or Operation component carries as its `subType`; on the Operation component it is what selects which connector build runs.
- A **version change** sets which uploaded version is active for a classification; for PRIVATE connectors it takes effect without an approval step, for PUBLIC it opens an approval request. Active is not the same as reachable — see step 4.
- The **archive** (`.zip` of `lib/**` + `META-INF/`) is what gets uploaded as a version. The Gradle plugin's `connectorArchive` task builds it. Gradle is the supported build path and the one Boomi recommends; Maven guidance is best-effort (references/build_and_package.md, Maven).

## Credentials and enablement

The skill reads credentials from the workspace `.env`. Sensitive values are never accepted as command-line arguments — the scripts source them from `.env` directly. Keys (shared with boomi-integration): `BOOMI_USERNAME`, `BOOMI_API_TOKEN`, `BOOMI_ACCOUNT_ID`, `BOOMI_API_URL`.

Publishing requires the account to have a signed SDK Publisher Agreement and the user the DEVELOPER privilege. On a 403 or privilege-related 400 **from these scripts**, stop and report — do not retry; repeated invalid-auth calls risk platform lockout. Verify access with `connectordev-env-check.sh` first. (A 403 a *Runtime* hits downloading a connector archive is unrelated and is not an auth failure — see step 4.)

## `<skill-path>` resolution

- Take this SKILL.md's absolute path and drop `/SKILL.md` — that is `<skill-path>`.
- Verify with `bash <skill-path>/scripts/connectordev-env-check.sh` from a workspace containing `.env`.
- Treat the path as fixed for the session and re-emit it verbatim in every invocation.

## Scripts inventory

All scripts support `--help` for usage. The Connectors API tools below emit the API's raw response (JSON) to stdout and diagnostics to stderr; always reach the API through them — never hand-roll curl, URLs, or auth headers. The first three are local-toolchain tools: they read no `.env`, call no API, and report in plain text.

- `scripts/connectordev-doctor.sh` — `[<project-dir>] [--skip-network]`; build-toolchain preflight: JDK discovery, the Gradle/JDK pairing, and whether the **JVM** (not curl) reaches the plugin portal and the SDK repository. Run before scaffolding; `env-check` passing says nothing about the build toolchain. Run again with `<project-dir>` once source exists: it also warns on calls in `src/main/java` that buffer a whole stream in memory.
- `scripts/connectordev-init.sh` — `<target-dir> [--name <artifact>] [--package <pkg>] [--class <Name>]`; lays down the template project with a pinned Gradle wrapper and the `gw` launcher.
- `scripts/connectordev-descriptor-lint.sh` — `<descriptor-xml> [--sdk-version <version>]`; validates the descriptor against the SDK's XSD locally, naming the offending element and line.
- `scripts/connectordev-env-check.sh` — verify `.env` and API access; lists existing groupTypes.
- `scripts/connectordev-group.sh` — `create <json-file> | get <groupType> | delete <groupType> | query [<json-file>] | query-more <token> | classification-add <json-file> | classification-delete <classificationType>` (group query pages at 20).
- `scripts/connectordev-version.sh` — `upload <zip> --group <groupType> [--changelog <text>] | delete <groupType> <versionId> | query [<json-file>] | query-more <token> | validate <descriptor-xml>` (version query pages at 100).
- `scripts/connectordev-version-change.sh` — `set <classificationType> <versionId> [--notes <text>] | cancel <classificationType>`.

**Not covered:** the connector-archive upload that creates group, classification and version in one call. It requires a `MANIFEST.MF` carrying `display-name`, which the Gradle plugin never writes, so a stock archive cannot be used with it. Use `group create` → `version upload` → `version change` instead.

**Pipeline discipline** — pipe script output only to `head`, `tail`, `wc`, or `grep`; never to `python3 -c`, `jq -r`, or `awk`. The agent harness treats each piped executable as a separate trust boundary and prompts for approval per pipe, defeating the point of allowlisting the scripts.

**Temp files stay in the project tree** — write scratch files (request bodies, downloaded responses) under `active-development/`, not `/tmp/`.

**Use the Write tool, not bash heredocs** — create JSON body files with a Write call, then pass the file path to the script; heredoc patterns trip the harness's static analysis.

## Development workflow

1. **Scaffold and build** — `connectordev-doctor.sh`, then `connectordev-init.sh <dir>`, then `./gw connectorArchive` (references/build_and_package.md). Once the project exists, run `./gw connectorSamples` and read the samples before writing any connector code — they are the closest thing to authoritative idiom, and the Javadoc is not a substitute. Resolve current SDK and plugin versions before pinning anything. Build with `./gw`, not `./gradlew`: the wrapper launcher and the Gradle daemon read different JVM settings, so a truststore set for one leaves the other failing separately. Stream every response into payloads: one read into a `String`, byte array, or `JsonNode` tree OOMs the Runtime (`references/sdk_architecture.md`, Large payloads).
2. **Test locally** — unit tests with ConnectorTester (driving **every** operation type the descriptor declares, not only the one under development: a missing factory-method override surfaces only on that type's first execution, with every earlier checkpoint green); a local basic Runtime for breakpoints, container logs, and any **listener** connector — the only self-serve way to run one, since on a Runtime Cloud a listener needs an execution worker and on a Boomi-hosted cloud that is a request to Boomi (`references/test_connector.md`). If the connector will run on a shared cloud, execute it there before release: a cloud denies file writes outside its working directory, environment reads, process spawning, and reflection, and a local Runtime enforces no SecurityManager at all to catch them (`references/gotchas.md`, Cloud runtime restrictions).
3. **Validate the descriptor** — two gates, at different targets. `connectordev-descriptor-lint.sh` on the source file as you edit: it checks the XSD locally with no build in between, and names the element and line where the API returns one message naming nothing. Then `connectordev-version.sh validate` before every upload, against the **built** descriptor so packaging-time filtering is covered. Use the copy inside the archive, since that is what gets uploaded, rather than the one Gradle leaves in `build/resources/main/META-INF/`: `unzip -p build/distributions/<archive>.zip META-INF/connector-descriptor.xml > <file>` (`build/connector-upload/` with older plugins). Run it even on a clean lint, because the XSD carries neither the semantic tier nor the operation `types` vocabulary. `validate` has no side effects; it exits non-zero on a rejected descriptor, including the 2xx form that carries an `errors` array; a warnings-only response passes, with the warning on stderr — read it. Neither gate can see the Connection or Operation components that consume the descriptor, so a clean result from both is not evidence those are correct (references/descriptor.md, Downstream contract).
4. **Publish** — first time: `connectordev-group.sh create` (one group per connector; the response returns the `groupType`). Every build: `connectordev-version.sh upload`, then `connectordev-version-change.sh set` to make it active for a classification. Uploading registers a version against the group and does **not** activate it, including the first one — the classification carries no active version until a version change, and its connection form renders empty in the GUI until then. A version change needs **no process redeploy** — connector versions are resolved by the Runtime rather than snapshotted into a deployed package, the opposite of the parent/subprocess rule. It is not instant, though: a Runtime that has already loaded the connector serves the loaded version until the container restarts, and a newly activated version's archive 403s for roughly half an hour before a Runtime can fetch it (`references/test_connector.md`, Archive download and side-loading).
5. **Use it** — once released, browsing and process-building with the connector is boomi-integration skill territory (its `references/components/custom_connector_connection_component.md`, `references/steps/custom_connector_step.md`, and — for the Operation component's `GenericOperationConfig` structure — `references/components/rest_connector_operation_component.md`). Hand over two things with it, because neither is derivable from the descriptor or the connector project:
   - **The `classificationType`** — see Terminology. Absent from the descriptor, and the slug cannot be reconstructed, so it has to come from you or from a connection someone already created in the GUI.
   - **The descriptor**, or its declarations. The Operation component must name the same operation type, custom type id, object type id, and field ids; the Connection component the same root-level field ids. A mismatch shows up only in the GUI (`references/descriptor.md`, Downstream contract).

   If the connection carries a `type="password"` field, tell them it must be edited in the GUI rather than round-tripped — pulling and pushing that component back destroys the credential silently, and nothing on the Integration side blocks it (`references/descriptor.md`, Downstream contract).

   Profile import is the one step with no API: the Operation component's Import wizard calls `Browser.getObjectDefinitions()` from the GUI only, so a human has to run it. Verify by pulling the generated `profile.json` components and reading the XML (`JSONRootValue name=`, one `JSONObjectEntry` per field) — a wizard success with an empty or wrongly-rooted profile is a failure (`references/sdk_architecture.md`, Browser).

Query state before mutating: `group query` / `version query` show what exists; `group get <groupType>` shows a group's classifications, versions, and review status.

`group delete` is a **soft delete** — it returns the non-JSON body `{true}`, and the deleted group keeps its `groupType`. Neither `group query` nor `env-check`'s group listing filters deleted records, so both show groups that no longer exist.

## References

- references/build_and_package.md — Use when: scaffolding a project, choosing a framework, editing build files, packaging the archive, or deciding which dependencies to bundle.
- references/descriptor.md — Use when: authoring or debugging `connector-descriptor.xml` (fields, operations, visibility, test connection), or handing declarations to whoever builds the Connection and Operation components.
- references/rest_framework.md — Use when: building on `connector-sdk-rest` (`RestConnector` / `RestOperation`) — reserved connection and operation field ids, authentication configured without Java, and typed (non-EXECUTE) operations that keep framework auth.
- references/sdk_architecture.md — Use when: writing the Java (Connector/Browser/Operation classes, results, large or paged responses, listeners, thread safety), or debugging profile import from a Browser's object definitions.
- references/test_connector.md — Use when: writing tests (including large-response tests), debugging against a local Runtime, or deciding whether a local Runtime is needed at all (a listener connector is the clearest case).
- references/gotchas.md — Use when: reviewing connector code, a connector fails at runtime (missing classes, memory, cloud restrictions, logging), a GET or DELETE operation is never entered or its documents vanish, or tracked-property values aren't showing up in the platform UI's process Test mode.

## Platform docs on demand

`developer.boomi.com` serves every doc page as clean Markdown: prepend `/md` to the path and append `.md` (e.g. `/docs/Connectors/Testing_connector` → `https://developer.boomi.com/md/docs/Connectors/Testing_connector.md`). The full Connectors page index is `https://developer.boomi.com/md/docs/Connectors/llms.txt`. Fetch these rather than relying on memory for platform behavior.

## Sample payloads

Mirror an existing asset's shape (`group get`) when in doubt; payload field names follow the API's vocabulary.

### ConnectorGroup — group create

```json
{
  "groupName": "My Connector",
  "CreateConnectorClassification": { "classification": "dev", "displayName": "My Connector", "version": 1 }
}
```

### ConnectorClassification — classification-add

```json
{ "classification": "qa", "displayName": "My Connector QA", "groupType": "<groupType>" }
```

### Query filters

Filter fields are UPPER_SNAKE and differ per endpoint. **Group query** filters on `NAME` — the group's name as given at create time — and rejects `GROUP_TYPE`; **version query** filters on `GROUP_TYPE` and *requires* it — there is no "all versions" call, so versions are only reachable per group. An empty body returns everything from group query and is rejected by version query.

```json
{ "QueryFilter": { "expression": { "argument": ["My Connector"], "operator": "EQUALS", "property": "NAME" } } }
```

```json
{ "QueryFilter": { "expression": { "argument": ["<groupType>"], "operator": "EQUALS", "property": "GROUP_TYPE" } } }
```
