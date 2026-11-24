import Foundation
import Observation

/// Moves a rover that is already on a network (not on its hotspot) to another Wi‑Fi.
///
/// The rover saves the new network with top priority, keeps every other profile as a
/// fallback, and switches on its own after the terminal closes. If it can't join, it
/// restores the old profile and goes back to the old network (or its AccessPopup
/// hotspot), and the app reads back why.
@MainActor
@Observable
public final class WiFiSwitcher {
    public typealias StepState = RoverProvisioner.StepState
    public typealias Step = RoverProvisioner.Step

    public enum Outcome: Equatable, Sendable {
        /// Found on the new network at this address.
        case connected(String)
        /// The rover left; the Mac can't see the new network, so the user has to follow.
        case leftForNetwork(String)
    }

    public private(set) var survey: RoverWiFiSurvey?
    public private(set) var isScanning = false
    public private(set) var scanError: String?

    public private(set) var steps: [Step] = []
    public private(set) var isRunning = false
    public private(set) var error: String?
    public private(set) var outcome: Outcome?

    /// How long the rover gets to try the new network and fall back (its script waits up
    /// to 40 s for the join and again for the fallback).
    nonisolated static let fallbackWindow: TimeInterval = 100

    public init() {}

    // MARK: - Scan

    public func scan(rover: RoverClient, sudoPassword: String = "") async {
        isScanning = true
        scanError = nil
        defer { isScanning = false }
        do {
            let term = try await openTerminal(rover.hostIP)
            let out = try await term.runScript(RoverWiFiScript.survey(), timeout: 40)
            await term.close()
            let s = RoverWiFiScript.parseSurvey(out)
            survey = s
            if let h = s.hostname { rover.rememberedHostname = h }
        } catch {
            scanError = error.localizedDescription
        }
    }

    // MARK: - Switch

