import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Observation

/// "Follow the cat": watches the video, finds the target on the Mac ~8× a second
/// and steers the rover gently towards it. Optionally asks Claude every few seconds
/// about obstacles and where the target went. Any manual input stops it.
@MainActor
@Observable
public final class FollowController {
    public enum Phase: String, Sendable {
        case off, looking, following, holding, searching, lost, blocked, noVideo
        public var title: String {
            switch self {
            case .off: "Off"
            case .looking: "Looking"
            case .following: "Following"
            case .holding: "Close enough"
            case .searching: "Searching"
            case .lost: "Lost"
            case .blocked: "Obstacle ahead"
            case .noVideo: "No video"
            }
        }
    }

    public private(set) var phase: Phase = .off
    public var isActive: Bool { phase != .off }
    public var target: FollowTarget = .cat
    public var settings = FollowSettings()
    public private(set) var detection: Detection?
    public private(set) var command = DriveCommand.zero

    // Claude
    public var claudeEnabled = false
    /// Seconds between Claude checks while following (halved while searching).
    public var claudeInterval: Double = 5
    public private(set) var advice: ClaudeAdvice?
    public private(set) var claudeError: String?
    public private(set) var claudeBusy = false
    public private(set) var claudeRequests = 0
    public let claude: ClaudeVision

    private let rover: RoverClient
    private let video: MJPEGStream
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var detecting = false
    @ObservationIgnored private var lastSeen: Date?
    @ObservationIgnored private var lastSide: Double = 1
    @ObservationIgnored private var searchStarted: Date?
    @ObservationIgnored private var lastClaudeAt: Date?
    @ObservationIgnored private var blockedUntil: Date?
    @ObservationIgnored private var movingSent = false
    @ObservationIgnored private let tracker = ObjectTracker()
    /// Last time the detector or Claude (not just the tracker) saw the target.
    @ObservationIgnored private var lastConfirmed: Date?
    /// How long the tracker may follow on its own before it must be confirmed.
    static let trackerOnlyLimit: TimeInterval = 10

    public init(rover: RoverClient, video: MJPEGStream, claude: ClaudeVision) {
        self.rover = rover
        self.video = video
        self.claude = claude
    }

    // MARK: - Start / stop

    public func toggle() { isActive ? stop() : start() }

