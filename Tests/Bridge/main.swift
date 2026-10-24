import Foundation
import Darwin

signal(SIGPIPE, SIG_IGN)
BridgeWire.testSocket = "/tmp/mashkeys-test-\(UUID().uuidString.prefix(8)).sock"
let routing = RoutingRules()
routing.replace(RuleSnapshot(running: true, speech: false, websites: ["instagram.com"], applications: []))
let server = BrowserBridge(rules: routing)
var youtubeHits = 0
var blockedHits = 0
server.onHit = { _, source in
    if source.hasSuffix(":youtube") { youtubeHits += 1 }
    else { blockedHits += 1 }
}
try server.start()
DispatchQueue.global(qos: .userInitiated).async {
    do {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(fd) }
        var address = BridgeWire.address()
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        precondition(connected == 0)
        try BridgeWire.send(["type": "hello"], to: fd)
        let hello = try BridgeWire.receive(from: fd)
        precondition(hello?["isolated"] as? Bool == true)
        for offset in stride(from: 0, to: 44100, by: 512) {
            let count = min(512, 44100 - offset)
            let values: [Float] = (0..<count).map { index in
                let t = Double(offset + index) / 44100
                return Float((t < 0.18 ? 0.4 * (1 - exp(-t / 0.002)) * exp(-t / 0.045) : 0) * sin(2 * .pi * 80 * t))
            }
            let data = values.withUnsafeBytes { Data($0) }.base64EncodedString()
            for (stream, host) in [("instagram", "www.instagram.com"), ("youtube", "www.youtube.com")] {
                try BridgeWire.send(["type": "pcm", "stream": stream, "host": host, "rate": 44100.0,
                                     "samples": data, "browser": "com.google.Chrome"], to: fd)
                let reply = try BridgeWire.receive(from: fd)!
                precondition(reply["blocked"] as? Bool == (stream == "instagram"))
            }
        }
        // Change only the site rule while leaving the other stream eligible.
        routing.replace(RuleSnapshot(running: true, speech: false, websites: ["youtube.com"], applications: []))
        let one = [Float](repeating: 0, count: 512).withUnsafeBytes { Data($0) }.base64EncodedString()
        try BridgeWire.send(["type": "pcm", "stream": "youtube", "host": "youtube.com", "rate": 44100.0, "samples": one], to: fd)
        let blocked = try BridgeWire.receive(from: fd)
        precondition(blocked?["blocked"] as? Bool == true)
        DispatchQueue.main.async {
            precondition(youtubeHits == 1, "Allowed tab should continue independently")
            precondition(blockedHits == 0, "Ignored website must never emit a keyboard event")
            server.stop()
            print("PASS: local native messaging, ignored Instagram stream, independent YouTube stream, live rule changes")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { exit(0) }
        }
    } catch { fputs("Bridge test failed: \(error)\n", stderr); exit(1) }
}
dispatchMain()
