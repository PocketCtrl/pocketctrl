# Contributing to PocketCtrl

Thanks for helping improve PocketCtrl.

## Contribution terms

Before a contribution can be merged, its author must read and agree to the [Contributor License Agreement](CLA.md). The pull-request template records this confirmation.

Contributions to the public client and core are released under MPL-2.0. The CLA does not transfer ownership of your contribution; it gives the PocketCtrl project the additional permissions needed to maintain a consistent licensing model and preserve flexibility for official versions.

## Development checks

Before opening a pull request, run:

```bash
swift build --product pocketctrl
```

For native app changes, also build the affected Xcode schemes with code signing disabled or run them on an appropriate simulator/device.

## Pull requests

- Keep changes focused and explain the user-visible behavior.
- Add tests for protocol, framing, parsing, and security-sensitive behavior.
- Do not commit secrets, signing material, personal network addresses, generated build output, or user-specific Xcode data.
- Document changes to ports, wire formats, pairing, permissions, or trust assumptions.

Security reports should follow [SECURITY.md](SECURITY.md), not the public issue tracker.
