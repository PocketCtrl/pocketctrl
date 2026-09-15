// SPDX-License-Identifier: MPL-2.0
var checks = 0
func check(_ condition: Bool, _ label: String) {
    precondition(condition, label)
    checks += 1
}
for rect in [
    CGRect(x: 0, y: 0, width: 1000, height: 600),
    CGRect(x: 100, y: 50, width: 800, height: 450)
] {
    let harness = PointerHarness(videoContentRect: rect, remoteVideoSize: CGSize(width: 1600, height: 900))
    for event in [
        NSEvent(deltaX: 0, deltaY: 12),
        NSEvent(deltaX: 0, deltaY: -12),
        NSEvent(deltaX: 12, deltaY: 0),
        NSEvent(deltaX: -12, deltaY: 0),
        NSEvent(deltaX: 8, deltaY: 12),
        NSEvent(deltaX: 0, deltaY: 0)
    ] {
        let indicator = harness.normalizedRelativeDelta(for: event)
        let remote = harness.remoteScaledRelativeDelta(for: event)
        check(abs(indicator.x - remote.x / 1600) < 0.000001, "Indicator and remote mouse agree horizontally")
        check(abs(indicator.y - remote.y / 900) < 0.000001, "Indicator and remote mouse agree vertically")
        check(indicator.y == event.deltaY / rect.height, "Downward movement increases the overlay Y coordinate")
    }
}
let empty = PointerHarness(videoContentRect: .zero, remoteVideoSize: .zero)
check(empty.normalizedRelativeDelta(for: NSEvent(deltaX: 5, deltaY: 5)) == .zero, "Empty video cannot move the indicator")
print("\(checks) Mac pointer checks passed")
