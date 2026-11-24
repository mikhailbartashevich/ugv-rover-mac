import Foundation
import Observation

/// Opens a terminal on the rover through its JupyterLab (port 8888, no token on the
/// Waveshare image) and drives it over the terminal websocket.
@MainActor
final class JupyterTerminal {
    let base: URL
    private let session: URLSession
    private var ws: URLSessionWebSocketTask?
    private var name: String?
    private var output = ""
    private var cookies: [HTTPCookie] = []

    init(base: URL) {
        self.base = base
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 8
        // A standalone HTTPCookieStorage() doesn't work with URLSession, so cookies are handled by hand.
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        session = URLSession(configuration: cfg)
    }

    private var cookieHeader: String {
        cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    private var xsrf: String? { cookies.first { $0.name == "_xsrf" }?.value }

    private func request(_ path: String, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = method
        if !cookies.isEmpty { req.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        if method != "GET", let x = xsrf { req.setValue(x, forHTTPHeaderField: "X-XSRFToken") }
        return req
    }

    func open() async throws {
        // Loading the page sets the _xsrf cookie that POSTs need.
        let (_, labResp) = try await session.data(for: request("lab"))
        if let http = labResp as? HTTPURLResponse, let fields = http.allHeaderFields as? [String: String] {
            cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: base)
        }
        let (data, resp) = try await session.data(for: request("api/terminals", method: "POST"))
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["name"] as? String else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            throw ProvisionError.message("JupyterLab refused to open a terminal (HTTP \(code)).")
        }
        name = n
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = base.scheme == "https" ? "wss" : "ws"
        comps.path = "/terminals/websocket/\(n)"
        var wreq = URLRequest(url: comps.url!)
        let c = cookieHeader
        if !c.isEmpty { wreq.setValue(c, forHTTPHeaderField: "Cookie") }
        let task = session.webSocketTask(with: wreq)
        ws = task
        task.resume()
        receiveLoop()
    }

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(let msg) = result {
                    var text: String?
                    switch msg {
                    case .string(let s): text = s
                    case .data(let d): text = String(data: d, encoding: .utf8)
                    @unknown default: break
                    }
                    if let t = text, let data = t.data(using: .utf8),
                       let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
                       arr.first as? String == "stdout", let s = arr.dropFirst().first as? String {
                        self.output += s
                    }
                    self.receiveLoop()
                }
            }
        }
    }

    func send(_ line: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["stdin", line + "\r"])
        try await ws?.send(.string(String(data: payload, encoding: .utf8)!))
    }

    /// Waits until the terminal output contains one of `markers`; returns the full output.
    func waitFor(_ markers: [String], timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if markers.contains(where: { output.contains($0) }) { return output }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ProvisionError.message("The rover didn't answer in time.")
    }

    func close() async {
        ws?.cancel(with: .normalClosure, reason: nil)
        if let n = name {
            _ = try? await session.data(for: request("api/terminals/\(n)", method: "DELETE"))
        }
    }
}

enum ProvisionError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let m) = self { return m }; return nil }
}

/// One-button flow: rover (on its AccessPopup hotspot) learns the home Wi‑Fi,
/// switches to it, the Mac rejoins home Wi‑Fi, and we find the rover's new IP.
@MainActor
@Observable
final class RoverProvisioner {
    enum StepState { case pending, running, done, failed }
    struct Step: Identifiable { let id: Int; let title: String; var state: StepState = .pending; var detail: String? }

    var steps: [Step] = []
    var isRunning = false
    var error: String?
    var newHost: String?

    private static let titles = [
        "Connect to the rover's JupyterLab",
        "Save your Wi‑Fi on the rover",
        "Rover switches to your Wi‑Fi",
        "Mac rejoins your Wi‑Fi",
        "Find the rover on your network",
    ]

    func reset() {
        steps = Self.titles.enumerated().map { Step(id: $0.offset, title: $0.element) }
        error = nil
        newHost = nil
    }

    private func set(_ i: Int, _ s: StepState, _ detail: String? = nil) {
        steps[i].state = s
        if let detail { steps[i].detail = detail }
    }

