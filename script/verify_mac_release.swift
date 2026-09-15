// SPDX-License-Identifier: MPL-2.0
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("Release verification failed: \(message)\n".utf8))
    exit(1)
}
func readPlist(_ path: String) -> [String: Any] {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let result = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            fail("Invalid plist: \(path)")
        }
        return result
    } catch { fail("Cannot read \(path): \(error.localizedDescription)") }
}
func permits(_ pattern: String, _ value: String) -> Bool {
    pattern == value || (pattern.hasSuffix(".*") && value.hasPrefix(String(pattern.dropLast())))
}
guard CommandLine.arguments.count == 4 else { fail("Expected Info.plist, entitlements, and decoded profile.") }
let info = readPlist(CommandLine.arguments[1])
let entitlements = readPlist(CommandLine.arguments[2])
let profile = readPlist(CommandLine.arguments[3])
guard info["CFBundleIdentifier"] as? String == "app.pocketctrl.mac" else { fail("Wrong app bundle identifier.") }
for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
    guard let value = info[key] as? String,
          value.range(of: #"^[0-9]+(\.[0-9]+)*$"#, options: .regularExpression) != nil else {
        fail("Invalid release version: \(key)")
    }
}
for key in ["com.apple.security.get-task-allow", "get-task-allow", "com.apple.security.app-sandbox",
            "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-unsigned-executable-memory",
            "com.apple.security.cs.allow-dyld-environment-variables"] {
    if entitlements[key] as? Bool == true { fail("Unexpected release entitlement: \(key)") }
}
guard let expiration = profile["ExpirationDate"] as? Date, expiration > Date() else { fail("Provisioning profile expired.") }
guard profile["ProvisionsAllDevices"] as? Bool == true,
      profile["ProvisionedDevices"] == nil else { fail("Use a Developer ID distribution profile, not a development profile.") }
guard let allowed = profile["Entitlements"] as? [String: Any],
      let appID = entitlements["com.apple.application-identifier"] as? String,
      appID.hasSuffix(".app.pocketctrl.mac"), !appID.contains("$"),
      let allowedID = allowed["com.apple.application-identifier"] as? String,
      permits(allowedID, appID),
      let groups = entitlements["keychain-access-groups"] as? [String], groups == [appID],
      let allowedGroups = allowed["keychain-access-groups"] as? [String],
      allowedGroups.contains(where: { permits($0, appID) }) else {
    fail("App identity / Keychain entitlements are missing or not authorized by the profile.")
}
print("Version and data-protection Keychain provisioning checks passed.")
