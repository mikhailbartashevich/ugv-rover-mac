import Foundation

/// Finds rovers on the local network by probing their web app on port 5000.
public enum RoverScanner {
    /// The rover's web app port (configurable for tests).
    nonisolated(unsafe) public static var port = 5000

    /// Probes every host in the given /24 prefixes ("192.168.1").
    public static func scan(prefixes: [String]) async -> [String] {
        await probe(prefixes.flatMap { p in (1...254).map { "\(p).\($0)" } })
    }

    public static func isRover(_ ip: String) async -> Bool {
        await !probe([ip]).isEmpty
    }

    public static func probe(_ hosts: [String]) async -> [String] {
        let port = Self.port
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.2
        let session = URLSession(configuration: cfg)
        var found: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for ip in hosts {
                group.addTask {
                    guard let url = URL(string: "http://\(ip):\(port)/"),
                          let (data, resp) = try? await session.data(from: url),
                          (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    let body = String(decoding: data.prefix(20000), as: UTF8.self).lowercased()
                    return (body.contains("socket.io") || body.contains("ugv") || body.contains("rover")) ? ip : nil
                }
            }
            for await ip in group { if let ip { found.append(ip) } }
        }
        return found.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Resolves a hostname (e.g. "raspberrypi.local") to an IPv4 address.
    public static func resolve(_ host: String) async -> String? {
        await Task.detached {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                                 ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var res: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &res) == 0, let first = res else { return nil }
            defer { freeaddrinfo(res) }
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(first.pointee.ai_addr, first.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST)
            return String(cString: buf)
        }.value
    }
}
