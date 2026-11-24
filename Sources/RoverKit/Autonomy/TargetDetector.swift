import CoreGraphics
import Vision

/// What the rover can follow.
public enum FollowTarget: String, CaseIterable, Identifiable, Sendable {
    case cat, dog, person
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self { case .cat: "cat.fill"; case .dog: "dog.fill"; case .person: "figure.stand" }
    }
}

/// Where the target is in a frame. `box` is normalised (0…1) with the origin top-left.
public struct Detection: Sendable, Equatable {
    public enum Source: String, Sendable { case detector, saliency, claude }
    public let label: String
    public let confidence: Float
    public let box: CGRect
    public let source: Source

    public init(label: String, confidence: Float, box: CGRect, source: Source) {
        self.label = label
        self.confidence = confidence
        self.box = box
        self.source = source
    }
}

/// On-device detection with Apple's Vision framework.
///
/// Rover camera frames are small and blurry, where Vision's animal detector often
/// finds nothing. So for animals it falls back to: "does the scene classifier say
/// there's a cat?" + "where is the most salient object?", picking the object
/// closest to where the target was last seen.
public enum TargetDetector {
    public static func detect(_ image: CGImage, target: FollowTarget, near previous: CGRect?) -> Detection? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        switch target {
        case .person:
            let req = VNDetectHumanRectanglesRequest()
            req.upperBodyOnly = false
            try? handler.perform([req])
            let found = (req.results ?? []).map {
                Detection(label: "person", confidence: $0.confidence, box: topLeft($0.boundingBox), source: .detector)
            }
            return pick(found, near: previous)

        case .cat, .dog:
            let animals = VNRecognizeAnimalsRequest()
            let classify = VNClassifyImageRequest()
            let salient = VNGenerateObjectnessBasedSaliencyImageRequest()
            try? handler.perform([animals, classify, salient])

            let direct = (animals.results ?? []).compactMap { o -> Detection? in
                guard let l = o.labels.first, l.identifier.lowercased() == target.rawValue, l.confidence > 0.3 else { return nil }
                return Detection(label: target.rawValue, confidence: l.confidence, box: topLeft(o.boundingBox), source: .detector)
            }
            if let d = pick(direct, near: previous) { return d }

            let sceneConfidence = classify.results?.first { $0.identifier == target.rawValue }?.confidence ?? 0
            let boxes = (salient.results?.first?.salientObjects ?? []).map { (topLeft($0.boundingBox), $0.confidence) }
                .filter { $0.0.width * $0.0.height > 0.01 && $0.0.width * $0.0.height < 0.95 }

            if sceneConfidence >= 0.15 {
                let objects = boxes.map {
                    Detection(label: target.rawValue, confidence: min(sceneConfidence * 2, $0.1), box: $0.0, source: .saliency)
                }
                return pick(objects, near: previous)
            }
            // The scene classifier flickers frame to frame. If we were just tracking the
            // target, keep following the salient object that overlaps where it was.
            guard let p = previous else { return nil }
            return boxes.filter { iou($0.0, p) > 0.3 }
                .max { iou($0.0, p) < iou($1.0, p) }
                .map { Detection(label: target.rawValue, confidence: 0.3, box: $0.0, source: .saliency) }
        }
    }

    /// The candidate nearest the previous box, or the most confident one.
    static func pick(_ candidates: [Detection], near previous: CGRect?) -> Detection? {
        guard let p = previous else { return candidates.max { $0.confidence < $1.confidence } }
        return candidates.min { distance($0.box, p) < distance($1.box, p) }
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        hypot(a.midX - b.midX, a.midY - b.midY)
    }

    /// Vision uses a bottom-left origin.
    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }
}
