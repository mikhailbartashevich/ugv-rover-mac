import Foundation
import Observation

public struct NetInterface: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String
    public let service: String
    public let ipv4: String
}

/// The Mac side: which interfaces are up, which one carries the default route,
/// and whether the internet is reachable right now.
@MainActor
@Observable
public final class NetworkStatus {
    public private(set) var interfaces: [NetInterface] = []
    public private(set) var defaultInterface: String?
    public private(set) var internetOK: Bool?
    public private(set) var serviceOrder: [String] = []
    public private(set) var preferredNetworks: [String] = []

    /// The rover's hotspot subnet (AccessPopup).
    public static let hotspotPrefix = "192.168.50"

    public init() {}

    public func refresh() async {
        let services = await Self.serviceMap()
        interfaces = Self.ipv4Interfaces().map {
            NetInterface(name: $0.0, service: services[$0.0] ?? $0.0, ipv4: $0.1)
        }
        defaultInterface = await Self.defaultRouteInterface()
        serviceOrder = await Self.orderedServices()
        internetOK = await Self.checkInternet()
    }

    public var localPrefixes: [String] {
        Array(Set(interfaces.compactMap { i -> String? in
            let p = i.ipv4.split(separator: ".")
            return p.count == 4 ? p.prefix(3).joined(separator: ".") : nil
        })).sorted()
    }

    public var onRoverHotspot: Bool {
        interfaces.contains { $0.ipv4.hasPrefix(Self.hotspotPrefix + ".") }
    }

    public func serviceName(for iface: String?) -> String? {
        guard let iface else { return nil }
        return interfaces.first { $0.name == iface }?.service ?? iface
    }

    /// Interface whose IPv4 is in the same /24 as the rover.
    public func interface(reaching roverIP: String) -> NetInterface? {
        let parts = roverIP.split(separator: ".")
        guard parts.count == 4 else { return nil }
        let prefix = parts.prefix(3).joined(separator: ".") + "."
        return interfaces.first { $0.ipv4.hasPrefix(prefix) }
    }

    public func loadPreferredNetworks() async {
        let out = await Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", await Self.wifiDevice()])
        preferredNetworks = out.split(separator: "\n").dropFirst()
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "AccessPopup" }
    }

    /// Joins a Wi‑Fi network. Returns an error message, or nil on success.
    public func joinWiFi(ssid: String, password: String) async -> String? {
        var args = ["-setairportnetwork", await Self.wifiDevice(), ssid]
        if !password.isEmpty { args.append(password) }
        let out = await Shell.run("/usr/sbin/networksetup", args).trimmingCharacters(in: .whitespacesAndNewlines)
        try? await Task.sleep(for: .seconds(4))
        await refresh()
        return out.isEmpty ? nil : out
    }

    /// Moves `service` to the end of the service order, so another connection
    /// (iPhone USB, Ethernet…) carries the internet while Wi‑Fi stays on the rover.
    /// Needs admin rights — macOS shows its own password prompt.
    public func demoteService(_ service: String) async -> String? {
        var order = serviceOrder.filter { $0 != service }
        order.append(service)
        let shell = "/usr/sbin/networksetup -ordernetworkservices " + order.map(Shell.quote).joined(separator: " ")
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let out = await Shell.run("/usr/bin/osascript", ["-e", "do shell script \"\(escaped)\" with administrator privileges"])
        await refresh()
        return out.isEmpty ? nil : out
    }

    // MARK: - System queries

    static func ipv4Interfaces() -> [(String, String)] {
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

    static func wifiDevice() async -> String {
        await serviceMap().first { $0.value == "Wi-Fi" }?.key ?? "en0"
    }

    static func defaultRouteInterface() async -> String? {
        let out = await Shell.run("/sbin/route", ["-n", "get", "default"])
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("interface:") {
                return t.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Device name → network service name ("en0" → "Wi-Fi").
    static func serviceMap() async -> [String: String] {
        let out = await Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"])
        var map: [String: String] = [:]
        var port: String?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line.hasPrefix("Device: "), let p = port { map[String(line.dropFirst("Device: ".count))] = p }
        }
        return map
    }

    static func orderedServices() async -> [String] {
        let out = await Shell.run("/usr/sbin/networksetup", ["-listnetworkserviceorder"])
        // Lines like "(1) Wi-Fi".
        return out.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("("), let close = line.firstIndex(of: ")"),
                  Int(line[line.index(after: line.startIndex)..<close]) != nil else { return nil }
            return line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        }
    }

    static func checkInternet() async -> Bool {
        var req = URLRequest(url: URL(string: "https://captive.apple.com/hotspot-detect.html")!)
        req.timeoutInterval = 3
        req.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, resp) = try? await URLSession(configuration: .ephemeral).data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return String(data: data, encoding: .utf8)?.contains("Success") == true
    }
}
