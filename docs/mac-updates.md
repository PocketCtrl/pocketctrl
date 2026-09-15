# Mac in-app updates

The native Mac target uses Sparkle 2.10+ for user-initiated, signed updates.
Settings → General → About and the PocketCtrl menu offer **Check for Updates…**.
Sparkle downloads the update, asks the user to install, replaces the app, and
relaunches it. Installing disconnects active sessions. Hosting resumes according
to the user's existing start-hosting preference. Xcode Debug builds disable the
updater so development copies cannot replace themselves with public releases.

There are no scheduled update checks or system profiling enabled by default.
Checking contacts GitHub, which receives normal network request metadata.

## Release procedure

1. Increase the Mac `CFBundleVersion` for every update (Sparkle compares build
   numbers), and set its marketing version. Leave the iOS version alone.
2. Archive, sign, notarize and package using `script/release_mac.sh` and the
   existing website release guide. Verify the bundled Sparkle framework and
   helpers are signed correctly; do not publish if notarization fails.
3. Locate Sparkle's `bin` directory in the resolved Xcode package artifacts,
   or use the matching official Sparkle distribution. Then run:

   ```sh
   SPARKLE_BIN=/path/to/Sparkle/bin bash script/generate_mac_appcast.sh \
     /path/to/PocketCtrl-1.0.1-2-mac.dmg v1.0.1
   ```

4. Upload the final DMG, checksum, and generated **appcast.xml** to the same
   draft GitHub release. Its tag must match the command. Do not edit the DMG
   after signing the appcast. Publish and mark Latest only when ready.
5. Verify the feed at
   `https://github.com/PocketCtrl/pocketctrl/releases/latest/download/appcast.xml`
   and its enclosure download URL, then update the website's download variables.
   Every future Latest release must carry appcast.xml, including iOS-related
   releases if they become this repository's Latest release.

The private Ed25519 key lives in the release Mac's login Keychain under account
`app.pocketctrl.mac`. Only the public key belongs in Info.plist. Keep a secure
backup outside Git; never paste or commit the private key. A different publisher
or fork must configure its own feed and key. Do not casually regenerate the key.

## Bootstrap and testing

The already-published 1.0 app has no updater. Users must manually install the
first updater-enabled release once. A feed is not published by merely adding
this code: until the next release includes appcast.xml, release-build checks
will report a feed error.

Before shipping, exercise a real older-to-newer signed/notarized update from
an installed writable Applications copy, preferably on a separate test Mac:
check, cancel, download, Install and Relaunch, version change, preserved pairing
and settings, hosting startup policy, offline errors, and an invalid signature
being rejected. Do not modify a signed bundle's version in place to fake this
test. Compilation alone does not verify the installer/relaunch path.
