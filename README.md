# boomi-connectordev

A Boomi Companion skill for custom connector development with the Boomi Connector SDK.

> **Important:** Boomi Companion is a publicly available developer offering, not an officially supported Boomi product. It is provided as-is and is not covered by Boomi support agreements or SLAs. Boomi curates and maintains this tool on a best-effort basis — treat it as a self-service resource. Boomi reserves the right to modify or discontinue it at any time without notice.

This project is licensed under the [BSD-2-Clause License](LICENSE). If you fork or modify this code, you should not use the name "Boomi" for your version.

## Feedback & Issues

Found a bug or have a feature idea? Email developer-offerings@boomi.com with a clear description, steps to reproduce, and any relevant error messages.

## Setup

The `boomi-connectordev` skill reads credentials from the workspace `.env`. If the `bc-integration` plugin or `boomi-integration` skill is already set up, the same Platform details are re-used by this skill — no new keys are needed.

| Key | Used by | Notes |
|---|---|---|
| `BOOMI_USERNAME` | Connectors API | Your Boomi platform username (email) |
| `BOOMI_API_TOKEN` | Connectors API | Settings → My User Settings → Platform API Tokens |
| `BOOMI_ACCOUNT_ID` | Connectors API | Settings → Account Information |
| `BOOMI_API_URL` | Connectors API | Typically `https://api.boomi.com` |
| `BOOMI_TIMEOUT` | Connectors API | Optional; request timeout in seconds (default 60) |
| `BOOMI_VERIFY_SSL` | Connectors API | Optional; set `false` to skip TLS verification |

The scripts parse `.env` rather than executing it: they read the keys above, ignore every other key, and never expand a value — so a `.env` shared with another Boomi Companion skill works untouched. Single-quote any value containing spaces or shell characters; one that needs it is refused with a line number rather than loaded in a corrupted form.

Publishing connectors additionally requires the account to have a signed SDK Publisher Agreement and the user to hold the DEVELOPER privilege. Run `connectordev-env-check.sh` to verify access.

Building connectors locally requires a JDK and Gradle — the supported build path, and the one Boomi recommends. Maven guidance is best-effort. Connectors emit Java 8 bytecode regardless of the JDK used to build them; the supported JDK/Gradle pairing is in `references/build_and_package.md`. Live testing and debugging require a local Runtime (Atom) on a machine you control — shared cloud runtimes can execute a published connector but do not support archive swapping or remote debugging.

Allowlist the skill and its scripts in the workspace's `.claude/settings.json` under `permissions.allow`:

- `Skill(bc-connectordev:boomi-connectordev)`
- `Bash(bash */skills/boomi-connectordev/scripts/*)`
- `Bash(./gw:*)` — the connector project's Gradle launcher, run from the project directory
