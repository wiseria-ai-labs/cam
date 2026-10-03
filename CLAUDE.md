# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

CAM is a macOS menu bar app. It keeps more than one Claude Code login on one Mac. It switches the active login and shows the 5-hour and 7-day usage of each account.

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
- The left rail shows one item for each agent (`Agent.all`). Only Claude Code works now. Codex and Kimi Code have `soon` set and show as placeholders. The agent logos come from simple-icons (CC0).

### Token usage

The session logs of Claude Code (`<configDir or ~/.claude>/projects/**/*.jsonl`) do not record the account. CAM records this data itself in `~/Library/Application Support/cam/`. With `configDir`, the files are `<configDir>/cam-*`.

| File | Content |
|---|---|
| `timeline.json` | The time of each change of the active account. |
| `procs.json` | The `claude` processes that ran at a switch. The authentication stays with the process, so these processes use the old account until they stop. |
| `daily.json` | The token total for each day and each account. The CLI deletes logs after 30 days, so the heat map uses this archive. |

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
- Keep the code in the current two source files. Add a file only when the reason is clear.
