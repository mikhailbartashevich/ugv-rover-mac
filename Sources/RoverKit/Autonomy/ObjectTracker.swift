import CoreGraphics
import Foundation
import Vision

/// Follows a box from frame to frame with Vision's object tracker. It can hold on to
/// targets far too small for the recognisers, so a distant cat that Claude (or a
/// lucky detection) spotted once stays locked while the rover drives towards it.
final class ObjectTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var handler = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?

    /// Below this the tracker is guessing.
    static let minimumConfidence: Float = 0.3

    var isActive: Bool { lock.withLock { request != nil } }

    /// Starts tracking `box` (normalised, top-left origin).
    func seed(_ box: CGRect) {
        let clipped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0.005, clipped.height > 0.005 else { return }
        lock.withLock {
            let obs = VNDetectedObjectObservation(boundingBox: TargetDetector.topLeft(clipped))  // flip is symmetric
            let r = VNTrackObjectRequest(detectedObjectObservation: obs)
            r.trackingLevel = .accurate
            request = r
            handler = VNSequenceRequestHandler()
        }
    }

    func reset() {
        lock.withLock { request = nil }
    }

    /// Where the tracked object is in this frame, or nil once the tracker loses it.
    func track(_ image: CGImage) -> (box: CGRect, confidence: Float)? {
        lock.withLock {
            guard let r = request else { return nil }
            do { try handler.perform([r], on: image) } catch { request = nil; return nil }
            guard let o = r.results?.first as? VNDetectedObjectObservation,
                  o.confidence >= Self.minimumConfidence else {
                request = nil
                return nil
            }
            r.inputObservation = o
            return (TargetDetector.topLeft(o.boundingBox), o.confidence)
        }
    }
}
