import AppKit
import Observation

/// Minimal MJPEG (multipart/x-mixed-replace) reader for the rover's /video_feed.
@MainActor
@Observable
final class MJPEGStream: NSObject {
    var image: NSImage?
    var isRunning = false
    var error: String?

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var task: URLSessionDataTask?
    @ObservationIgnored nonisolated(unsafe) private var buffer = Data()

    func start(url: URL) {
        stop()
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

    func stop() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
        isRunning = false
    }
}

extension MJPEGStream: URLSessionDataDelegate {
    nonisolated private static let soi = Data([0xFF, 0xD8])
    nonisolated private static let eoi = Data([0xFF, 0xD9])

    nonisolated func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        var latest: Data?
        while let start = buffer.range(of: Self.soi),
              let end = buffer.range(of: Self.eoi, in: start.upperBound..<buffer.endIndex) {
            latest = buffer.subdata(in: start.lowerBound..<end.upperBound)
            buffer.removeSubrange(buffer.startIndex..<end.upperBound)
        }
        if buffer.count > 5_000_000 { buffer.removeAll() }
        if let jpeg = latest, let img = NSImage(data: jpeg) {
            Task { @MainActor in self.image = img }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let msg = error.flatMap { ($0 as NSError).code == NSURLErrorCancelled ? nil : $0.localizedDescription }
        Task { @MainActor in
            if self.task === task {
                self.isRunning = false
                self.error = msg ?? "Stream closed"
            }
        }
    }
}
