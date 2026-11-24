import Foundation
import Network

/// Minimal RTSP client for one H.264 track, RTP interleaved over the RTSP TCP connection
/// (RFC 2326 §10.12) — what the rover's mediamtx serves at `rtsp://<ip>:8554/cam`.
/// TCP avoids the rover's firewall/NAT questions and loses nothing on Wi‑Fi.
///
/// Everything runs on `queue`. Callbacks: `onParameterSets` with SPS/PPS from the SDP,
/// `onAccessUnit` with the NAL units of each frame, `onClose` once with a reason.
final class RTSPClient: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible { let description: String }

    var onParameterSets: (([Data]) -> Void)?
    var onAccessUnit: (([Data], UInt32) -> Void)?
    var onClose: ((String) -> Void)?
    /// Time of the last RTP packet (for stall detection; readable from any thread).
    var lastPacketAt: Date? {
        packetLock.lock(); defer { packetLock.unlock() }
        return _lastPacketAt
    }
    private var _lastPacketAt: Date?
    private let packetLock = NSLock()

    private let url: URL
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var buffer = Data()
    private var cseq = 0
    private var session: String?
    private var step = Step.options
    private var trackURL: String = ""
    private var payloadType: UInt8 = 96
    private var depacketizer = H264Depacketizer()
    private var keepAlive: DispatchSourceTimer?
    private var closed = false

    private enum Step { case options, describe, setup, play, playing }

    init(url: URL, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
    }

    func start() {
        guard let host = url.host(), let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 554)) else {
            return close("Bad video address \(url.absoluteString)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        let conn = NWConnection(host: NWEndpoint.Host(host), port: port, using: NWParameters(tls: nil, tcp: tcp))
        connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.request("OPTIONS", self.url.absoluteString)
                self.receive()
            case .failed(let e), .waiting(let e):
                self.close("Can't reach the rover's video stream (\(e.localizedDescription))")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    func stop() {
        guard !closed else { return }
        if session != nil { request("TEARDOWN", url.absoluteString) }
        closed = true
        teardown()
    }

    // MARK: - RTSP

    private func request(_ method: String, _ target: String, _ headers: [String] = []) {
        cseq += 1
        var lines = ["\(method) \(target) RTSP/1.0", "CSeq: \(cseq)", "User-Agent: UGVControl"]
        if let session { lines.append("Session: \(session)") }
        lines += headers
        let text = lines.joined(separator: "\r\n") + "\r\n\r\n"
        connection?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    private func handleResponse(status: Int, headers: [String: String], body: Data) {
        guard status == 200 else {
            if step == .playing { return }   // a failed keep-alive isn't fatal
            let hint = status == 404 ? " The rover isn't publishing its camera yet." : ""
            return close("The rover's video server answered \(status).\(hint)")
        }
        switch step {
        case .options:
            step = .describe
            request("DESCRIBE", url.absoluteString, ["Accept: application/sdp"])
        case .describe:
            let sdp = String(decoding: body, as: UTF8.self)
            guard let track = SDP.h264Track(sdp) else { return close("The rover's stream has no H.264 video.") }
            payloadType = track.payloadType
            if !track.parameterSets.isEmpty { onParameterSets?(track.parameterSets) }
            let base = headers["content-base"] ?? headers["content-location"] ?? url.absoluteString
            trackURL = SDP.resolve(control: track.control, base: base)
            step = .setup
            request("SETUP", trackURL, ["Transport: RTP/AVP/TCP;unicast;interleaved=0-1"])
        case .setup:
            session = headers["session"]?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) }
            step = .play
            request("PLAY", url.absoluteString, ["Range: npt=0.000-"])
        case .play:
            step = .playing
            startKeepAlive(timeout: headers["session"].flatMap(SDP.sessionTimeout) ?? 60)
        case .playing:
            break
        }
    }

    /// mediamtx drops readers that stay silent past its timeout; ping it well before.
    private func startKeepAlive(timeout: Int) {
        let t = DispatchSource.makeTimerSource(queue: queue)
        let every = Double(max(2, min(timeout / 3, 15)))
        t.schedule(deadline: .now() + every, repeating: every)
        t.setEventHandler { [weak self] in
            guard let self, !self.closed else { return }
            self.request("GET_PARAMETER", self.url.absoluteString)
        }
        t.resume()
        keepAlive = t
    }

    // MARK: - Reading

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, done, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data); self.parse() }
            if let error { return self.close("Video connection lost (\(error.localizedDescription))") }
            if done { return self.close("The rover closed the video stream.") }
            self.receive()
        }
    }

    private func parse() {
        while !buffer.isEmpty, !closed {
            let b = buffer
            let s = b.startIndex
            if b[s] == 0x24 {                                     // '$' interleaved binary frame
                guard b.count >= 4 else { return }
                let channel = b[s + 1]
                let length = Int(b[s + 2]) << 8 | Int(b[s + 3])
                guard b.count >= 4 + length else { return }
                if channel == 0 { handleRTP(b.subdata(in: s + 4 ..< s + 4 + length)) }
                buffer = b.subdata(in: s + 4 + length ..< b.endIndex)
            } else if b.count < 5, Data("RTSP/".utf8).starts(with: b) {
                return                                             // partial status line
            } else if b.starts(with: Data("RTSP/".utf8)) {
                guard let end = b.range(of: Data("\r\n\r\n".utf8)) else { return }
                let head = String(decoding: b[s ..< end.lowerBound], as: UTF8.self)
                var lines = head.components(separatedBy: "\r\n")
                let statusLine = lines.removeFirst().split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines {
                    guard let colon = line.firstIndex(of: ":") else { continue }
                    headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard b.count >= b.distance(from: s, to: end.upperBound) + length else { return }
                let body = b.subdata(in: end.upperBound ..< end.upperBound + length)
                buffer = b.subdata(in: end.upperBound + length ..< b.endIndex)
                handleResponse(status: statusLine.count > 1 ? Int(statusLine[1]) ?? 0 : 0, headers: headers, body: body)
            } else {
                // Out of sync: skip to the next frame or response.
                let next = b.dropFirst().firstIndex { $0 == 0x24 || $0 == 0x52 } ?? b.endIndex
                buffer = b.subdata(in: next ..< b.endIndex)
            }
        }
    }

    private func handleRTP(_ p: Data) {
        guard let packet = RTPPacket(p), packet.payloadType == payloadType else { return }
        packetLock.lock(); _lastPacketAt = Date(); packetLock.unlock()
        for unit in depacketizer.push(packet) { onAccessUnit?(unit.nals, unit.timestamp) }
    }

    // MARK: - Closing

    private func close(_ reason: String) {
        guard !closed else { return }
        closed = true
        teardown()
        onClose?(reason)
    }

    private func teardown() {
        keepAlive?.cancel()
        keepAlive = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        onAccessUnit = nil
        onParameterSets = nil
    }
}

