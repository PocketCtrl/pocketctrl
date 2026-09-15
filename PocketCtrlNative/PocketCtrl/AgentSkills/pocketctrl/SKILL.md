---
name: pocketctrl
description: Inspect and control the PocketCtrl host on this Mac with the installed pocketctrl CLI. Use for PocketCtrl hosting status, pairing, stream settings, remote input, audio, discovery, or launch behavior.
license: MPL-2.0
metadata:
  author: PocketCtrl
  version: "1"
---

# PocketCtrl

Use the installed `pocketctrl` command to inspect or control the PocketCtrl host running on this Mac.

## Workflow

1. Check that the CLI is available with `command -v pocketctrl`. If it is unavailable, tell the user to open **PocketCtrl > Settings > Command Line** and install the CLI.
2. Run `pocketctrl status` before changing host state or settings unless the user has already supplied current status output.
3. Make only the changes the user requested. Do not infer permission to start, stop, restart, reconfigure, or regenerate anything from a request for information.
4. Report the resulting state clearly. After a state-changing command, use `pocketctrl status` when verification would be useful.

## Commands

- `pocketctrl status` — inspect host status and current settings.
- `pocketctrl start` — start hosting.
- `pocketctrl stop` — stop hosting.
- `pocketctrl restart` — restart hosting.
- `pocketctrl set <key> <value> [...]` — update settings such as `fps`, `bitrate`, `remote-input`, `audio`, `adaptive-bitrate`, `keep-awake`, `auto-start`, `launch-at-login`, `local-discovery`, or `display`.
- `pocketctrl pairing` — display current pairing information.
- `pocketctrl regenerate-pairing` — replace the current pairing credential.
- `pocketctrl help` — show the current CLI syntax.

## Safety

- Treat pairing output as sensitive. Run `pocketctrl pairing` only when the user asks for pairing information, and do not persist or repeat secrets unnecessarily.
- Regenerating pairing information can invalidate existing setup. Run `pocketctrl regenerate-pairing` only when the user directly requests that action.
- Enabling remote input permits mouse and keyboard control. Change it only when directly requested.
- Never read, print, copy, or modify PocketCtrl's control-token file. The CLI handles its credential internally.
- Do not set or override `POCKETCTRL_CONTROL_TOKEN` or `POCKETCTRL_HOST_URL`. The installed CLI is intentionally restricted to the local PocketCtrl app.
