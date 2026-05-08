# Codex Notion Bridge

Codex Notion Bridge is a local macOS menu bar app that receives Notion comment webhooks through a Cloudflare named tunnel, verifies `X-Notion-Signature`, fetches comment/page context from Notion, filters for `@Codex` or `codex:`, runs local `codex exec`, and replies to the original Notion discussion with the result.

The app is SwiftPM-first and intentionally local-first. Notion write access is kept inside the bridge process; spawned Codex jobs do not receive the Notion API token.

## Build

```sh
swift build
swift test
swift run CodexNotionBridge
```

## First Run Checklist

1. Create or update a Notion integration with comment read and insert capabilities.
2. Share the target Notion pages/databases with that integration.
3. Configure a persistent Cloudflare named tunnel that routes to `http://127.0.0.1:8787`.
4. In the menu bar app settings, set:
   - Notion API token.
   - Codex binary path, defaulting to `codex`.
   - `cloudflared` path, defaulting to `cloudflared`.
   - Cloudflare tunnel name or tunnel token.
5. Create a Notion webhook subscription that points to:

```text
https://<your-tunnel-hostname>/notion/webhook
```

6. When Notion sends the verification token, the app stores it in Keychain and shows verified status.
7. Add a Notion comment that begins with `@Codex` or `codex:`.

## Data Locations

Secrets are stored in macOS Keychain under the service `CodexNotionBridge`.

Non-secret state lives under:

```text
~/Library/Application Support/CodexNotionBridge/
```

That folder contains config JSON, dedupe state, event/job logs, and per-job workspaces with prompt/output files.

## Cloudflare Tunnel

The app can start a named tunnel in either of these forms:

```sh
cloudflared tunnel --no-autoupdate run <name>
cloudflared tunnel --no-autoupdate run --token <token>
```

Quick tunnels are deliberately not part of v1 because Notion webhook URLs cannot be changed after verification without recreating the subscription.