// MARK: - SDP

enum SDP {
    struct Track: Equatable {
        var payloadType: UInt8
        var control: String
        var parameterSets: [Data]
    }

    /// The first H.264 video track of a session description.
    static func h264Track(_ sdp: String) -> Track? {
        var inVideo = false
        var pt: UInt8?
        var control = ""
        var sets: [Data] = []
        var formats: [UInt8] = []
        for raw in sdp.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                if inVideo, pt != nil { break }
                inVideo = line.hasPrefix("m=video")
                formats = line.split(separator: " ").dropFirst(3).compactMap { UInt8($0) }
                continue
            }
            guard inVideo else { continue }
            if line.hasPrefix("a=rtpmap:") {
                let parts = line.dropFirst(9).split(separator: " ", maxSplits: 1)
                if parts.count == 2, parts[1].uppercased().hasPrefix("H264/"), let n = UInt8(parts[0]) { pt = n }
            } else if line.hasPrefix("a=control:") {
                control = String(line.dropFirst(10))
            } else if line.hasPrefix("a=fmtp:"), let r = line.range(of: "sprop-parameter-sets=") {
                let value = line[r.upperBound...].prefix { $0 != ";" && $0 != " " }
                sets = value.split(separator: ",").compactMap { Data(base64Encoded: padded(String($0))) }
            }
        }
        guard inVideo || pt != nil, let type = pt ?? formats.first else { return nil }
        return Track(payloadType: type, control: control, parameterSets: sets)
    }

    static func resolve(control: String, base: String) -> String {
        if control.isEmpty || control == "*" { return base }
        if control.lowercased().hasPrefix("rtsp://") { return control }
        return base.hasSuffix("/") ? base + control : base + "/" + control
    }

    /// `Session: 12345;timeout=60` → 60.
    static func sessionTimeout(_ header: String) -> Int? {
        guard let r = header.range(of: "timeout=") else { return nil }
        return Int(header[r.upperBound...].prefix { $0.isNumber })
    }

    private static func padded(_ s: String) -> String {
        s + String(repeating: "=", count: (4 - s.count % 4) % 4)
    }
}

