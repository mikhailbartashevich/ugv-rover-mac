import Foundation
import Observation

/// Minimal Socket.IO v5 / Engine.IO v4 client over a websocket — just what the
/// rover's Flask-SocketIO server needs: namespaces /ctrl (modes, telemetry) and
/// /json (ESP32 commands), ping/pong, events in and out. Reconnects on its own.
@MainActor
@Observable
public final class RoverSocket {
    public enum State: Sendable { case disconnected, connecting, connected }

    public private(set) var state: State = .disconnected
    public private(set) var telemetry = Telemetry()
    public private(set) var lastUpdate: Date?
    public private(set) var jsonReady = false

    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private let session = URLSession(configuration: .ephemeral)
    @ObservationIgnored private var baseURL: URL?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    public init() {}

    public var isConnected: Bool { state == .connected }
    public var canSendJSON: Bool { state == .connected && jsonReady }

    public func connect(to base: URL) {
        disconnect()
        baseURL = base
        telemetry = Telemetry()
        lastUpdate = nil
        open()
    }

    public func disconnect() {
        generation += 1
        reconnectTask?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        jsonReady = false
        state = .disconnected
    }

    /// Mode/action command, same as the web UI's `cmdSend(A, B, C)`.
    @discardableResult
    public func emitCtrl(_ code: Int, b: Int = 0, c: Int = 0) -> Bool {
        guard state == .connected else { return false }
        let message = "{\"A\":\(code),\"B\":\(b),\"C\":\(c)}"
        guard let data = try? JSONSerialization.data(withJSONObject: ["message", message]),
              let s = String(data: data, encoding: .utf8) else { return false }
        sendRaw("42/ctrl," + s)
        return true
    }

    /// ESP32 command, like the web UI's `socketJson.emit('json', …)`.
    @discardableResult
    public func emit(_ command: ESP32Command) -> Bool {
        guard canSendJSON else { return false }
        sendRaw("42/json,[\"json\",\(command.json)]")
        return true
    }

    // MARK: - Engine.IO plumbing

    private func open() {
        guard let base = baseURL,
              var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return }
        c.scheme = "ws"
        c.path = "/socket.io/"
        c.queryItems = [URLQueryItem(name: "EIO", value: "4"), URLQueryItem(name: "transport", value: "websocket")]
        guard let url = c.url else { return }
        let t = session.webSocketTask(with: url)
        task = t
        jsonReady = false
        state = .connecting
        t.resume()
        receive(t, generation)
    }

    private func receive(_ t: URLSessionWebSocketTask, _ gen: Int) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    self.receive(t, gen)
                case .failure:
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func scheduleReconnect() {
        state = .disconnected
        jsonReady = false
        let gen = generation
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled, gen == self.generation else { return }
            self.open()
        }
    }

    private func handle(_ s: String) {
        if s.hasPrefix("0{") {                       // Engine.IO open → join namespaces
            sendRaw("40/ctrl,")
            sendRaw("40/json,")
        } else if s == "2" {                         // ping
            sendRaw("3")
        } else if s.hasPrefix("40/ctrl") {
            state = .connected
        } else if s.hasPrefix("40/json") {
            jsonReady = true
        } else if s.hasPrefix("42/ctrl,") {
            handleEvent(s.dropFirst("42/ctrl,".count))
        } else if s.hasPrefix("1") || s.hasPrefix("41/ctrl") {
            scheduleReconnect()
        }
    }

    private func handleEvent(_ body: Substring) {
        guard let data = body.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              arr.first as? String == "update",
              let dict = arr.dropFirst().first as? [String: Any] else { return }
        // The host sends zeros until the chassis reports in; the web UI ignores those too.
        if let v = (dict["112"] as? NSNumber)?.doubleValue, v == 0 { return }
        telemetry.apply(dict)
        lastUpdate = Date()
    }

    private func sendRaw(_ s: String) {
        task?.send(.string(s)) { _ in }
    }
}
