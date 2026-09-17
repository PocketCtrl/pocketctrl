// SPDX-License-Identifier: MPL-2.0
DispatchQueue.global().asyncAfter(deadline: .now() + 15) {
    fatalError("Diagnostic transport loopback test timed out")
}
let port = unusedUDPPort()
let receiver = try UDPReceiver(port: port)
let baseline = try UDPMultiPeerSender()
for mode in MacDiagnosticTransport.allCases {
    let transport = MacTransportDiagnostics(mode: mode)
    let payload = Data("diagnostic loopback \(mode.rawValue)".utf8)
    try transport.send(payload, host: "127.0.0.1", port: port, baseline: baseline)
    check(receiver.receiveWithSource()?.data == payload, "\(mode.rawValue) delivers identical datagram bytes to IPv4 receiver")
    if mode != .ipv4 {
        try transport.send(payload, host: "::1", port: port, baseline: baseline)
        check(receiver.receiveWithSource()?.data == payload, "\(mode.rawValue) supports IPv6")
    } else {
        do {
            try transport.send(payload, host: "::1", port: port, baseline: baseline)
            fatalError("Native IPv4 test must not silently use another transport")
        } catch UDPSocketError.sendFailed(let code) {
            check(code == EAFNOSUPPORT, "native IPv4 explicitly rejects IPv6 endpoints")
        }
    }
    transport.stop()
}
receiver.stop()
baseline.stop()