    func run(ssid: String, password: String, sudoPassword: String, rover: RoverClient, net: NetworkStatus) async {
        reset()
        isRunning = true
        defer { isRunning = false }
        var step = 0
        do {
            // 1. Jupyter
            set(0, .running)
            let roverIP = rover.baseURL?.host() ?? "192.168.50.5"
            guard let jbase = URL(string: "http://\(roverIP):8888") else { throw ProvisionError.message("Bad rover address.") }
            let term = JupyterTerminal(base: jbase)
            do { try await term.open() } catch {
                throw ProvisionError.message("Can't reach JupyterLab at \(roverIP):8888. Is the Mac connected to the rover's AccessPopup Wi‑Fi?\n\(error.localizedDescription)")
            }
            set(0, .done)

            // 2. Save Wi‑Fi (script is sent base64-encoded so markers don't appear in the echo)
            step = 1; set(1, .running)
            let script = Self.script(ssid: ssid, password: password, sudoPassword: sudoPassword)
            let b64 = Data(script.utf8).base64EncodedString()
            // Sent in short lines: terminals can truncate very long input lines.
            try await term.send("umask 077; rm -f /tmp/.ugv_b64")
            var rest = Substring(b64)
            while !rest.isEmpty {
                try await term.send("printf %s '\(rest.prefix(400))' >> /tmp/.ugv_b64")
                rest = rest.dropFirst(400)
            }
            try await term.send("base64 -d < /tmp/.ugv_b64 > /tmp/.ugv_wifi.sh; rm -f /tmp/.ugv_b64; bash /tmp/.ugv_wifi.sh")
            let out = try await term.waitFor(["__UGV_OK__", "__UGV_FAIL__"], timeout: 30)
            await term.close()
            if let r = out.range(of: "__UGV_FAIL__") {
                let reason = out[r.upperBound...].split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw ProvisionError.message(reason == "sudo"
                    ? "The rover asked for a sudo password. Enter it under Advanced and try again."
                    : "The rover couldn't save the network: \(reason)")
            }
            var roverName: String?
            if let r = out.range(of: "__UGV_INFO__") {
                let parts = out[r.upperBound...].split(whereSeparator: \.isNewline).first?.split(separator: " ") ?? []
                if let h = parts.first { roverName = String(h).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            set(1, .done, roverName.map { "Rover hostname: \($0)" })

            // 3. Rover switches (we can't watch it — its hotspot goes away)
            step = 2; set(2, .running, "Waiting for the hotspot to go down…")
            try await Task.sleep(for: .seconds(8))
            set(2, .done, "Hotspot is switching off")

            // 4. Mac back to home Wi‑Fi
            step = 3; set(3, .running)
            if let msg = await net.joinWiFi(ssid: ssid, password: password) {
                set(3, .failed, msg + " — join “\(ssid)” manually; I'll keep looking.")
            } else {
                set(3, .done)
            }

            // 5. Find rover
            step = 4; set(4, .running, "Searching… (up to 2 minutes)")
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                await net.refresh()
                if let name = roverName, let ip = await Self.resolve("\(name).local"), await Self.isRover(ip) {
                    newHost = ip; break
                }
                let found = await NetworkStatus.scanForRovers(prefixes: net.localPrefixes.filter { $0 != "192.168.50" })
                if let ip = found.first { newHost = ip; break }
                try await Task.sleep(for: .seconds(3))
            }
            guard let ip = newHost else {
                throw ProvisionError.message("Couldn't find the rover on your Wi‑Fi yet. Check the IP on its screen (line “W:”) and type it in the toolbar. If the rover can't see your network it returns to its AccessPopup hotspot.")
            }
            set(4, .done, "Rover is at \(ip)")
            rover.host = ip
            await rover.ping()
        } catch {
            if step < steps.count { set(step, .failed) }
            self.error = error.localizedDescription
        }
    }

    // MARK: - helpers

    nonisolated static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Bash run on the rover. Adds a NetworkManager profile for the home Wi‑Fi,
    /// prints markers, then (detached, so it survives the terminal closing and the
    /// hotspot dropping) lets AccessPopup switch wlan0 from hotspot to that network.
    nonisolated static func script(ssid: String, password: String, sudoPassword: String) -> String {
        let sec = password.isEmpty ? "" : "wifi-sec.key-mgmt wpa-psk wifi-sec.psk \"$PASS\""
        return """
        SSID=\(shellQuote(ssid))
        PASS=\(shellQuote(password))
        PW=\(shellQuote(sudoPassword))
        s() { if [ -n "$PW" ]; then printf '%s\\n' "$PW" | sudo -S -p '' "$@"; else sudo -n "$@"; fi; }
        if ! s true 2>/dev/null; then echo "__UGV_FAIL__ sudo"; rm -f "$0"; exit 1; fi
        s nmcli connection delete ugv-home >/dev/null 2>&1
        if ! ERR=$(s nmcli connection add type wifi ifname wlan0 con-name ugv-home ssid "$SSID" \(sec) connection.autoconnect yes connection.autoconnect-priority 50 2>&1); then
          echo "__UGV_FAIL__ $ERR" | tr '\\n' ' '; echo; rm -f "$0"; exit 1
        fi
        echo "__UGV_INFO__ $(hostname) $(cat /sys/class/net/wlan0/address 2>/dev/null)"
        cat > /tmp/.ugv_switch.sh <<EOS
        sleep 3
        if command -v accesspopup >/dev/null; then accesspopup; else nmcli connection up ugv-home; fi
        rm -f /tmp/.ugv_switch.sh
        EOS
        if [ -n "$PW" ]; then printf '%s\\n' "$PW" | sudo -S -p '' true; fi
        s setsid nohup bash /tmp/.ugv_switch.sh >/tmp/ugv_switch.log 2>&1 < /dev/null &
        rm -f "$0"
        echo "__UGV_OK__"
        """
    }

    nonisolated static func resolve(_ host: String) async -> String? {
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

    nonisolated static func isRover(_ ip: String) async -> Bool {
        await !NetworkStatus.scanHosts([ip]).isEmpty
    }
}
