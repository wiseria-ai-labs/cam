# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

CAM is a macOS menu bar app. It keeps more than one Claude Code or Kimi Code login on one Mac. It switches the active login and shows the 5-hour and 7-day usage of each account.

## Commands

| Task | Command |
|---|---|
| Run the CLI | `.build/debug/cam list` or `.build/debug/cam switch <email or uuid prefix>` |
| Run one test | `swift test --filter switchKeepsRotatedTokensAndMcpOAuth` |
| Make a release DMG | `scripts/release.sh <version>` |

`scripts/release.sh` builds a universal app and signs it with the Developer ID of Wiseria LLC. It writes `dist/CAM-<version>.dmg`. It also notarizes the DMG with the `notarytool` keychain profile `cam-notary`. To use a different profile, set `NOTARY_PROFILE`. To skip notarization, set `NOTARY_PROFILE` to an empty value.

## Architecture

### Login state of Claude Code

The Claude Code login has two parts. `Store` reads and writes both parts.

| Part | Location |
|---|---|
| OAuth credentials | Keychain item `Claude Code-credentials`. The JSON has `claudeAiOauth` and `mcpOAuth`. |
| Account profile | The `oauthAccount` field in `~/.claude.json`. |

If `configDir` is set, the Keychain item name gets the suffix `-<first 8 hex chars of sha256(configDir)>`. The config file moves to `<configDir>/.claude.json`. These rules copy Claude Code 2.1.287. They are not a public API. If a new CLI version changes them, examine the CLI binary again.

### Login state of Kimi Code

The Kimi Code login is one file. `KimiStore` reads and writes it.

| Part | Location |
|---|---|
| OAuth credential (`access_token` 15 min / `refresh_token` 30 days rolling) | `~/.kimi-code/credentials/kimi-code.json` (0600) |

`config.toml` references it as `[providers."managed:kimi-code".oauth] storage="file" key="oauth/kimi-code"`. These rules copy Kimi Code CLI 2.1.1. They are not a public API either.

- The account id is the `user_id` claim of the access-token JWT, decoded without verification. Region (`cn`/`global`) also comes from the JWT.
- The CLI re-reads the credential file on every use and coordinates refreshes across processes with a proper-lockfile lock. CAM takes the same lock (sentinel `~/.kimi-code/oauth/kimi-code`, lock dir its `.lock`, stale 5s, 60s deadline) and re-reads the file after acquiring it. Unlike Claude, a running `kimi` session picks up a switched account within minutes — no process table needed.
- Refresh: `POST {auth.kimi.com\|auth.kimi.ai}/api/oauth/token`, form `client_id=17e5f671-…&grant_type=refresh_token&refresh_token=…` plus the `X-Msh-*` device headers (`device_id` from `~/.kimi-code/device_id`). The server always rotates the refresh token; the whole response must be written back.
- Quota: `GET {api.kimi.com\|api.kimi.ai}/coding/v1/usages` → `usages.limit_5h / limit_7d / limit_month_total / limit_month_code` (`used_ratio` + `reset_time`) and `booster_wallet`. Profile: `GET …/me` → `nickname`, `user_level_name`. New plans have no 7-day window; fall back to monthly.
- Switching writes the target credential atomically. CAM keeps the lock mtime fresh every 2s while it holds the lock, like proper-lockfile's `update`; otherwise a refresh that takes more than 5s lets the CLI steal the lock.
- Only the mainland default slot is supported. A non-default host (global `auth.kimi.ai`) uses the slot `oauth/kimi-code-<sha256[0:16]>`, so the file is `credentials/kimi-code-<hash>.json` and the lock is `oauth/kimi-code-<hash>.lock`. `addViaLogin` rejects such a login. Global support needs `credPath`/`lockPath` derived from the `config.toml` key and the host switched too.
- Vault: Keychain item `CAMKimiAccounts`, JSON `[userId: {credential, profile}]`. Adding an account runs `kimi login` in a temporary `KIMI_CODE_HOME` with the real `device_id` and `region` marker pre-seeded; the CLI opens the browser itself and prints the device-code URL, which the UI shows if the browser did not open.

### Vault

The vault is one Keychain item with the name `ClaudeAccountManager`. Its JSON is `[accountUuid: {oauthAccount, claudeAiOauth}]`.

Do not rename the vault item. The project had the name ClaudeAccountManager before. A new name makes all saved accounts unavailable.

