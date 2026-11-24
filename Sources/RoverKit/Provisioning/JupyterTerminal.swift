import Foundation

/// A terminal on the rover, opened through its JupyterLab (port 8888, no token on
/// the Waveshare image) and driven over the terminal websocket.
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
            throw ProvisionError("JupyterLab refused to open a terminal (HTTP \(code)).")
        }
        name = n
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = base.scheme == "https" ? "wss" : "ws"
        comps.path = "/terminals/websocket/\(n)"
        var wreq = URLRequest(url: comps.url!)
        if !cookies.isEmpty { wreq.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
        let task = session.webSocketTask(with: wreq)
        ws = task
        task.resume()
        receiveLoop()
    }

    /// Types a line into the terminal.
    func send(_ line: String) async throws {
        let payload = try JSONSerialization.data(withJSONObject: ["stdin", line + "\r"])
        try await ws?.send(.string(String(decoding: payload, as: UTF8.self)))
    }

    /// Waits until the output contains one of `markers`; returns the full output.
    func waitFor(_ markers: [String], timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if markers.contains(where: { output.contains($0) }) { return output }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ProvisionError("The rover didn't answer in time.")
    }

    /// Types a bash script into the terminal (see ProvisionScript.terminalLines) and waits
    /// for it to print the OK or FAIL marker. Returns the terminal output.
    func runScript(_ script: String, timeout: TimeInterval) async throws -> String {
        for line in ProvisionScript.terminalLines(for: script) {
            try await send(line)
        }
        return try await waitFor([ProvisionScript.okMarker, ProvisionScript.failMarker], timeout: timeout)
    }

    func close() async {
        ws?.cancel(with: .normalClosure, reason: nil)
        if let n = name {
            _ = try? await session.data(for: request("api/terminals/\(n)", method: "DELETE"))
        }
    }

    // MARK: - Private

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

    private func receiveLoop() {
        ws?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, case .success(let msg) = result else { return }
                let text: String? = switch msg {
                case .string(let s): s
                case .data(let d): String(data: d, encoding: .utf8)
                @unknown default: nil
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

struct ProvisionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
