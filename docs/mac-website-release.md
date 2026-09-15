# PocketCtrl: Mac website release

For updater-enabled builds, also follow [Mac in-app updates](mac-updates.md).
Every new Latest GitHub release must include the signed-update `appcast.xml`
generated from its final notarized DMG, as well as the download and checksum.

The full native Mac app (host, viewer, login item, CLI, agent skill installer) is distributed
directly from the website. The iOS app can be released independently on the App Store.
Keep both targets in Xcode. Leave the macOS App Store Connect version in Prepare for Submission;
do not add it for review. A previously uploaded Mac build does not require you to release it.
Apple only allows deleting a platform before a build has ever been uploaded for it.

## One-time signing setup

Creating a Developer ID profile requires access to Certificates, Identifiers & Profiles
on the intended Apple Developer team. Ask the account owner for access if needed.

1. In Xcode → Settings → Accounts, sign in to the intended developer team.
2. Under Manage Certificates, obtain a **Developer ID Application** certificate with its private key.
   An Apple Development or Apple Distribution certificate is not a substitute. No Developer ID
   Installer certificate is needed for our DMG/ZIP distribution.
3. In Certificates, Identifiers & Profiles, use the existing explicit Mac App ID
   `app.pocketctrl.mac`. Create a **Developer ID** provisioning profile for this ID and certificate,
   download and install it in Xcode. Record its profile name or UUID.
   The profile must authorize the app identifier and its own Keychain access group.
   Keep the existing team / App ID prefix for releases and updates; changing identity can affect
   Keychain access and system privacy permissions.
