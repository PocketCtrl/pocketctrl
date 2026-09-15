// NetService fixtures exercise both production parsers without browsing the LAN.
final class DiscoveryFixture: NetService {
    var fixtureAddresses: [Data] = []
    var fixtureTXT: [String: Data] = ["v": Data("1".utf8), "id": Data("fixture".utf8)]
    override var addresses: [Data]? { fixtureAddresses }
    override func txtRecordData() -> Data? { NetService.data(fromTXTRecord: fixtureTXT) }
    // The synthetic didFind callback must not start a real mDNS resolve.
    override func resolve(withTimeout timeout: TimeInterval) {}
}

func socketData(_ host: String) -> Data {
    var address = IPNetwork.destination(host: host, port: 5555)!
    return withUnsafeBytes(of: &address) { Data($0) }
}

let serviceFixture = DiscoveryFixture(domain: "local.", type: "_pocketctrl._udp.", name: "fixture")
let macBrowser = LocalDiscoveryBrowser()
let mobileBrowser = ClientLocalDiscoveryBrowser()
serviceFixture.fixtureAddresses = [socketData("fd00:1::1")]
check(macBrowser.discoveredHost(from: serviceFixture)?.localAddress == "fd00:1::1", "Mac Bonjour parser retains native IPv6")
check(mobileBrowser.discoveredHost(from: serviceFixture)?.localAddress == "fd00:1::1", "iOS Bonjour parser retains native IPv6")
serviceFixture.fixtureAddresses = [socketData("fd00:1::1"), socketData("192.168.1.2")]
check(macBrowser.discoveredHost(from: serviceFixture)?.localAddress == "192.168.1.2", "Mac Bonjour keeps IPv4 preference on dual-stack LAN")
check(mobileBrowser.discoveredHost(from: serviceFixture)?.localAddress == "192.168.1.2", "iOS Bonjour keeps IPv4 preference on dual-stack LAN")
let loopbackScope = if_nametoindex("lo0")
serviceFixture.fixtureAddresses = [socketData("fe80::1%\(loopbackScope)")]
serviceFixture.fixtureTXT["local"] = Data("fe80::1%99".utf8)
check(macBrowser.discoveredHost(from: serviceFixture)?.localAddress == "fe80::1%\(loopbackScope)", "Mac Bonjour retains receiver-local IPv6 scope over TXT scope")
check(mobileBrowser.discoveredHost(from: serviceFixture)?.localAddress == "fe80::1%\(loopbackScope)", "iOS Bonjour retains receiver-local IPv6 scope over TXT scope")
serviceFixture.fixtureAddresses = []
check(macBrowser.discoveredHost(from: serviceFixture) == nil && mobileBrowser.discoveredHost(from: serviceFixture) == nil, "both parsers reject foreign-scoped TXT-only routes")
serviceFixture.fixtureTXT["local"] = Data("192.168.1.2".utf8)
check(macBrowser.discoveredHost(from: serviceFixture)?.localAddress == "192.168.1.2" && mobileBrowser.discoveredHost(from: serviceFixture)?.localAddress == "192.168.1.2", "IPv4 TXT fallback remains supported")

// Exercise the real delegate callbacks, capturing only diagnostics. No browse,
// publish, or resolve operation is started by these synthetic callbacks.
ClientDiagnostics.connectionEvents.removeAll()
mobileBrowser.targetHostID = "previous-host-identity"
var deliveredHosts = 0
mobileBrowser.onHostResolved = { _ in deliveredHosts += 1 }
serviceFixture.fixtureTXT["name"] = Data("PRIVATE_DEVICE_NAME".utf8)
serviceFixture.fixtureTXT["credentialSecret"] = Data("SECRET_MUST_NOT_APPEAR".utf8)
mobileBrowser.netServiceDidResolveAddress(serviceFixture)
check(deliveredHosts == 0, "identity mismatch diagnostics do not weaken discovery filtering")
check(ClientDiagnostics.connectionEvents.contains { $0.contains("reason=hostIdentityMismatch") && $0.contains("expectedHost=\(ClientDiagnostics.identifierTag("previous-host-identity"))") && $0.contains("advertisedHost=\(ClientDiagnostics.identifierTag("fixture"))") }, "identity mismatch log correlates expected and advertised host fingerprints")
check(mobileBrowser.diagnosticSummary.contains("identityMismatches=1"), "Wi-Fi timeout summary retains identity mismatch count")
mobileBrowser.targetHostID = "fixture"
mobileBrowser.netServiceDidResolveAddress(serviceFixture)
check(deliveredHosts == 1 && ClientDiagnostics.connectionEvents.contains { $0.contains("identityMatches=true") }, "matching identity still delivers the paired host and logs the match")
var localNetworkDenials: [Bool] = []
mobileBrowser.onLocalNetworkAccessDenied = { localNetworkDenials.append($0) }
mobileBrowser.netServiceBrowser(NetServiceBrowser(), didNotSearch: ["NSNetServicesErrorCode": NSNumber(value: -72008)])
check(ClientDiagnostics.connectionEvents.contains { $0.contains("discovery.searchFailed") && $0.contains("-72008") }, "discovery failures retain numeric Bonjour errors")
check(localNetworkDenials == [true], "policy-denied Bonjour error reports Local Network access as denied")
mobileBrowser.netServiceBrowser(NetServiceBrowser(), didNotSearch: ["NSNetServicesErrorCode": NSNumber(value: -72004)])
check(localNetworkDenials == [true], "other Bonjour errors do not report a Local Network denial")
mobileBrowser.netServiceBrowser(NetServiceBrowser(), didFind: serviceFixture, moreComing: false)
check(localNetworkDenials == [true, false], "finding a service clears the Local Network denial")
serviceFixture.fixtureTXT["v"] = Data("999".utf8)
mobileBrowser.netServiceDidResolveAddress(serviceFixture)
check(ClientDiagnostics.connectionEvents.contains { $0.contains("reason=missingIdentityOrUnsupportedVersion") }, "invalid discovery metadata logs a concrete rejection reason")
let diagnosticsText = ClientDiagnostics.connectionEvents.joined(separator: "\n")
check(!diagnosticsText.contains("PRIVATE_DEVICE_NAME") && !diagnosticsText.contains("SECRET_MUST_NOT_APPEAR") && !diagnosticsText.contains("previous-host-identity") && !diagnosticsText.contains("192.168.1.2"), "new discovery diagnostics omit names, secrets, raw identities and addresses")
