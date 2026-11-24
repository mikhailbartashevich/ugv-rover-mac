import AppKit
import AVFoundation
import CoreImage
import Observation
import VideoToolbox

/// The rover's camera: H.264 from its mediamtx over RTSP/TCP (`rtsp://<ip>:8554/cam`),
/// decoded in hardware and shown on `displayLayer` the moment each frame arrives.
///
/// Keeps itself alive: if the stream drops (e.g. the rover's program restarts) or stalls,
/// it reconnects every couple of seconds until `stop()`.
@MainActor
@Observable
public final class VideoStream {
    /// At least one frame has been shown since `start`.
    public private(set) var hasFrame = false
    /// Pixel size of the video.
    public private(set) var videoSize = CGSize(width: 4, height: 3)
    /// Video is on (it may be reconnecting); false after `stop()`.
    public private(set) var isRunning = false
    public private(set) var error: String?
    /// Frames per second measured on the Mac side.
    public private(set) var fps: Double = 0
    /// The stream dropped and is being re-opened.
    public private(set) var isReconnecting = false

    /// Shows the decoded frames. Owned here so it survives view updates.
    @ObservationIgnored public let displayLayer = AVSampleBufferDisplayLayer()
    /// The layer's renderer, fed from the video queue (enqueueing is thread-safe).
    @ObservationIgnored private let renderer: AVSampleBufferVideoRenderer
    /// When the last frame arrived (not observed, so polling it doesn't redraw views).
    @ObservationIgnored public private(set) var lastFrameAt: Date?
    @ObservationIgnored private var latestPixelBuffer: CVPixelBuffer?
    @ObservationIgnored private var latestImageCache: CGImage?

    @ObservationIgnored private let queue = DispatchQueue(label: "rover.video", qos: .userInteractive)
    @ObservationIgnored private var client: RTSPClient?
    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var connected = false
    @ObservationIgnored private var openedAt = Date()
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var frameCount = 0
    @ObservationIgnored private var fpsWindowStart = Date()

    /// No RTP packets for this long counts as a stall.
    static let stallTimeout: TimeInterval = 5
    /// The rover sends a keyframe only every ~8 s (x264 default GOP), so the first
    /// picture can take that long; give up on a connection that shows nothing for longer.
    static let firstFrameTimeout: TimeInterval = 20

    public init() {
        renderer = displayLayer.sampleBufferRenderer
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = .clear
    }

    public func start(url: URL) {
        self.url = url
        isRunning = true
        hasFrame = false
        error = nil
        open(url)
        if watchdog == nil {
            watchdog = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkHealth() }
            }
        }
    }

    /// Stops for good (until the next `start`).
    public func stop() {
        isRunning = false
        isReconnecting = false
        watchdog?.invalidate()
        watchdog = nil
        close()
    }

    /// The latest frame, for detection. Made on demand, cached until the next frame.
    public var latestCGImage: CGImage? {
        if let latestImageCache { return latestImageCache }
        guard let pb = latestPixelBuffer else { return nil }
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &image)
        latestImageCache = image
        return image
    }

    /// The latest frame as JPEG data, for saving to disk.
    public var currentJPEG: Data? {
        guard let cg = latestCGImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    }

    // MARK: - Connection

    private func open(_ url: URL) {
        close()
        generation += 1
        let gen = generation
        openedAt = Date()
        connected = true

        let client = RTSPClient(url: url, queue: queue)
        let decoder = H264Decoder()
        nonisolated(unsafe) let renderer = renderer
        client.onParameterSets = { decoder.setParameterSets($0) }
        client.onAccessUnit = { [weak self] nals, ts in
            guard let pb = decoder.decode(nals, timestamp: ts) else { return }
            Self.show(pb, on: renderer)
            Task { @MainActor in self?.didDecode(pb, gen) }
        }
        client.onClose = { [weak self] reason in
            Task { @MainActor in self?.didClose(reason, gen) }
        }
        self.client = client
        queue.async { client.start() }
    }

    private func close() {
        if let client { queue.async { client.stop() } }
        client = nil
        connected = false
        fps = 0
    }

    /// Re-opens the stream if it dropped or stalled.
    private func checkHealth() {
        guard isRunning, let url else { return }
        let now = Date()
        let lastPacket = client?.lastPacketAt
        let stalled: Bool
        if !connected {
            stalled = now.timeIntervalSince(openedAt) > 2
        } else if let lastPacket {
            let lastFrame = max(lastFrameAt ?? .distantPast, openedAt)
            stalled = now.timeIntervalSince(lastPacket) > Self.stallTimeout
                || now.timeIntervalSince(lastFrame) > Self.firstFrameTimeout
        } else {
            stalled = now.timeIntervalSince(openedAt) > Self.stallTimeout + 3
        }
        if stalled {
            if hasFrame { isReconnecting = true }
            open(url)
        }
    }

    private func didClose(_ reason: String, _ gen: Int) {
        guard gen == generation else { return }
        connected = false
        fps = 0
        error = reason
        if isRunning && hasFrame && !isReconnecting { isReconnecting = true }
    }

    private func didDecode(_ pb: CVPixelBuffer, _ gen: Int) {
        guard gen == generation else { return }
        latestPixelBuffer = pb
        latestImageCache = nil
        lastFrameAt = Date()
        if !hasFrame { hasFrame = true }
        if isReconnecting { isReconnecting = false }
        if error != nil { error = nil }
        let size = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        if size != videoSize { videoSize = size }
        // Count frames and publish the rate once a second, not on every frame.
        frameCount += 1
        let now = Date()
        if now.timeIntervalSince(fpsWindowStart) >= 1 {
            fps = Double(frameCount) / now.timeIntervalSince(fpsWindowStart)
            frameCount = 0
            fpsWindowStart = now
        }
    }

    /// Hands a decoded frame to the layer, to be shown right away (no clock, no queueing).
    nonisolated private static func show(_ pb: CVPixelBuffer, on renderer: AVSampleBufferVideoRenderer) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format) == noErr,
              let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
