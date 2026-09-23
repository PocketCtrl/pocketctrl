# Contributing to PocketCtrl

Thanks for helping improve PocketCtrl. Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

## Contribution terms

Before a contribution can be merged, its author must read and agree to the [Contributor License Agreement](CLA.md). The pull-request template records this confirmation.

Contributions to the public client and core are released under MPL-2.0. The CLA does not transfer ownership of your contribution; it gives the PocketCtrl project the additional permissions needed to maintain a consistent licensing model and preserve flexibility for official versions.

## Local setup

The Xcode project does not contain an Apple Developer team. To run the apps on your own devices, copy
`PocketCtrlNative/Config/Local.xcconfig.example` to `PocketCtrlNative/Config/Local.xcconfig` and set
`DEVELOPMENT_TEAM` to your team ID. That file is gitignored; never commit it or add a team to the project file.
Building with `CODE_SIGNING_ALLOWED=NO` (as CI does) needs no team.

Shared schemes for `PocketCtrl` (Mac) and `PocketCtrlMobile` (iPhone/iPad) are checked in under
`PocketCtrl.xcodeproj/xcshareddata`.

## Development checks

Before opening a pull request, run the same checks as CI:

```bash
swift build --product pocketctrl
zsh script/test_host_identity.sh
zsh script/test_stream_quality.sh
zsh script/test_network_endpoints.sh
zsh script/test_audio_session.sh
zsh script/test_speech_input.sh
zsh script/test_mac_pointer.sh
zsh script/test_computer_use.sh
zsh script/test_mac_transport_diagnostics.sh
bash script/test_mac_release.sh
```

The test scripts expect a full Xcode installation and default to `/Applications/Xcode.app`; set `DEVELOPER_DIR` if yours is elsewhere.

Computer Use tests use mock providers, an in-memory Keychain substitute, and recorded
input events. They do not require API keys, incur API charges, or control your desktop.
See [Computer Use](docs/computer-use.md) for setup, privacy considerations, and the
separate supervised runtime checks needed before distributing a build.

For native app changes, also build the affected Xcode schemes with code signing disabled or run them on an appropriate simulator/device.

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Add tests for protocol, framing, parsing, and security-sensitive behavior.
- Do not commit secrets, signing material, personal network addresses, generated build output, or user-specific Xcode data.
- Document changes to ports, wire formats, pairing, permissions, or trust assumptions.

Security reports should follow [SECURITY.md](SECURITY.md), not the public issue tracker.