// MARK: - RTP / H.264 (RFC 3550, RFC 6184)

struct RTPPacket {
    var payloadType: UInt8
    var marker: Bool
    var sequence: UInt16
    var timestamp: UInt32
    var payload: Data

    init?(_ d: Data) {
        let b = [UInt8](d)
        guard b.count >= 12, b[0] >> 6 == 2 else { return nil }
        var start = 12 + Int(b[0] & 0x0F) * 4
        if b[0] & 0x10 != 0 {                               // header extension
            guard b.count >= start + 4 else { return nil }
            start += 4 + (Int(b[start + 2]) << 8 | Int(b[start + 3])) * 4
        }
        var end = b.count
        if b[0] & 0x20 != 0, let pad = b.last { end -= Int(pad) }  // padding
        guard start < end else { return nil }
        payloadType = b[1] & 0x7F
        marker = b[1] & 0x80 != 0
        sequence = UInt16(b[2]) << 8 | UInt16(b[3])
        timestamp = UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7])
        payload = Data(b[start ..< end])
    }
}

/// Reassembles NAL units (single, STAP-A, FU-A) into whole frames.
struct H264Depacketizer {
    struct AccessUnit { var nals: [Data]; var timestamp: UInt32 }

    private var nals: [Data] = []
    private var timestamp: UInt32?
    private var fragment: Data?
    private var lastSequence: UInt16?
    private var corrupt = false

    /// Returns the frames this packet completes (usually none or one).
    mutating func push(_ p: RTPPacket) -> [AccessUnit] {
        var done: [AccessUnit] = []
        if let ts = timestamp, ts != p.timestamp, let u = flush() { done.append(u) }   // marker was missed
        if let last = lastSequence, p.sequence != last &+ 1 {
            fragment = nil
            corrupt = true
        }
        lastSequence = p.sequence
        timestamp = p.timestamp

        let b = [UInt8](p.payload)
        guard let first = b.first else { return done }
        switch first & 0x1F {
        case 1...23:
            nals.append(p.payload)
        case 24:                                               // STAP-A
            var i = 1
            while i + 2 <= b.count {
                let n = Int(b[i]) << 8 | Int(b[i + 1])
                i += 2
                guard n > 0, i + n <= b.count else { break }
                nals.append(Data(b[i ..< i + n]))
                i += n
            }
        case 28:                                               // FU-A
            guard b.count > 2 else { break }
            let header = b[1]
            if header & 0x80 != 0 {
                fragment = Data([(first & 0xE0) | (header & 0x1F)]) + Data(b[2...])
            } else if fragment != nil {
                fragment?.append(contentsOf: b[2...])
            }
            if header & 0x40 != 0, let f = fragment {
                nals.append(f)
                fragment = nil
            }
        default:
            break
        }
        if p.marker, let u = flush() { done.append(u) }
        return done
    }

    private mutating func flush() -> AccessUnit? {
        defer { nals = []; timestamp = nil; fragment = nil; corrupt = false }
        guard !nals.isEmpty, !corrupt, let ts = timestamp else { return nil }
        return AccessUnit(nals: nals, timestamp: ts)
    }
}
