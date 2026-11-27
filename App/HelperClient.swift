import Foundation

struct HelperState: Decodable, Equatable {
    struct CPU: Decodable, Equatable {
        var avg: Double?; var max: Double?; var sensors: Int
        var effective: Double?  // smoothed temperature the curve follows (thermal inertia)
    }
    struct Fan: Decodable, Equatable { var actual: Double?; var min: Double?; var max: Double?; var target: Double?; var manual: Bool }
    struct Failsafe: Decodable, Equatable { var avg: Double; var hottest: Double }

    var version: Int
    var mode: String          // curve | failsafe | auto | error
    var error: String?
    var cpu: CPU
    var ssd: Double?
    var battery: Double?
    var fans: [Fan]
    var pct: Double?
    var fake: Bool
    var failsafe: Failsafe
    var controlling: Bool
}

/// Talks to fancurved over its Unix socket. All calls block. AppModel only ever touches it
/// from its own serial queue, which is what makes the unchecked Sendable safe.
final class HelperClient: @unchecked Sendable {
    static let expectedVersion = 4
    let path: String
    private var fd: Int32 = -1
    private var buffer = Data()

    init(path: String) { self.path = path }
    deinit { disconnect() }

    var isConnected: Bool { fd >= 0 }

    func connect() -> Bool {
        if fd >= 0 { return true }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(s); return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
        guard ok else { close(s); return false }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        buffer.removeAll()
        return true
    }

    func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    /// Sends one request and returns the raw JSON reply, or nil (and disconnects) on any I/O error.
    func request(_ obj: [String: Any]) -> Data? {
        guard fd >= 0, var data = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
        data.append(0x0A)
        let sent = data.withUnsafeBytes { send(fd, $0.baseAddress, data.count, 0) }
        guard sent == data.count else { disconnect(); return nil }
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                return Data(line)
            }
            let n = recv(fd, &chunk, chunk.count, 0)
            guard n > 0 else { disconnect(); return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 1 << 20 { disconnect(); return nil }
        }
    }

    /// Version reported by the helper on this connection (set by AppModel after `hello`).
    var version: Int?

    func helloVersion() -> Int? {
        guard let d = request(["cmd": "hello"]),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["version"] as? Int
    }

    func state() -> HelperState? {
        request(["cmd": "state"]).flatMap { try? JSONDecoder().decode(HelperState.self, from: $0) }
    }

    /// Returns the new state, or an error message from the helper.
    func control(enabled: Bool, points: [CurvePoint], response: Double) -> Result<HelperState, HelperError> {
        let body: [String: Any] = ["cmd": "control", "enabled": enabled, "points": points.map { [$0.temp, $0.pct] },
                                   "response": response]
        guard let d = request(body) else { return .failure(HelperError(L("error.noResponse"))) }
        if let s = try? JSONDecoder().decode(HelperState.self, from: d) { return .success(s) }
        let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        return .failure(HelperError((j?["error"] as? String) ?? L("error.badReply")))
    }
}

struct HelperError: Error, Equatable {
    let message: String
    init(_ message: String) { self.message = message }
}
