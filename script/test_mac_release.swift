// SPDX-License-Identifier: MPL-2.0
import Foundation

let verifier = CommandLine.arguments[1]
let directory = URL(fileURLWithPath: CommandLine.arguments[2])
let identity = "TESTTEAMID.app.pocketctrl.mac"
let info: [String: Any] = ["CFBundleIdentifier": "app.pocketctrl.mac", "CFBundleVersion": "1", "CFBundleShortVersionString": "1.0"]
let entitlements: [String: Any] = ["com.apple.application-identifier": identity, "keychain-access-groups": [identity]]
let profile: [String: Any] = [
    "ExpirationDate": Date().addingTimeInterval(3600), "ProvisionsAllDevices": true,
    "Entitlements": ["com.apple.application-identifier": identity, "keychain-access-groups": ["TESTTEAMID.*"]]
]
var count = 0
func check(_ label: String, info testInfo: [String: Any] = info,
           entitlements testEntitlements: [String: Any] = entitlements,
           profile testProfile: [String: Any] = profile, passes: Bool = false) throws {
    var paths: [String] = []
    for (index, value) in [testInfo, testEntitlements, testProfile].enumerated() {
        let path = directory.appendingPathComponent("fixture-\(index).plist")
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: path)
        paths.append(path.path)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: verifier)
    process.arguments = paths
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard (process.terminationStatus == 0) == passes else {
        print("FAIL: \(label)"); exit(1)
    }
    count += 1
    print("PASS: \(label)")
}
func replacing(_ source: [String: Any], _ key: String, _ value: Any?) -> [String: Any] {
    var result = source
    result[key] = value
    return result
}
try check("matching website profile", passes: true)
try check("wrong app", info: replacing(info, "CFBundleIdentifier", "app.pocketctrl.mobile"))
try check("unsafe version", info: replacing(info, "CFBundleVersion", "../../other"))
try check("expired profile", profile: replacing(profile, "ExpirationDate", Date.distantPast))
try check("development profile", profile: replacing(profile, "ProvisionsAllDevices", false))
try check("device-limited profile", profile: replacing(profile, "ProvisionedDevices", ["test-device"]))
try check("missing identity", entitlements: replacing(entitlements, "com.apple.application-identifier", nil))
try check("missing Keychain group", entitlements: replacing(entitlements, "keychain-access-groups", nil))
try check("other app's Keychain group", entitlements: replacing(entitlements, "keychain-access-groups", ["TESTTEAMID.other"]))
try check("wrong profile identity", profile: replacing(profile, "Entitlements", ["com.apple.application-identifier": "OTHERTEAM.app.pocketctrl.mac", "keychain-access-groups": ["OTHERTEAM.*"]]))
for key in ["com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.app-sandbox",
            "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.allow-dyld-environment-variables"] {
    try check("reject \(key)", entitlements: replacing(entitlements, key, true))
}
print("\(count) release-metadata checks passed (synthetic fixtures, not signing/notarization tests).")