4. Store notarization credentials in Keychain, interactively, without putting passwords in this repo:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun notarytool store-credentials PocketCtrl-Notary
   ```

   Follow Apple's prompts for Apple ID, team, and an app-specific password (or use supported API-key
   authentication). Do not paste credentials into chat or commit them to scripts.

The app intentionally keeps the data-protection Keychain. It does **not** silently fall back to
the login Keychain in Release. The website configuration supplies the app's Keychain entitlement;
the distribution profile must authorize it. The Debug fallback does not prove Release pairing works.

## Build and package

From the native repo root:

```sh
bash script/release_mac.sh preflight
PROFILE_NAME="Your installed Developer ID profile name" bash script/release_mac.sh archive
```

The archive command prints the exact `.app` path. Then:

```sh
NOTARY_PROFILE=PocketCtrl-Notary bash script/release_mac.sh package "/path/printed/above/PocketCtrl.app"
```

`archive` is local. `package` uploads that build to Apple's notary service, waits for acceptance,
staples and validates the ticket, checks Gatekeeper, and creates a final ZIP plus a signed,
separately notarized drag-to-Applications DMG, each with a SHA-256 file under
`release-output/`. It does **not** upload to the website, GitHub, Vercel, or App Store Connect.
If notarization fails, inspect the submission using `xcrun notarytool log` before retrying.

The DMG layout step uses Finder and needs a logged-in Mac desktop. If macOS asks,
allow your terminal to control Finder. Packaging only arranges its temporary installer
volume; it does not install or launch PocketCtrl. The DMG contains the same universal app
and an Applications shortcut, with no administrator installer required.

To wrap an already notarized, stapled app without rebuilding or re-notarizing the app itself:

```sh
NOTARY_PROFILE=PocketCtrl-Notary bash script/package_mac_dmg.sh "/path/to/notarized/PocketCtrl.app"
```

This still signs and notarizes the new DMG container. Keep existing ZIP assets available
for compatibility; only change the website URL/checksum after uploading and testing the DMG.

The scripts use the full Xcode at `/Applications/Xcode.app` without changing `xcode-select` globally.
Set `DEVELOPER_DIR` if Xcode is elsewhere. The public project does not store an Apple Developer team:
`archive` reads `TEAM_ID` from the environment or `DEVELOPMENT_TEAM` from the untracked
`PocketCtrlNative/Config/Local.xcconfig` (copy `Local.xcconfig.example`). `SIGN_IDENTITY` can select
another authorized signing identity when intentionally needed.
No automatic provisioning changes are made. The archive uses `distribution/macos/Website.xcconfig`
and `Website.entitlements`, leaving the normal Mac Debug build and iOS target untouched.

Each run gets a separate directory. Existing archives/downloads are not overwritten. Keep the
archive and dSYMs privately for symbolication. Never distribute `notary-upload.zip`: the final ZIP
is regenerated after stapling. Bump the Mac version/build in Xcode before each release.

## Test the actual release before publishing

Use the notarized app, not Xcode's Debug copy. Quit other PocketCtrl copies first.
Do not delete your development data to test: use a separate macOS account or spare Mac.

- Download the final DMG through a browser (so quarantine/Gatekeeper is actually exercised), open it,
  drag PocketCtrl to its Applications shortcut, eject the installer, and open PocketCtrl from Applications
  with normal macOS security settings. Do not use `xattr -d` or disable Gatekeeper.
- Fresh installation: onboarding, Screen Recording, Accessibility, Local Network acceptance/denial and recovery.
- Pair a device with unattended access, quit/reopen both apps, and reconnect. Verify there are no
  Keychain write/verify errors. Test screen locking/unlocking separately; credentials retain their existing device-only, when-unlocked policy.
- Local Wi-Fi without Tailscale, Tailscale remote connections, code/QR/link pairing, input, clipboard,
  audio, multiple viewers, sleep/wake recovery and keep-awake behavior.
- Launch at login from the installed Applications copy. Check optional CLI install/uninstall and
  `pocketctrl status`; agent skill installation must preserve unrelated user files.
- Upgrade an installed signed version by quitting and replacing it with the next signed version.
  Verify saved pairings, permissions and login behavior. Upgrades do not intentionally reset any data.
- Test Intel and Apple silicon hardware, and the oldest supported macOS (15.6). The script requires
  a universal arm64/x86_64 binary; that check does not substitute for hardware testing.

## Publish and connect the website

1. Upload the final notarized DMG and its `.sha256` to a public HTTPS download host.
   The notarized ZIP and its checksum may also remain available as an alternative.
   A versioned GitHub Release asset is a suitable option once the repository is public.
   Do not publish the private `.xcarchive`, certificates, profiles, or credentials.
   Make the corresponding MPL-2.0 source and license available for that release.
2. In the **separate PocketCtrlWebsite repo / Vercel project**, configure:
   - `POCKETCTRL_MAC_DOWNLOAD_URL`: permanent public HTTPS URL of that exact DMG, not a release HTML page.
   - `POCKETCTRL_MAC_VERSION`: its marketing version, e.g. `1.0`.
   - `POCKETCTRL_MAC_SHA256`: the 64-character checksum printed in the `.sha256` file.
3. Deploy the website. `/download` then enables its download button; no URL means a coming-soon page.
   Changing release environment variables requires a redeploy. Test the public link and checksum.
4. In iOS App Review notes, point reviewers to the public Mac download and pairing/setup guide.
   Do not tell them to get the Mac host from the Mac App Store.

Version 1.0 requires a manual upgrade. Updater-enabled versions use Sparkle for
user-initiated installation and relaunch; follow [Mac in-app updates](mac-updates.md)
to generate and publish their signed update feed. No payment service is included.

## References

- [Apple: Developer ID distribution](https://developer.apple.com/developer-id/)
- [Apple: notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple: platform deletion](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms)
- [Apple: platform versions are submitted separately](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/overview-of-submitting-for-review)

## Verification limits

Run the signing, notarization, stapling, and Gatekeeper checks for each release.
Unsigned builds and metadata tests do not prove signed-release Keychain behavior
or runtime permission handling. Test the actual notarized download using the
checklist above before publishing it.

Keep certificates, private keys, provisioning profiles, notarization credentials,
archives, dSYMs, and private test logs outside published source. A successful
previous release does not establish that a newly built artifact is ready.
