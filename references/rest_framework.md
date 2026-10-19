# REST Framework Reference (`connector-sdk-rest`)

The package is **`com.boomi.common.rest`** — not `com.boomi.connector.*`.

| Class | Role |
|---|---|
| `RestConnector` | extends `BaseConnector`. `createBrowser()` throws `UnsupportedOperationException` — always override. Default `createExecuteOperation()` returns `new RestOperation(new RestOperationConnection(context))`; it adds no other operation factory, so every other declared type needs its own override (sdk_architecture.md, Connector class). |
| `RestOperation` | extends `BaseUpdateOperation`. **`executeUpdate` is `protected final`** — it cannot be overridden. Extension points: `getPath`, `getParameters`, `getHeaders`, `getEntity`, `isRequestBodyRequired`. |
| `RestOperationConnection` / `RestConnection` | read configuration from connection properties. `getHttpClient()` returns a client with proxy, pooling, retry, and redirect settings but **no credentials**; `getHttpContext()` returns the `HttpClientContext` that carries them. |
| `RestClient` | thin wrapper over Apache `CloseableHttpClient`. Its constructor requires a non-blank HTTP method, taken from the custom operation type — so `getClient()` works only in EXECUTE. |

An operation needing direct `OperationResponse` control (per-document results) must use a plain `BaseUpdateOperation` instead — `RestOperation` cannot provide it.

## Typed operations

A `RestConnector` can back GET, QUERY, and the other typed operation types and keep the framework's connection-driven auth. Override the factory, pass a `RestOperationConnection` to the base-class operation, and execute with **both** client and context:

```java
@Override
protected Operation createGetOperation(OperationContext context) {
    return new MyGetOperation(new RestOperationConnection(context));
}

// in MyGetOperation extends BaseGetOperation, executeGet(...):
RestOperationConnection conn = (RestOperationConnection) getConnection();
HttpGet get = new HttpGet(conn.getUrl() + "/items/" + request.getObjectId().getObjectId());
try (CloseableHttpResponse resp = conn.getHttpClient().execute(get, conn.getHttpContext())) {
    // map status, build the payload
}
```

- **The context is mandatory.** `execute(request)` without `getHttpContext()` sends no credentials even with `auth=BASIC` and a valid username/password. Locally that surfaces as a plain 401; on a cloud runtime it is an `AccessControlException` (gotchas.md, Cloud runtime restrictions).
- **Do not call `getClient()` outside EXECUTE.** It throws `IllegalArgumentException: Http Method` — a typed operation has no custom operation type.
- Status mapping, paging, and the request itself are the operation's job; nothing from `RestOperation` applies.

## Reserved connection field ids

The framework reads these by **literal id** via `getConnectionProperties().getProperty("<id>")`. **Renaming one silently disables the behavior** — no error, no warning; `getProperty` simply returns null.

`auth`, `url`, `username`, `password`, `domain`, `workstation`, `preemptive`, `oauthContext`, `connectTimeout`, `readTimeout`, `awsAccessKey`, `awsSecretKey`, `awsService`, `awsRegion`, `customAwsService`, `customAwsRegion`, `privateCertificate`, `publicCertificate`, `cookieScope`, `customAuthCredentials`, `apiKeyLocation`, `apiKeyCustomProperties`, `enableConnectionPooling`, `followRedirects`

## Reserved operation field ids

`path`, `queryParameters`, `requestHeaders` — same lookup mechanism, so the same silent failure applies to a misnamed operation field.

## Authentication with no Java

Declare `auth` plus the fields its scheme needs; the framework does the rest.

`auth` allowed values (`AuthenticationType`): `NONE`, `BASIC`, `DIGEST`, `OAUTH2`, `AWS`, `AWS_ROLES_ANYWHERE`, `CUSTOM`, `NTLM`, `API_KEY`.

**`auth` must be declared.** Bare `username`/`password` do **not** enable Basic auth. `AuthenticationType.fromValue` has three behaviors:

| Input | Result |
|---|---|
| blank / absent | returns `NONE` **silently** — no credentials sent |
| matches an enum name | that value, matched **case-insensitively** (`basic` == `BASIC`) |
| non-blank, unrecognized | throws `IllegalArgumentException: Invalid Authentication type: <value>` |

A typo fails loudly; a *missing* field fails silently. Note the contrast with the descriptor schema, which is case-sensitive — different layers, opposite rules.

`preemptive` is honoured, read as `getBooleanProperty("preemptive", false)`.

### API key

Declare `auth` (including `API_KEY`), `apiKeyLocation`, and the grid field `apiKeyCustomProperties` (type `customproperties`).

`apiKeyLocation` values (`APIKeyAuthentication`): `REQUEST_HEADER`, `QUERY`, `COOKIE`, `NONE`. Same three-way `fromValue` semantics as above.

**`COOKIE` requires `cookieScope` to also be set.** With `cookieScope` unset the request is sent **with no API key at all** — HTTP 200, shape green, no error, no log line. Set `cookieScope` to `GLOBAL`, `CONNECTOR_SHAPE`, or `IGNORED` as a **connection field**.

## Cookies

`cookieScope` is a **connection field** (`GLOBAL` | `CONNECTOR_SHAPE` | `IGNORED`). `GLOBAL` is backed by a process-wide static cookie store shared across executions — consider the isolation implications on a shared runtime.

The `<networkConfig cookieScope="…"/>` element in `connector-config.xml` validates and is enum-checked, but does not affect HTTP cookie persistence — the connection field is the lever that works. The Gradle plugin regenerates `connector-config.xml` on every build from four literals and never emits `networkConfig`, so shipping the element at all requires post-processing the archive.
