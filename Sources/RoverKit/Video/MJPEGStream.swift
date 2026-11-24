import AppKit
import Observation

/// Reader for the rover's `/video_feed` (multipart/x-mixed-replace JPEG stream).
///
/// Keeps itself alive: if the stream drops (e.g. the rover's program restarts) or
/// stalls with no frames, it reconnects every couple of seconds until `stop()`.
@MainActor
@Observable
public final class MJPEGStream: NSObject {
    public private(set) var image: NSImage?
    public private(set) var isRunning = false
    public private(set) var error: String?
    /// Frames per second measured on the Mac side.
    public private(set) var fps: Double = 0
    /// The stream dropped and is being re-opened.
    public private(set) var isReconnecting = false

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var task: URLSessionDataTask?
    @ObservationIgnored nonisolated(unsafe) private var buffer = Data()
    /// When the last frame arrived and the frame itself, for consumers that poll
    /// (not observed, so they don't trigger view updates on every frame).
    @ObservationIgnored public private(set) var lastFrameAt: Date?
    @ObservationIgnored public private(set) var latestCGImage: CGImage?
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var fpsWindowStart = Date()
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var watchdog: Timer?

    /// No frame for this long counts as a stall.
    static let stallTimeout: TimeInterval = 6

    public override init() { super.init() }

    public func start(url: URL) {
        self.url = url
        wantsRunning = true
        open(url)
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHealth() }
            }
        }
    }

    /// Stops for good (until the next `start`).
    public func stop() {
        wantsRunning = false
        isReconnecting = false
        watchdog?.invalidate()
        watchdog = nil
        close()
    }

    private func open(_ url: URL) {
        close()
        startedAt = Date()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        cfg.timeoutIntervalForResource = .infinity
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        session = s
        buffer = Data()
        task = s.dataTask(with: url)
        task?.resume()
        isRunning = true
        error = nil
    }

    private func close() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        isRunning = false
        fps = 0
    }

    /// The latest frame as JPEG data, for saving to disk.
    public var currentJPEG: Data? {
        guard let img = image, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    /// Re-opens the stream if it dropped or stalled.
    private func checkHealth() {
        guard wantsRunning, let url else { return }
        let lastSign = max(lastFrameAt ?? .distantPast, startedAt)
        if !isRunning || Date().timeIntervalSince(lastSign) > Self.stallTimeout {
            isReconnecting = true
            open(url)
        }
    }

    private func didReceive(_ img: NSImage) {
        isReconnecting = false
        image = img
        lastFrameAt = Date()
        latestCGImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        // Count frames and publish the rate once a second, not on every frame.
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(fpsWindowStart) >= 1 {
            fps = Double(frameCount) / now.timeIntervalSince(fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
        }
    }
}

extension MJPEGStream: URLSessionDataDelegate {
    nonisolated private static let soi = Data([0xFF, 0xD8])
    nonisolated private static let eoi = Data([0xFF, 0xD9])

    nonisolated public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        var latest: Data?
        while let start = buffer.range(of: Self.soi),
              let end = buffer.range(of: Self.eoi, in: start.upperBound..<buffer.endIndex) {
            latest = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        }
        if buffer.count > 5_000_000 { buffer.removeAll() }
        if let jpeg = latest, let img = NSImage(data: jpeg) {
            Task { @MainActor in self.didReceive(img) }
        }
    }

    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let msg = error.flatMap { ($0 as NSError).code == NSURLErrorCancelled ? nil : $0.localizedDescription }
        Task { @MainActor in
            guard self.task === task else { return }
            self.isRunning = false
            self.fps = 0
            self.error = msg ?? "Stream closed"
        }
    }
}
