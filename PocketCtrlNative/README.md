# PocketCtrl native apps

This folder contains the Xcode project for PocketCtrl's native apps:

- **`PocketCtrl`** — the macOS app. It is both the host (shares this Mac's screen and accepts control) and a Mac viewer (connects to another Mac). It also installs the optional `pocketctrl` command-line tool and the agent skill.
- **`PocketCtrlMobile`** — the iPhone and iPad viewer app.

Both targets live in `PocketCtrl.xcodeproj` with shared schemes of the same names. Requirements and the top-level quick start are in the [repository README](../README.md). Read [SECURITY.md](../SECURITY.md) before hosting on a Mac you care about.

## How connecting works

PocketCtrl has no account and no cloud service. Devices pair directly and then talk to each other over your own network.

1. **Open pairing on the Mac.** Pairing is closed by default. Opening it creates a 12-character **Computer Code**, a QR code, and a `pocketctrl://` pairing link. All three represent the same short-lived invitation and expire together. An invitation carries connection details only; it cannot grant access by itself.
2. **Request from the viewer.** On iPhone or iPad, scan the QR code or type the Computer Code. On a Mac viewer, paste the pairing link or upload a QR screenshot. The viewer immediately looks for the host over local Wi-Fi and Tailscale.
3. **Approve on the Mac.** The host shows the requesting device's fingerprint and route. The Mac owner chooses what the device may do and authenticates with Touch ID or password. Capabilities are per device:
   - **Screen viewing** — always included.
   - **Remote input**, **clipboard**, and **audio** — separate, default off.
   - **Unattended** access (credential kept for later reconnects) or **session-only** access (credential discarded when hosting stops or the Mac app restarts).
4. **Connect.** The viewer receives its own random credential. Every later connection is authenticated with it and can be revoked individually from the Mac.

Bonjour (`_pocketctrl._udp`) advertises routing metadata only, so viewers can find a host on the same subnet. Away from home, install [Tailscale](https://tailscale.com) on both devices and join the same tailnet; PocketCtrl picks local Wi-Fi when the devices share a subnet and otherwise uses Tailscale. Never forward PocketCtrl's raw UDP ports to the public internet.

## Mac app (`PocketCtrl`)

Hosting:

- ScreenCaptureKit capture of a selected display, VideoToolbox H.264 encoding, and system audio.
- Per-viewer credentials; all video, audio, control, and clipboard traffic is authenticated and encrypted (ChaChaPoly with channel-separated keys).
- Remote input injected with CoreGraphics events, gated per device by the approval above.
- Capture width, frame rate, and bitrate ceilings; adaptive bitrate lowers quality under loss and recovers when the network stabilizes. Multiple viewers share one encoder at the most restrictive requested limits.
- Keep-awake while hosting, auto-start hosting, and launch at login.
- Trusted-device list with individual revocation and a live list of connected viewers.
- Diagnostics for Screen Recording, Accessibility, and Local Network permission state.

Viewing another Mac:

- Saved computers, pairing by link or QR screenshot, and the same Detail / FPS quality controls as the mobile app (see [docs/stream-quality.md](../docs/stream-quality.md)).
- View-only by default; remote control, pointer capture, clipboard, and audio are explicit toggles and only work if the host approved them for this device.

Automation:

- **Settings → Command Line** installs the `pocketctrl` CLI into `/usr/local/bin`. It talks to a loopback-only control API on `127.0.0.1:47777` protected by a random bearer token in the Keychain. See the [top-level README](../README.md) and [mcp/README.md](../mcp/README.md).
- The same pane installs the portable [agent skill](PocketCtrl/AgentSkills/pocketctrl/SKILL.md) for Codex or Claude Code.

## iPhone and iPad app (`PocketCtrlMobile`)

- QR scanner and Computer Code entry for pairing, with automatic local Wi-Fi / Tailscale route selection and a guided Tailscale setup when needed.
- Saved Macs on the home screen, with Wake-on-LAN for Macs on the same network.
- Full-screen remote view; drag to move the pointer, on-screen trackpad, left/right click controls, and a keyboard with typing sent to the Mac.
- Voice typing: on-device speech recognition turns dictation into text typed on the Mac.
- Optional audio playback when the host approved audio for this device.
- Detail and FPS sliders with a data-usage estimate; positions persist across launches.
- Clear recovery messaging when Local Network permission is denied or the Mac is unreachable.

Requires iOS or iPadOS 18 or newer.

## Permissions the host Mac needs

- **Screen Recording** — requested by macOS the first time capture starts.
- **Accessibility** — required only when remote input is enabled; the app prompts when hosting starts.
- **Local Network** — for Bonjour discovery and same-subnet connections.

The Diagnostics area shows the current state of each and offers prompt buttons. If you change a permission in System Settings while the app is running, quit and reopen PocketCtrl.

## Building

```bash
open PocketCtrl.xcodeproj
```

Select the `PocketCtrl` scheme for the Mac app or `PocketCtrlMobile` for a simulator or device.

The project does not include an Apple Developer team. To run on your own devices, copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` to your team ID; that file is gitignored. Command-line builds with `CODE_SIGNING_ALLOWED=NO` (what CI does) need no team:

```bash
xcodebuild -project PocketCtrl.xcodeproj -scheme PocketCtrl -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

`script/build_and_run.sh` at the repository root builds the Debug Mac app and launches it, optionally with lldb or a live log stream.

Both apps store credentials in the device-only, non-synchronizing Keychain. Mac Debug builds may fall back to the login Keychain when data-protection entitlements are unavailable; this fallback does not prove that a Release build's Keychain behavior works. See [docs/mac-website-release.md](../docs/mac-website-release.md) for signing, notarization, and release testing.

## Testing on one Mac

The Mac app can host and view at the same time, which is the fastest way to exercise the pipeline:

1. Start hosting and open pairing.
2. In the viewer section of the same app, paste the pairing link.
3. Approve the request in the host section and connect.

Host and viewer counters (packets, chunks, frames, bytes, dropped frames, input events) update live and are useful when diagnosing network problems.

## Network safety

PocketCtrl encrypts and authenticates its media and control channels with a per-device credential, but it is pre-release remote-control software without a professional independent audit. Keep pairing closed except while adding a device you physically control, prefer Tailscale away from home, and never expose PocketCtrl's ports directly to the public internet.
