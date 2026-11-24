import Foundation
import Observation

struct NetInterface: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let service: String
    let ipv4: String
}

/// Looks at the Mac side: which interfaces are up, which one carries the default
/// route, and whether the internet is reachable right now.
@MainActor
@Observable
final class NetworkStatus {
    var interfaces: [NetInterface] = []
    var defaultInterface: String?
    var internetOK: Bool?
    var serviceOrder: [String] = []

    func refresh() async {
        let services = await Self.serviceMap()
        interfaces = Self.ipv4Interfaces().map {
            NetInterface(name: $0.0, service: services[$0.0] ?? $0.0, ipv4: $0.1)
        }
        defaultInterface = await Self.defaultRouteInterface()
        serviceOrder = await Self.orderedServices()
        internetOK = await Self.checkInternet()
    }

    var preferredNetworks: [String] = []

    var localPrefixes: [String] {
        Array(Set(interfaces.compactMap { i -> String? in
            let p = i.ipv4.split(separator: ".")
            return p.count == 4 ? p.prefix(3).joined(separator: ".") : nil
        })).sorted()
    }

    var wifiDevice: String? {
        interfaces.first { $0.service == "Wi-Fi" }?.name
    }

    func loadPreferredNetworks() async {
        let dev = await Self.serviceMap().first { $0.value == "Wi-Fi" }?.key ?? "en0"
        let out = await Self.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", dev])
        preferredNetworks = out.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "AccessPopup" }
    }

    /// Joins a Wi‑Fi network. Returns an error message, or nil on success.
    func joinWiFi(ssid: String, password: String) async -> String? {
        let dev = await Self.serviceMap().first { $0.value == "Wi-Fi" }?.key ?? "en0"
        var args = ["-setairportnetwork", dev, ssid]
        if !password.isEmpty { args.append(password) }
        let out = await Self.run("/usr/sbin/networksetup", args).trimmingCharacters(in: .whitespacesAndNewlines)
        try? await Task.sleep(for: .seconds(4))
        await refresh()
        return out.isEmpty ? nil : out
    }

    /// Probe every host in the given /24 prefixes for the rover web app on :5000.
    nonisolated static func scanForRovers(prefixes: [String]) async -> [String] {
        await scanHosts(prefixes.flatMap { p in (1...254).map { "\(p).\($0)" } })
    }

    nonisolated static func scanHosts(_ hosts: [String]) async -> [String] {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.2
        let session = URLSession(configuration: cfg)
        var found: [String] = []
        await withTaskGroup(of: String?.self) { group in
            for ip in hosts {
                group.addTask {
                    guard let url = URL(string: "http://\(ip):5000/"),
                          let (data, resp) = try? await session.data(from: url),
                          (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    let body = String(decoding: data.prefix(20000), as: UTF8.self).lowercased()
                    return (body.contains("socket.io") || body.contains("ugv") || body.contains("rover")) ? ip : nil
                }
            }
            for await ip in group { if let ip { found.append(ip) } }
        }
        return found.sorted()
    }

    func serviceName(for iface: String?) -> String? {
        guard let iface else { return nil }
        return interfaces.first { $0.name == iface }?.service ?? iface
    }

    /// Interface whose IPv4 is in the same /24 as the rover.
    func interface(reaching roverHost: String) -> NetInterface? {
        let parts = roverHost.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let prefix = parts.prefix(3).joined(separator: ".") + "."
        return interfaces.first { $0.ipv4.hasPrefix(prefix) }
    }

    // MARK: - helpers

    nonisolated static func ipv4Interfaces() -> [(String, String)] {
        var result: [(String, String)] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            let name = String(cString: ifa.ifa_name)
            let ip = String(cString: host)
            if name.hasPrefix("utun") || name.hasPrefix("bridge") || ip.hasPrefix("169.254.") { continue }
            result.append((name, ip))
        }
        return result
    }

    nonisolated static func run(_ path: String, _ args: [String]) async -> String {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            p.terminationHandler = { _ in
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                cont.resume(returning: String(data: d, encoding: .utf8) ?? "")
            }
            do { try p.run() } catch { cont.resume(returning: "") }
        }
    }

    nonisolated static func defaultRouteInterface() async -> String? {
        let out = await run("/sbin/route", ["-n", "get", "default"])
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// device name -> network service name ("en0" -> "Wi-Fi")
    nonisolated static func serviceMap() async -> [String: String] {
        let out = await run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var map: [String: String] = [:]
        var port: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line.hasPrefix("Device: "), let p = port { map[String(line.dropFirst("Device: ".count))] = p }
        }
        return map
    }

    nonisolated static func orderedServices() async -> [String] {
        let out = await run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        // lines like "(1) Wi-Fi"
        return out.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
            let num = line[line.index(after: line.startIndex)..<close]
            guard Int(num) != nil else { return nil }
            return line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
    }

    nonisolated static func checkInternet() async -> Bool {
        var req = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: .ephemeral)
        guard let (data, resp) = try? await s.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(data: data, encoding: .utf8)?.contains("Success") == true
    }

    /// Move `service` to the end of the service order, so another connection
    /// (iPhone USB, Ethernet…) wins the default route while Wi-Fi stays connected
    /// to the rover. Needs admin rights — macOS shows its own password prompt.
    func demoteService(_ service: String) async -> String? {
        var order = serviceOrder.filter { $0 != service }
        order.append(service)
        let quoted = order.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let shell = "/usr/sbin/networksetup -ordernetworkservices \(quoted)"
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let out = await Self.run("/usr/bin/osascript", ["-e", script])
        await refresh()
        return out.isEmpty ? nil : out
    }
}
