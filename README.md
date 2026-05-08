# Codex Notion Bridge

Codex Notion Bridge is a local macOS menu bar app that receives Notion comment webhooks through Tailscale, verifies `X-Notion-Signature`, fetches comment/page context from Notion, filters for `@Codex` or `codex:`, runs local `codex exec`, and replies to the original Notion discussion with the result.

The app is SwiftPM-first and intentionally local-first. Notion write access is kept inside the bridge process; spawned Codex jobs do not receive the Notion API token.

## Build

```sh
swift build
swift test
swift run CodexNotionBridge
```

To run the same executable shape that a packaged app uses, run the signed debug
binary instead of `swift run`:

```sh
scripts/run-signed.sh
```

The script builds the SwiftPM product, signs the debug executable with the first
available Apple Development identity and a stable code-signing identifier, then
runs that signed executable directly. Set `CODE_SIGN_IDENTITY` to choose a
specific signing identity or `CODE_SIGN_IDENTIFIER` to override the identifier.

## First Run Checklist

1. Create or update a Notion integration with comment read and insert capabilities.
2. Share the target Notion pages/databases with that integration.
3. Let the app configure Tailscale Funnel on startup, or run it manually for the local app on port `7676`.
4. In the menu bar app settings, set:
   - Notion API token.
   - Codex binary path, defaulting to `codex`.
   - Tailscale CLI path, defaulting to `tailscale`.
5. Create a Notion webhook subscription that points to:

```text
https://<your-device>.<tailnet>.ts.net/notion/webhook
```

6. When Notion sends the verification token, the app stores it in the local secrets file and shows verified status.
7. Add a Notion comment that begins with `@Codex` or `codex:`.

## Data Locations

App state lives under:

```text
~/Library/Application Support/CodexNotionBridge/
```

That folder contains config JSON, `secrets.json`, dedupe state, event/job logs,
and per-job workspaces with prompt/output files. The secrets file stores the
Notion API token and Notion webhook verification token with `0600` file
permissions.

## Tailscale

The app reads the local MagicDNS name from:

```sh
tailscale status --json
```

Specifically, it uses `Self.DNSName` to display and copy the webhook URL. On
startup, the app asks Tailscale to configure Funnel for the local port:

```sh
tailscale funnel --bg --yes 7676
```

It also checks Funnel with:

```sh
tailscale funnel status --json
```

Funnel is considered correctly configured when one of its proxy targets forwards
to the configured local port, for example `http://127.0.0.1:7676`. MagicDNS and
Tailscale Serve are tailnet-only. For Notion to deliver webhooks from the public
internet, expose the local service with Tailscale Funnel or another public HTTPS
route.
