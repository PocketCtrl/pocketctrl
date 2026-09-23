# PocketCtrl

PocketCtrl is a free, open-source, native remote desktop client for controlling a Mac from another Mac, iPhone, or iPad. It connects your devices directly over your own Wi-Fi or Tailscale network, with no account required.

Created by Kylan O'Connor at [Iterative](https://tryiterative.com), which owns and maintains the official PocketCtrl project.

The `main` branch may contain features not yet included in published releases. Screen, audio, control, and clipboard traffic are encrypted and authenticated with a per-device credential, but the protocol has not received a professional independent audit. Do not expose PocketCtrl's raw ports to the public internet; use a local network or Tailscale.

## Repository layout

- `PocketCtrlNative/` — macOS host/viewer and iPhone/iPad app targets.
- `Sources/PocketCtrlHostCLI/` — optional command-line control utility for the running Mac app.
- `mcp/` — local MCP integration for controlling the Mac host.

## Requirements

- macOS 15.6 or newer for the native Mac app
- Xcode 26 or newer to build the native apps (website release checked with Xcode 26.5)
- Screen Recording permission on the host Mac
- Accessibility permission when remote input is enabled

## Quick start

Build the optional command-line control utility:

```bash
swift build --product pocketctrl
```

After launching the Mac app, choose **PocketCtrl > Settings > Command Line > Install CLI** to install the `pocketctrl` command in `/usr/local/bin`. The app requests administrator approval for the installation and configures the local control credential automatically.

The same settings pane can install PocketCtrl's portable [Agent Skill](PocketCtrlNative/PocketCtrl/AgentSkills/pocketctrl/SKILL.md) for Codex or Claude Code. The skill contains no credentials; it teaches local agents to use the installed CLI and handle pairing or state-changing commands carefully.

Open the native apps:

```bash
open PocketCtrlNative/PocketCtrl.xcodeproj
```

See [PocketCtrlNative/README.md](PocketCtrlNative/README.md) for app setup.

## Optional Computer Use

The development version includes supervised OpenAI Computer Use from the
iPhone/iPad viewer's robot button: tap to type, or hold to speak and release to
send an on-device transcription. It requires your own OpenAI API key on the host
Mac and a separate Computer Use grant for the paired device. Choose GPT-6 Luna,
Sol, or Astra and a supported thinking level before sending a task. This optional
feature sends screen content and task instructions to OpenAI; ordinary remote
desktop connections do not require it. See [setup and limitations](docs/computer-use.md).

## Distribution

The full Mac app is distributed through the [PocketCtrl website](https://www.pocketctrl.com/download),
separately from the iOS App Store release. See [Mac website release](docs/mac-website-release.md)
for the Developer ID signing, provisioning, notarization, packaging, and release-testing workflow.
Published downloads may differ from the development version described here. Use the
release notes to check which features a downloaded build includes.

## Security

Remote-control software has a large security surface. Please read [SECURITY.md](SECURITY.md) before deploying PocketCtrl or reporting a vulnerability. Pair only with devices you trust, keep local discovery disabled when it is unnecessary, and use view-only mode unless remote input is needed.

Never commit device credentials, signing certificates, provisioning profiles, `.env` files, captures, diagnostics, or generated service configuration. Both the root and native-project `.gitignore` files exclude these common private artifacts.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development checks and contribution terms.

## License

PocketCtrl's public client and core are available under the [Mozilla Public License 2.0](LICENSE). See [LICENSING.md](LICENSING.md) for the exact boundary. PocketCtrl's name, icon, official builds, website identity, and PocketCtrl Network branding are covered separately by the [trademark guidelines](TRADEMARKS.md).

## Project stewardship

PocketCtrl was created by Kylan O'Connor at Iterative, which owns and manages the project. See [GOVERNANCE.md](GOVERNANCE.md) for the project's stewardship and decision-making model.