    public func start() {
        guard phase == .off else { return }
        phase = .looking
        tracker.reset()
        detection = nil
        lastSeen = nil
        searchStarted = nil
        blockedUntil = nil
        advice = nil
        claudeError = nil
        rover.onManualOverride = { [weak self] in self?.stop(reason: "Manual control — stopped following") }
        // Steering assumes the camera looks straight ahead.
        if abs(rover.pan) > 1 || rover.steady { rover.setGimbal(pan: 0, tilt: rover.tilt) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.125, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        rover.show("Following the \(target.rawValue)", symbol: "pawprint.fill")
    }

    public func stop(reason: String? = nil) {
        guard phase != .off else { return }
        timer?.invalidate()
        timer = nil
        phase = .off
        detection = nil
        command = .zero
        movingSent = false
        rover.onManualOverride = nil
        rover.send(.stop)
        rover.show(reason ?? "Stopped following", symbol: "pawprint")
    }

    // MARK: - Loop

    private func tick() {
        guard let at = video.lastFrameAt, Date().timeIntervalSince(at) < 0.8, let frame = video.latestCGImage else {
            phase = .noVideo
            drive(.zero)
            return
        }
        askClaudeIfDue(frame)
        guard !detecting else { return }
        detecting = true
        let target = self.target
        let previous = detection?.box
        let tracker = self.tracker
        Task { [weak self] in
            // Vision runs off the main thread; results come back here. Recognition first;
            // if it misses, the object tracker keeps hold of a target seen earlier.
            let found = await Task.detached(priority: .userInitiated) { () -> Detection? in
                if let d = TargetDetector.detect(frame, target: target, near: previous) {
                    tracker.seed(d.box)
                    return d
                }
                if let t = tracker.track(frame) {
                    return Detection(label: target.rawValue, confidence: t.confidence, box: t.box, source: .tracker)
                }
                return nil
            }.value
            self?.detecting = false
            self?.handle(found)
        }
    }

    private func handle(_ local: Detection?) {
        guard phase != .off else { return }
        let now = Date()

        // Fall back to Claude's box if it's fresh and the on-device detector missed.
        var found = local
        if let d = found {
            if d.source == .tracker {
                if let c = lastConfirmed, now.timeIntervalSince(c) > Self.trackerOnlyLimit {
                    tracker.reset()                       // unconfirmed too long: it may have drifted
                    found = nil
                }
            } else {
                lastConfirmed = now
            }
        }
        if found == nil, let a = advice, a.targetVisible, let box = a.box, now.timeIntervalSince(a.date) < 1.5 {
            found = Detection(label: target.rawValue, confidence: 0.5, box: box, source: .claude)
        }

        if let d = found {
            detection = d
            lastSeen = now
            searchStarted = nil
            lastSide = d.box.midX < 0.5 ? 1 : -1
            var cmd = FollowPlanner.command(for: d.box, settings: settings)
            if let until = blockedUntil, now < until, cmd.linear > 0 {
                cmd.linear = 0
                phase = .blocked
            } else {
                phase = cmd.isZero ? .holding : .following
            }
            drive(smoothed(cmd))
            return
        }

        let since = lastSeen.map { now.timeIntervalSince($0) } ?? .infinity
        if since < 0.6 {                                     // brief miss: coast down
            drive(DriveCommand(linear: command.linear * 0.5, angular: command.angular * 0.5))
            return
        }
        detection = nil

        if settings.searchWhenLost, lastSeen != nil, since > 1.2 {
            if searchStarted == nil { searchStarted = now }
            if let start = searchStarted, now.timeIntervalSince(start) < 12 {
                phase = .searching
                drive(DriveCommand(linear: 0, angular: 0.35 * searchSide(now)))
                return
            }
        }
        phase = lastSeen == nil ? .looking : .lost
        drive(.zero)
    }

    /// Claude's hint wins if it's recent; otherwise the side we last saw the target on.
    private func searchSide(_ now: Date) -> Double {
        if let a = advice, now.timeIntervalSince(a.date) < 6 {
            switch a.direction {
            case .left: return 1
            case .right: return -1
            default: break
            }
        }
        return lastSide
    }

    /// Eases changes between cycles, without dropping below the motors' minimum.
    private func smoothed(_ c: DriveCommand) -> DriveCommand {
        var out = DriveCommand(linear: command.linear * 0.4 + c.linear * 0.6,
                               angular: command.angular * 0.4 + c.angular * 0.6)
        if c.linear == 0 { out.linear = 0 } else { out.linear = max(out.linear, settings.minSpeed) }
        if c.angular == 0 { out.angular = 0 }
        else if abs(out.angular) < settings.minTurn { out.angular = c.angular < 0 ? -settings.minTurn : settings.minTurn }
        return out
    }

    /// Sends every cycle while moving (the ESP32 stops on its own otherwise); one stop when idle.
    private func drive(_ c: DriveCommand) {
        command = c
        if c.isZero {
            if movingSent { rover.send(.stop); movingSent = false }
        } else {
            rover.send(.velocity(linear: c.linear, angular: c.angular))
            movingSent = true
        }
    }

    // MARK: - Claude

    private func askClaudeIfDue(_ frame: CGImage) {
        guard claudeEnabled, !claudeBusy, claude.isAvailable else { return }
        let searching = phase == .searching || phase == .lost || phase == .looking
        let interval = searching ? max(2.5, claudeInterval / 2) : claudeInterval
        if let last = lastClaudeAt, Date().timeIntervalSince(last) < interval { return }
        // Without a local fix, send the frame at full size so Claude can spot a distant target.
        guard let jpeg = Self.jpeg(frame, maxSide: detection == nil ? 1600 : 640) else { return }

        lastClaudeAt = Date()
        claudeBusy = true
        claudeRequests += 1
        let context = "Rover state: \(phase.title.lowercased()). " +
            (detection.map { "On-device tracker sees the \(target.rawValue) at x=\(String(format: "%.2f", $0.box.midX)) of the frame width." }
             ?? "On-device tracker does not see the \(target.rawValue).")
        Task {
            do {
                let a = try await claude.advise(jpeg: jpeg, target: target, context: context)
                advice = a
                claudeError = nil
                // Claude spotted a target the Mac can't see (often a distant one): track it.
                if a.targetVisible, let box = a.box {
                    lastConfirmed = Date()
                    if detection == nil { tracker.seed(box) }
                }
                if a.obstacleAhead || !a.safeToDrive { blockedUntil = Date().addingTimeInterval(4) }
            } catch {
                claudeError = error.localizedDescription
            }
            claudeBusy = false
        }
    }

    static func jpeg(_ image: CGImage, maxSide: Int) -> Data? {
        let scale = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
