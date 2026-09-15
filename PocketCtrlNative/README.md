# PocketCtrl

PocketCtrl is a native remote desktop app for controlling your Mac from another Mac, iPhone, or iPad. The macOS app combines the Mac host and Mac viewer so local and remote workflows can be tested quickly.

The project also includes `PocketCtrlMobile`, an iOS starter target for the iPhone/iPad client.

## What Works

- ScreenCaptureKit desktop capture from a selected display.
- VideoToolbox H.264 encode and decode.
- LAN UDP video packetization and reassembly.
- Mac viewer video canvas with aspect-fit scaling.
- Mouse move, mouse down/up, right click, middle click, scroll, key down, and key up capture.
- Host-side CoreGraphics `CGEvent` injection.
- Input overlay constrained to the rendered video bounds so pointer coordinates match aspect-fit desktop video.
- View-only mode by default, with an explicit Remote Control toggle in the Viewer panel.
- Host display selection for multi-monitor setups.
- Capture width, FPS, and bitrate controls for Retina/network tuning.
- Viewer feedback over the control channel.
- Host adaptive bitrate updates through VideoToolbox without restarting capture.
- Automatic local-network and Tailscale route selection after secure device pairing.
- Per-device credentials, scoped approval, individual revocation, and session-only access.
- Application-layer authenticated encryption for screen, audio, control, and clipboard traffic.
- In-app diagnostics for Accessibility and Screen Recording permissions.
- Host/viewer health counters for packets, chunks, frames, bytes, skipped frames, and input events.
- Local-network permission description; the full Mac host is unsandboxed and distributed using Developer ID signing and notarization.

## Website distribution

The Mac app requires macOS 15.6 or later. Keep this Mac target in Xcode even though it is not
being submitted to the Mac App Store. Follow [the release guide](../docs/mac-website-release.md)
to build a universal, signed and notarized website download. The iOS target is released separately.

## Permissions

The host Mac needs:

- Screen Recording permission for PocketCtrl.
- Accessibility permission for PocketCtrl.

The app prompts for Accessibility trust when hosting starts. Screen Recording is handled by macOS the first time capture is attempted.

The Diagnostics panel shows the current state of both permissions and includes prompt buttons. If a permission was just changed in System Settings, quit and reopen PocketCtrl, then use Refresh Status.

## One-Mac Loopback Test

1. Open the app.
2. Leave both host and viewer addresses as `127.0.0.1`.
3. Start Viewer.
4. Start Host.

Default ports:

- Video: `5555`
- Input: `5556`

When loopback is working, the Host panel should show increasing frame/packet/byte counts, and the Viewer panel should show received chunks plus completed frames. Move or click inside the rendered desktop video: the Viewer panel should show sent input events, and the Host panel should show received input events.

Input is paused until Remote Control is enabled in the Viewer panel.

## Dynamic Bitrate

When Adaptive bitrate is enabled, the viewer sends fps and estimated frame-loss feedback back to the host over the input/control port. The host lowers the VideoToolbox target bitrate when loss or viewer frame drops rise, then cautiously raises it again when the connection stabilizes.

This is still a LAN feedback loop, not a full WebRTC congestion controller, but it is the macOS app hook needed for the critical Wi-Fi bottleneck.

## Retina And Multi-Monitor

The host display picker selects which Mac display to capture. Capture width controls the encoded stream width so a Retina display can be downscaled before H.264 encoding instead of trying to push every physical pixel over the network. The viewer keeps the decoded video aspect-fit inside the window for dynamic resizing.

If you change display, width, FPS, bitrate, or LAN address while a session is active, use Apply Host Changes or Apply Viewer Changes. The app restarts that side of the session cleanly with the new settings.

## Two-Mac LAN Test

On the viewer Mac:

- Set Viewer Host IP to the host Mac's LAN address.
- Start Viewer.

On the host Mac:

- Set Host Viewer IP to the viewer Mac's LAN address.
- Start Host.

Both Macs should use the same video and input port values.

## iOS Target

Open `PocketCtrl.xcodeproj` and choose the `PocketCtrlMobile` scheme to run the iOS app on a simulator or device.

The iOS target currently includes:

- A separate SwiftUI iPhone/iPad app target.
- LAN video/input connection fields.
- UDP video receive, frame reassembly, VideoToolbox H.264 decode, and UIKit rendering.
- A full-screen remote view where dragging on the desktop moves the Mac pointer.
- Bottom left/right click controls that click at the last finger position.
- A top-left settings sheet for changing Host IP, video port, and input port.

To test iOS video and input against the Mac host:

1. Run `PocketCtrlMobile` on the iPhone/iPad first.
2. Note the `This iPhone` IP shown at the top of the iOS app.
3. Leave Video as `5555`, Input Port as `5556`, set Host IP to the Mac's LAN IP, then tap Connect.
4. Run `PocketCtrl` on the Mac.
5. Set Host Viewer IP to the iPhone IP from step 2.
6. Leave Video as `5555` and Input as `5556`.
7. Start Host.

The iOS client must be listening before the Mac host starts streaming. If macOS or iOS asks for local network permission, allow it.

## Network Safety

PocketCtrl encrypts and authenticates its media and control channels with a per-device credential. It is still pre-release remote-control software without a professional independent audit. Keep pairing closed except while adding a device, prefer Tailscale away from home, and never expose PocketCtrl's raw ports directly to the public internet.