    /// - Parameter moveMac: also put this Mac on the new network and find the rover there.
    public func run(ssid: String, password: String, sudoPassword: String, moveMac: Bool,
                    rover: RoverClient, net: NetworkStatus) async {
        let target = ssid
        let oldIP = rover.hostIP
        let oldSSID = survey?.currentSSID
        let keyMgmt = survey?.nearby.first { $0.ssid == target }?.keyMgmt ?? "wpa-psk"
        var titles = ["Connect to the rover's JupyterLab", "Save “\(target)” on the rover", "Rover switches networks"]
        titles += moveMac ? ["Mac joins “\(target)”", "Find the rover on “\(target)”"] : ["Make sure the rover stays on “\(target)”"]
        steps = titles.enumerated().map { Step(id: $0.offset, title: $0.element) }
        error = nil
        outcome = nil
        isRunning = true
        defer { isRunning = false }

        var step = 0
        do {
            set(0, .running)
            let term = try await openTerminal(oldIP)
            set(0, .done)

            step = 1
            set(1, .running)
            let script = RoverWiFiScript.makeSwitch(ssid: target, password: password, keyMgmt: keyMgmt,
                                                    sudoPassword: sudoPassword)
            let out = try await term.runScript(script, timeout: 30)
            await term.close()
            if let reason = ProvisionScript.value(after: ProvisionScript.failMarker, in: out) {
                throw ProvisionError(Self.describeFailure(reason, ssid: target))
            }
            let saved = RoverWiFiScript.parseSwitch(out)
            if let h = saved?.hostname { rover.rememberedHostname = h }
            set(1, .done, saved?.isNew == false ? "Updated the saved profile; other networks stay as fallbacks"
                                                : "Other saved networks stay as fallbacks")

            step = 2
            set(2, .running, "Waiting for the rover to leave \(oldSSID.map { "“\($0)”" } ?? "this network")…")
            let started = Date()
            guard try await waitUntilGone(oldIP, timeout: 25) else {
                // Still answering at the old address — probably on Ethernet too. Its result
                // file says how the Wi‑Fi switch went.
                let r = try await waitForResult(oldIP, until: started.addingTimeInterval(Self.fallbackWindow))
                try finish(with: r, target: target, step: 2)
                return
            }
            set(2, .done, "The rover left the old network")

            if moveMac {
                step = 3
                set(3, .running)
                if let msg = await net.joinWiFi(ssid: target, password: password) {
                    set(3, .failed, msg)
                    try await confirmOnOldNetwork(oldIP, oldSSID: oldSSID, target: target, since: started,
                                                  rejoinMac: false, net: net, step: 3)
                    return
                }
                set(3, .done)

                step = 4
                set(4, .running, "Searching… (up to 90 seconds)")
                if let ip = await find(hostname: rover.rememberedHostname, excluding: oldIP, net: net, timeout: 90) {
                    set(4, .done, "Rover is at \(ip)")
                    outcome = .connected(ip)
                    rover.host = ip
                    Task { await rover.connect() }
                    rover.show("Rover moved to \(target)", symbol: "wifi")
                    return
                }
                set(4, .failed, "Not found on “\(target)”")
                try await confirmOnOldNetwork(oldIP, oldSSID: oldSSID, target: target, since: started,
                                              rejoinMac: true, net: net, step: 4)
            } else {
                step = 3
                set(3, .running, "If the rover can't join, it comes back here within ~1½ minutes…")
                if try await waitUntilBack(oldIP, until: started.addingTimeInterval(Self.fallbackWindow)) {
                    let r = try await readResult(oldIP)
                    throw ProvisionError(Self.describeFallback(r, target: target, oldSSID: oldSSID))
                }
                set(3, .done, "It didn't come back, so it's on “\(target)”")
                outcome = .leftForNetwork(target)
            }
        } catch {
            if steps.indices.contains(step), steps[step].state != .failed { set(step, .failed) }
            self.error = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// The Mac couldn't reach the rover on the new network: go back and see whether the
    /// rover fell back to the old one, and why.
    private func confirmOnOldNetwork(_ oldIP: String, oldSSID: String?, target: String, since: Date,
                                     rejoinMac: Bool, net: NetworkStatus, step: Int) async throws {
        if rejoinMac, let old = oldSSID {
            _ = await net.joinWiFi(ssid: old, password: "")
        }
        if try await waitUntilBack(oldIP, until: since.addingTimeInterval(Self.fallbackWindow)) {
            let r = try await readResult(oldIP)
            throw ProvisionError(Self.describeFallback(r, target: target, oldSSID: oldSSID))
        }
        outcome = .leftForNetwork(target)
        throw ProvisionError("The rover left \(oldSSID.map { "“\($0)”" } ?? "the old network") and hasn't come back, so it's most likely on “\(target)”, but this Mac can't find it there. Join “\(target)” on the Mac and press Scan below, or read the address on the rover's screen (line “W:”).")
    }

    private func finish(with r: RoverWiFiResult?, target: String, step: Int) throws {
        guard let r else {
            throw ProvisionError("The rover didn't report back. Check its screen, or press Scan below.")
        }
        guard r.ok else { throw ProvisionError(Self.describeFallback(r, target: target, oldSSID: nil)) }
        set(step, .done, "Wi‑Fi joined “\(target)” at \(r.detail)")
        outcome = .leftForNetwork(target)
    }

    private func openTerminal(_ ip: String) async throws -> JupyterTerminal {
        guard let base = URL(string: "http://\(ip):8888") else { throw ProvisionError("Bad rover address.") }
        let term = JupyterTerminal(base: base)
        do { try await term.open() } catch {
            throw ProvisionError("Can't reach JupyterLab on the rover (\(ip):8888): \(error.localizedDescription)")
        }
        return term
    }

    private func readResult(_ ip: String) async throws -> RoverWiFiResult? {
        let term = try await openTerminal(ip)
        let out = try await term.runScript(RoverWiFiScript.readResult(), timeout: 20)
        await term.close()
        return RoverWiFiScript.parseResult(out)
    }

    private func waitForResult(_ ip: String, until deadline: Date) async throws -> RoverWiFiResult? {
        while Date() < deadline {
            if let r = try? await readResult(ip) { return r }
            try await Task.sleep(for: .seconds(4))
        }
        return nil
    }

    /// True once the rover stops answering at `ip`.
    private func waitUntilGone(_ ip: String, timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await !RoverScanner.isRover(ip) { return true }
            try await Task.sleep(for: .seconds(1))
        }
        return false
    }

    /// True if the rover answers at `ip` again before the deadline.
    private func waitUntilBack(_ ip: String, until deadline: Date) async throws -> Bool {
        while Date() < deadline {
            if await RoverScanner.isRover(ip) { return true }
            try await Task.sleep(for: .seconds(3))
        }
        return false
    }

    private func find(hostname: String?, excluding oldIP: String, net: NetworkStatus,
                      timeout: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await net.refresh()
            if let name = hostname, let ip = await RoverScanner.resolve("\(name).local"),
               await RoverScanner.isRover(ip) {
                return ip
            }
            let prefixes = net.localPrefixes.filter { $0 != NetworkStatus.hotspotPrefix }
            if let ip = await RoverScanner.scan(prefixes: prefixes).first(where: { $0 != oldIP }) { return ip }
            try? await Task.sleep(for: .seconds(3))
        }
        return nil
    }

    private func set(_ i: Int, _ s: StepState, _ detail: String? = nil) {
        guard steps.indices.contains(i) else { return }
        steps[i].state = s
        if let detail { steps[i].detail = detail }
    }

    // MARK: - Messages

    nonisolated static func describeFailure(_ reason: String, ssid: String) -> String {
        switch reason {
        case RoverWiFiScript.failSudo:
            "The rover asked for a sudo password. Enter it under Advanced and try again."
        case RoverWiFiScript.failAlreadyOn:
            "The rover is already on “\(ssid)”."
        default:
            "The rover couldn't save “\(ssid)”: \(reason)"
        }
    }

    nonisolated static func describeFallback(_ r: RoverWiFiResult?, target: String, oldSSID: String?) -> String {
        let back = "The rover couldn't join “\(target)” and went back to \(oldSSID.map { "“\($0)”" } ?? "its previous network")"
        guard let r, !r.ok else { return back + "." }
        let d = r.detail.lowercased()
        let hint = d.contains("secrets") || d.contains("802-1x") || d.contains("psk")
            ? "The password is probably wrong."
            : d.contains("no network with ssid") || d.contains("not found")
                ? "The rover can't see that network — it may be out of range."
                : "NetworkManager said: \(r.detail)"
        return "\(back). \(hint) Nothing else was changed."
    }
}
