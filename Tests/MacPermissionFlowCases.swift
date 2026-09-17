// SPDX-License-Identifier: MPL-2.0
// Source-level guards for permission sequencing; not a macOS privacy runtime test.
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
func source(_ name: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent("PocketCtrlNative/PocketCtrl/\(name).swift"), encoding: .utf8)
}
func check(_ condition: Bool, _ label: String) {
    guard condition else { fatalError("FAIL: \(label)") }
    print("PASS: \(label)")
}
let model = try source("RemoteDesktopModel")
let refresh = model.components(separatedBy: "func refreshSetupStatus(")[1]
    .components(separatedBy: "func requestAccessibilityPermission()")[0]
check(!refresh.contains("probeLocalNetworkPermission()"), "passive setup refresh does not request Local Network")
check(model.contains("Discovery available · video is checked when a device connects"), "Bonjour success is not presented as video permission")
check(model.contains("if feedback.completedFrames > 0") && model.contains("else if feedback.receivedChunks > 0"), "viewer delivery distinguishes complete frames from packets")
check(model.contains("self.host?.retryFailedMediaConnections()"), "Settings return routes recovery to the running host")
let sender = try source("SecureSessionDatagram")
let recovery = sender.components(separatedBy: "func retryFailedLocalConnections()")[1]
    .components(separatedBy: "private func recordSuccessfulSend")[0]
check(recovery.contains("guard hasFailures else { return }") && recovery.contains("sender.recreateSocket()"), "Settings recovery recreates only failed media sockets")
let warning = try source("LocalNetworkAccessWarningView")
check(warning.contains("Turn PocketCtrl off, then back on") && warning.contains("may refresh"), "warning explains toggle workaround without guaranteeing success")
