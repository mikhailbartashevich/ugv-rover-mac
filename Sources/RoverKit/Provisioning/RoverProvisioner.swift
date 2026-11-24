import Foundation
import Observation

/// One-button flow: the rover (on its AccessPopup hotspot) learns the home Wi‑Fi and
/// switches to it, the Mac rejoins home Wi‑Fi, and we find the rover's new IP.
@MainActor
@Observable
public final class RoverProvisioner {
    public enum StepState: Sendable { case pending, running, done, failed }

    public struct Step: Identifiable, Sendable {
        public let id: Int
        public let title: String
        public internal(set) var state: StepState = .pending
        public internal(set) var detail: String?
    }

    public private(set) var steps: [Step] = []
    public private(set) var isRunning = false
    public private(set) var error: String?
    public private(set) var newHost: String?

    private static let titles = [
        "Connect to the rover's JupyterLab",
        "Save your Wi‑Fi on the rover",
        "Rover switches to your Wi‑Fi",
        "Mac rejoins your Wi‑Fi",
        "Find the rover on your network",
    ]

    public init() {}

    public func run(ssid: String, password: String, sudoPassword: String,
                    rover: RoverClient, net: NetworkStatus) async {
        steps = Self.titles.enumerated().map { Step(id: $0.offset, title: $0.element) }
        error = nil
        newHost = nil
        isRunning = true
        defer { isRunning = false }

        var step = 0
        do {
            step = 0
            set(0, .running)
            let term = try await openTerminal(roverIP: rover.hostIP)
            set(0, .done)

            step = 1
            set(1, .running)
            let roverName = try await saveNetwork(term, ssid: ssid, password: password, sudoPassword: sudoPassword)
            set(1, .done, roverName.map { "Rover hostname: \($0)" })
            if let name = roverName { rover.rememberedHostname = name }

            step = 2
            set(2, .running, "Waiting for the hotspot to go down…")
            try await Task.sleep(for: .seconds(8))
            set(2, .done, "Hotspot is switching off")

            step = 3
            set(3, .running)
            if let msg = await net.joinWiFi(ssid: ssid, password: password) {
                set(3, .failed, "\(msg) — join “\(ssid)” manually; still looking for the rover.")
            } else {
                set(3, .done)
            }

            step = 4
            set(4, .running, "Searching… (up to 2 minutes)")
            let ip = try await findRover(hostname: roverName, net: net)
            newHost = ip
            set(4, .done, "Rover is at \(ip)")
            rover.host = ip
            socketReconnect(rover)
        } catch {
            set(step, .failed)
            self.error = error.localizedDescription
        }
    }

    // MARK: - Steps

    private func openTerminal(roverIP: String) async throws -> JupyterTerminal {
        guard let base = URL(string: "http://\(roverIP):8888") else { throw ProvisionError("Bad rover address.") }
        let term = JupyterTerminal(base: base)
        do {
            try await term.open()
        } catch {
            throw ProvisionError("Can't reach JupyterLab at \(roverIP):8888. Is the Mac connected to the rover's AccessPopup Wi‑Fi?\n\(error.localizedDescription)")
        }
        return term
    }

    /// Returns the rover's hostname.
    private func saveNetwork(_ term: JupyterTerminal, ssid: String, password: String, sudoPassword: String) async throws -> String? {
        let script = ProvisionScript.make(ssid: ssid, password: password, sudoPassword: sudoPassword)
        for line in ProvisionScript.terminalLines(for: script) {
            try await term.send(line)
        }
        let out = try await term.waitFor([ProvisionScript.okMarker, ProvisionScript.failMarker], timeout: 30)
        await term.close()
        if let reason = ProvisionScript.value(after: ProvisionScript.failMarker, in: out) {
            throw ProvisionError(reason == "sudo"
                ? "The rover asked for a sudo password. Enter it under Advanced and try again."
                : "The rover couldn't save the network: \(reason)")
        }
        return ProvisionScript.value(after: ProvisionScript.infoMarker, in: out)?
            .split(separator: " ").first.map(String.init)
    }

    private func findRover(hostname: String?, net: NetworkStatus) async throws -> String {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            await net.refresh()
            if let name = hostname, let ip = await RoverScanner.resolve("\(name).local"),
               await RoverScanner.isRover(ip) {
                return ip
            }
            let prefixes = net.localPrefixes.filter { $0 != NetworkStatus.hotspotPrefix }
            if let ip = await RoverScanner.scan(prefixes: prefixes).first { return ip }
            try await Task.sleep(for: .seconds(3))
        }
        throw ProvisionError("Couldn't find the rover on your Wi‑Fi yet. Check the IP on its screen (line “W:”) and type it in the toolbar. If the rover can't see your network it returns to its AccessPopup hotspot.")
    }

    private func socketReconnect(_ rover: RoverClient) {
        Task { await rover.connect() }
    }

    private func set(_ i: Int, _ s: StepState, _ detail: String? = nil) {
        guard steps.indices.contains(i) else { return }
        steps[i].state = s
        if let detail { steps[i].detail = detail }
    }
}
