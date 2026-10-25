import Foundation
import Darwin

enum BridgeFailure: Error { case invalidMessage, system(Int32) }

/// Private, per-user Unix socket. It never listens on a network interface.
enum BridgeWire {
    #if TESTING
    static var testSocket: String?
    #endif
    static var path: String {
        #if TESTING
        if let testSocket { return testSocket }
        #endif
        return "/tmp/io.github.Nile54.MashKeys.\(getuid()).sock"
    }
    static let limit = 131072

    static func address() -> sockaddr_un {
        var result = sockaddr_un()
        result.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &result.sun_path) { memory in
            let bytes = Array(path.utf8) + [0]
            memory.copyBytes(from: bytes)
        }
        result.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return result
    }

    static func receive(from fd: Int32) throws -> [String: Any]? {
        var header = [UInt8](repeating: 0, count: 4)
        guard try fill(fd, &header, bytes: 4) else { return nil }
        let count = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
        guard count > 0, count <= limit else { throw BridgeFailure.invalidMessage }
        var body = [UInt8](repeating: 0, count: count)
        guard try fill(fd, &body, bytes: count), let value = try JSONSerialization.jsonObject(with: Data(body)) as? [String: Any] else { throw BridgeFailure.invalidMessage }
        return value
    }

    static func send(_ message: [String: Any], to fd: Int32) throws {
        let body = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard body.count <= limit else { throw BridgeFailure.invalidMessage }
        let n = UInt32(body.count)
        var data = Data([UInt8(n & 255), UInt8((n >> 8) & 255), UInt8((n >> 16) & 255), UInt8((n >> 24) & 255)])
        data.append(body)
        try data.withUnsafeBytes { pointer in
            var offset = 0
            while offset < data.count {
                let written = Darwin.write(fd, pointer.baseAddress!.advanced(by: offset), data.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw BridgeFailure.system(errno) }
                offset += written
            }
        }
    }

    private static func fill(_ fd: Int32, _ buffer: inout [UInt8], bytes: Int) throws -> Bool {
        try buffer.withUnsafeMutableBytes { target in
            var offset = 0
            while offset < bytes {
                let count = Darwin.read(fd, target.baseAddress!.advanced(by: offset), bytes - offset)
                if count == 0 { return false }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeFailure.system(errno) }
                offset += count
            }
            return true
        }
    }
}

