# Security policy

## Supported versions

Security fixes are made on the latest `main` branch only.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's **Security → Report a vulnerability** flow for the `PocketCtrl/pocketctrl` repository. Include affected versions, reproduction steps, impact, and any suggested mitigation.

Please allow a reasonable amount of time for triage and a coordinated fix before public disclosure.

## Current security model

- Pairing is closed by default. Opening it creates a 12-character, short-lived invitation; the QR and Computer Code represent the same invitation and expire together.
- A pairing request does not grant access. The Mac owner must review the route and requesting-device fingerprint, choose explicit capabilities, and authenticate with Local Authentication.
- Each approved device receives a separate random credential. Unattended credentials can be revoked individually; session-only credentials are discarded when hosting stops.
- Screen video, system audio, control input, and clipboard payloads use ChaChaPoly authenticated encryption with channel-separated keys derived from the device credential. Pairing responses use ephemeral Curve25519 key agreement and ChaChaPoly.
- Screen viewing is the base permission. Remote input, clipboard, and audio are separate capabilities and default off for new device approvals. Host-wide settings do not grant access to an unapproved device.
- Bonjour advertises routing metadata only. It never advertises a device credential or grants access.
- Pairing rejects invalid proofs and rate-limits repeated failures. Keep pairing closed except while adding a device you physically control.
- The optional host-control API binds to `127.0.0.1` and uses a separate random bearer token stored in the Mac Keychain. Installing the optional CLI also writes a copy to `~/Library/Application Support/PocketCtrl/cli-control-token`, with directory permissions 0700 and file permissions 0600. Processes running as your user can read this copy. Never publish it or expose the API to a network.
- Release builds store persistent credentials in the non-synchronizing, device-only, when-unlocked Keychain. Locking the device does not revoke credentials already loaded in memory. Mac Debug builds can use the login Keychain when data-protection entitlements are unavailable.

## Optional Computer Use

Computer Use is disabled by default and requires a separate per-device grant
in addition to remote-input permission. Existing paired devices do not receive
this grant automatically.

When enabled, task instructions, screenshots, and limited focused-control context
are sent to OpenAI using an API key stored in the host Mac's Keychain. On-device
speech transcription can supply instructions; speech audio is not sent to OpenAI.
See [Computer Use privacy notes](docs/privacy-policy.md).

The feature requires a supervising viewer and pauses when supervision is lost.
Approvals, screen validation, and Stop reduce risk but are not a security boundary
against every model mistake or prompt-injection attack. Keep sensitive content
closed and supervise every task.

PocketCtrl has not received a professional independent security audit. Use Tailscale rather than exposing raw PocketCtrl ports to the public internet.
