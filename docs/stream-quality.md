# Stream quality

iPhone/iPad Settings offers only two continuous sliders, Detail and FPS, with
an automatic quality label beside the title. The Mac viewer's toolbar dropdown
opens the same controls in a popover. Both remember their own slider positions.
Rebuild/update both apps to use the settings end to end.

| Preset | Capture-width cap | Target fps | H.264 video budget |
| --- | --- | --- | --- |
| Saver | 1280 px | 20 | 2 Mbps |
| Balanced | 1600 px | 30 | 6 Mbps |
| Smooth | 1600 px | 60 | 9 Mbps |
| Max | Host's capture limit | 60 | 30 Mbps |

The table shows the legacy preset anchor points, not buttons in the mobile UI.
Detail moves continuously from 0–100%, and FPS from 3–60 (rounded to whole fps
only when sent to the Mac). Resolution and bitrate interpolate between the
legacy anchors. Fractional slider positions are saved across launches, and old
presets/stepped values migrate without losing the user's selection.

At 0% detail and 3 fps, capture width is capped at 992 pixels and the H.264
video budget is 0.3416 Mbps (2.562 MB/min, 0.15372 GB/hour before overhead).
The minimum detail matches the previous curve's 10% detail setting.
At 5 fps its budget is about 0.569 Mbps (4.27 MB/min, 0.2562 GB/hour).
This trades small-text readability for lower data use. The bottom quarter of
the Detail slider interpolates up to the unchanged 1280-pixel anchor;
settings at 25% detail and above keep their existing resolution and budgets.
The curve increases continuously through 5, 10 and 15 fps; legacy preset budgets
are unchanged. Small usage values retain extra decimal places in the readouts.

The mobile label is derived from normalized slider positions: Max when both
are at least 90%; Smooth when FPS exceeds detail by at least 20 percentage
points; Sharp for the reverse; Saver when their average is below one third;
otherwise Balanced. Names describe the requested balance, not measured speed.

These are requested ceilings, not guaranteed performance. The Mac's capture
width, frame rate, and bitrate remain upper bounds. With multiple viewers, one
shared encoder uses the most restrictive requested limit in each dimension.
Adaptive mode may reduce bitrate and frame rate further when the network is
struggling. Turning adaptive mode off does not override a viewer's limits.

Video usage estimates convert the requested bitrate to decimal MB/min and
GB/hour in both readouts. They exclude audio, packet/encryption overhead, and VPN overhead and
are not a cellular data limit. Actual video use is also shown while connected.
Static screens and HEVC fallback can consume less; encoder peaks may consume
more than the nominal average budget.

## Verification

Run `zsh script/test_stream_quality.sh` for the production model, feedback codec,
multi-viewer aggregation, timestamp pacer, and host adaptation regression tests.
Tests don't start capture, access app credentials, or change app permissions.

Before release, test a moving desktop on a real iPhone and Mac:

1. Compare Detail 50% / FPS 30 with Detail 50% / FPS 60 on a good network.
2. Select 45 fps and verify the moving stream approaches 45, not 30.
3. Change only Detail; quit/reopen the phone app and check both slider values.
4. Change only FPS during a session; capture should not restart. Detail changes
   may briefly refresh capture while the encoder resolution changes.
5. Leave the screen still, then interact: lower idle fps is expected; motion
   should resume at the active target unless network backoff is required.
6. Repeat with adaptive mode off, then with two viewers using different limits.
7. Verify portrait/landscape settings on a small iPhone, iPad, and larger text.
8. Select 3 fps at minimum detail; verify moving content approaches 3 fps and
   both slider positions survive relaunch on phone and Mac.

Older Mac hosts safely fall back to known presets but cannot honor the new
custom numeric limits or Smooth preset. Update the Mac companion first.