final class BrowserBridge {
    var onHit: ((BassHit, String) -> Void)?
    var onSpeech: ((Bool, String) -> Void)?
    var onConnection: ((Int) -> Void)?
    let rules: RoutingRules
    private var listener: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "io.github.Nile54.MashKeys.bridge")
    private let clientsMutex = NSLock()
    private var clients: Set<Int32> = []
    private var alive = true

    init(rules: RoutingRules) { self.rules = rules }

    func start() throws {
        var info = stat()
        if lstat(BridgeWire.path, &info) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK else { throw BridgeFailure.invalidMessage }
            unlink(BridgeWire.path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BridgeFailure.system(errno) }
        var address = BridgeWire.address()
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard status == 0 else { Darwin.close(fd); throw BridgeFailure.system(errno) }
        chmod(BridgeWire.path, S_IRUSR | S_IWUSR)
        guard listen(fd, 4) == 0 else { Darwin.close(fd); throw BridgeFailure.system(errno) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        listener = source
        source.setCancelHandler { Darwin.close(fd); unlink(BridgeWire.path) }
        source.setEventHandler { [weak self] in self?.acceptClients(fd) }
        source.resume()
    }

    func stop() {
        clientsMutex.lock(); alive = false
        for fd in clients { _ = shutdown(fd, SHUT_RDWR) }
        clientsMutex.unlock()
        listener?.cancel(); listener = nil
    }

    private func acceptClients(_ fd: Int32) {
        while true {
            let peer = accept(fd, nil, nil)
            if peer < 0 { return }
            var user: uid_t = 0, group: gid_t = 0
            guard getpeereid(peer, &user, &group) == 0, user == getuid() else { Darwin.close(peer); continue }
            // BSD can inherit the listener's nonblocking flag. Each accepted
            // connection is served by its own worker and must wait for frames.
            let flags = fcntl(peer, F_GETFL, 0)
            _ = fcntl(peer, F_SETFL, flags & ~O_NONBLOCK)
            var noSignal: Int32 = 1
            setsockopt(peer, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            clientsMutex.lock()
            let acceptPeer = alive && clients.count < 4
            if acceptPeer { clients.insert(peer) }
            let total = clients.count
            clientsMutex.unlock()
            guard acceptPeer else { Darwin.close(peer); continue }
            DispatchQueue.main.async { [weak self] in self?.onConnection?(total) }
            DispatchQueue(label: "io.github.Nile54.MashKeys.browser-client.\(peer)", qos: .userInitiated).async { [self] in serve(peer) }
        }
    }

    private func serve(_ fd: Int32) {
        var streams: [String: (host: String, rate: Double, pipeline: AudioPipeline, frames: Int64, start: Double)] = [:]
        defer {
            streams.values.forEach { $0.pipeline.stop() }
            Darwin.close(fd)
            clientsMutex.lock(); clients.remove(fd); let count = clients.count; clientsMutex.unlock()
            DispatchQueue.main.async { [weak self] in self?.onConnection?(count) }
        }
        do {
            while let message = try BridgeWire.receive(from: fd) {
                let config = rules.snapshot
                var response: [String: Any] = ["ok": true, "running": config.running,
                                               "isolated": config.isolatesBrowser,
                                               "events": config.events,
                                               "blockedSites": config.websites.sorted()]
                let kind = message["type"] as? String ?? ""
                let key = String(fd) + ":" + String((message["stream"] as? String ?? "").prefix(80))
                if kind == "stop" { streams.removeValue(forKey: key)?.pipeline.stop() }
                if kind == "pcm" {
                    if !config.isolatesBrowser {
                        // Older helper builds already stop their AudioContext on
                        // an informational error. Release capture so normal tab
                        // playback feeds the app's system-wide tap again.
                        response["released"] = true
                        response["error"] = "Connected-tabs mode is off; MashKeys is listening system-wide."
                    }
                    guard let rawHost = message["host"] as? String, let host = RuleSnapshot.host(from: rawHost),
                          let rate = message["rate"] as? Double, rate >= 16000, rate <= 96000,
                          let encoded = message["samples"] as? String, let bytes = Data(base64Encoded: encoded),
                          !bytes.isEmpty, bytes.count <= 8192, bytes.count % 4 == 0 else { throw BridgeFailure.invalidMessage }
                    let application = message["browser"] as? String ?? "com.google.Chrome"
                    let blocked = config.blocks(host: host) || config.blocks(application: application)
                    response["blocked"] = blocked
                    if !config.running || !config.isolatesBrowser || blocked {
                        streams.removeValue(forKey: key)?.pipeline.stop()
                    } else {
                        if let old = streams[key], old.host != host || old.rate != rate { old.pipeline.stop(); streams.removeValue(forKey: key) }
                        if streams[key] == nil && streams.count < 4 {
                            let pipeline = AudioPipeline(rate: rate, guardSpeech: config.speech,
                                                         onHit: { [weak self] hit in
                                                             DispatchQueue.main.async {
                                                                 guard let self else { return }
                                                                 let current = self.rules.snapshot
                                                                 if current.running && current.isolatesBrowser && !current.blocks(host: host) && !current.blocks(application: application) { self.onHit?(hit, key) }
                                                             }
                                                         }, onSpeech: { [weak self] blocked in
                                                             DispatchQueue.main.async { self?.onSpeech?(blocked, key) }
                                                         }, onWarning: { _ in })
                            streams[key] = (host, rate, pipeline, 0, ProcessInfo.processInfo.systemUptime)
                        }
                        if var stream = streams[key] {
                            stream.pipeline.speech?.setEnabledIfNeeded(config.speech)
                            var samples = [Float](repeating: 0, count: bytes.count / 4)
                            samples.withUnsafeMutableBytes { _ = bytes.copyBytes(to: $0) }
                            for i in samples.indices { samples[i] = samples[i].isFinite ? max(-1, min(1, samples[i])) : 0 }
                            stream.frames += Int64(samples.count)
                            samples.withUnsafeBufferPointer { stream.pipeline.feedMono($0.baseAddress!, frames: $0.count,
                                                                                      time: stream.start + Double(stream.frames) / stream.rate) }
                            streams[key] = stream
                        }
                    }
                }
                try BridgeWire.send(response, to: fd)
            }
        } catch {
            #if TESTING
            fputs("Bridge test connection ended: \(error)\n", stderr)
            #endif
        }
    }
}

/// Chrome launches this mode through its native-messaging registry, not a network service.
func runBrowserNativeHost() -> Never {
    signal(SIGPIPE, SIG_IGN)
    var remote: Int32 = -1
    defer { if remote >= 0 { Darwin.close(remote) } }
    do {
        while let request = try BridgeWire.receive(from: STDIN_FILENO) {
            if remote < 0 {
                remote = socket(AF_UNIX, SOCK_STREAM, 0)
                var address = BridgeWire.address()
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(remote, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                if connected != 0 {
                    Darwin.close(remote); remote = -1
                    try BridgeWire.send(["ok": false, "error": "Open MashKeys, then reconnect this tab."], to: STDOUT_FILENO)
                    continue
                }
            }
            try BridgeWire.send(request, to: remote)
            guard let reply = try BridgeWire.receive(from: remote) else { break }
            try BridgeWire.send(reply, to: STDOUT_FILENO)
        }
    } catch { }
    exit(0)
}
