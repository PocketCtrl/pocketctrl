// SPDX-License-Identifier: MPL-2.0
import Foundation

guard CommandLine.arguments.count == 4 else { fatalError("Expected team, profile and output path") }
let options: [String: Any] = [
    "method": "developer-id",
    "signingStyle": "manual",
    "teamID": CommandLine.arguments[1],
    "signingCertificate": "Developer ID Application",
    "provisioningProfiles": ["app.pocketctrl.mac": CommandLine.arguments[2]],
    "destination": "export"
]
let data = try PropertyListSerialization.data(fromPropertyList: options, format: .xml, options: 0)
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[3]), options: .atomic)