### Rules that prevent data loss

- Do all Keychain reads and writes through `/usr/bin/security`. Do not use the `SecItem` API. The Keychain items of the CLI trust `security`, so `security` gets access without a prompt.
- Write Keychain data as hex through `security -i` on stdin. End the command with a newline. Without the newline, `security -i` does not write and still exits with 0. If the command is longer than 4032 characters, use argv.
- Keep JSON as `[String: Any]`. Do not change it to `Codable` types. `Codable` removes the fields that the code does not know.
- When you change the active login, replace only `claudeAiOauth`. Keep `mcpOAuth` and all other fields.
- Before a switch, call `syncLive()`. The CLI rotates the refresh token. If the app does not save the new token, the vault copy becomes invalid.
- `syncLive()` uses `whoami` (`/api/oauth/profile`) to find the real owner of the live token. A running `claude` session can write the token of the old account after a switch.
- Write `.claude.json` to a temporary file with mode 0600. Then rename the file. The file can contain MCP secrets.
- Refresh tokens only for accounts that are not active. Do not refresh the token of the active account. That makes the refresh token of the CLI invalid.

### Add an account

`addViaLogin()` runs `claude auth login` in a temporary `CLAUDE_CONFIG_DIR` in `~/Library/Application Support/cam/`. The current login does not change. The process environment does not include `CLAUDE*` and `ANTHROPIC*` variables.

When the task is cancelled, the app stops the `claude` process. The **Quit** menu item cancels the login first. If it does not, the `claude` process continues to run after the app stops.

### User interface

- Use `NSStatusItem` with `NSPopover`. Do not use `MenuBarExtra`. A `MenuBarExtra` window does not change its height after the content changes.
- `Model.run` does one operation at a time. While `busy` is set, the UI disables all actions. This also keeps Keychain access serial.
- Show the switch and delete confirmations in the account row. The row keeps the same height, so the popover does not jump. Do not use alerts. An alert can close the popover.
- The UI does not let the user delete the active account. The next refresh imports the active account again.
- The panel has no footer. **Refresh** and **Quit** are in the right-click menu of the status item.
- The left rail shows one item for each agent (`Agent.all`). Claude Code and Kimi Code work. Codex has `soon` set and shows as a placeholder. The agent logos come from simple-icons (CC0).

### Token usage

The session logs of Claude Code (`<configDir or ~/.claude>/projects/**/*.jsonl`) do not record the account. CAM records this data itself in `~/Library/Application Support/cam/`. With `configDir`, the files are `<configDir>/cam-*`.

| File | Content |
|---|---|
| `timeline.json` | The time of each change of the active account. |
| `procs.json` | The `claude` processes that ran at a switch. The authentication stays with the process, so these processes use the old account until they stop. |
| `daily.json` | The token total for each day and each account. The CLI deletes logs after 30 days, so the heat map uses this archive. |
| `kimi-timeline.json` | Same as `timeline.json` for Kimi Code (`KimiStore` keeps its own because attribution is per agent). |
| `kimi-daily.json` | Same archive for Kimi Code. |

- Kimi Code token data comes from `usage.record` lines in `~/.kimi-code/sessions/*/*/agents/*/wire.jsonl` (`inputOther + output + inputCacheRead + inputCacheCreation`, `time` in ms). Forked sessions copy whole `wire.jsonl` files, so the dedup key is `agentId|time|tokens` without the session id.

- Remove duplicate log entries by message id. One response writes many lines, and a resumed session copies old lines.
- Overwrite a day in `daily.json` only if the new total is not less than the archived total. If the CLI deleted some logs, the new total is too small.

## Tests

The tests use the real login Keychain. They use temporary items with the name `cam-test-*` and a temporary `configDir`, and they delete these items at the end.

- Do not write tests that change the default `Claude Code-credentials` item.
- Set `whoami` in tests to stop network calls.
- `cancelLoginStopsQuickly` needs the `claude` CLI on the Mac. It puts a fake `open` command in `PATH`, so no browser opens.

Before you test on the real login, make a backup of the live Keychain item.

## Conventions

- Write code comments, UI text, and `README.md` in Simplified Chinese.
- Keep the code in the current three source files: `Store.swift` (Claude Code), `KimiStore.swift` (Kimi Code, added when Kimi support landed), and `App.swift` (shared UI). Add a file only when the reason is clear.
