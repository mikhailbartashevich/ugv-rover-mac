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
    public enum Source: String, Sendable { case detector, saliency, claude, tracker }
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
///
/// Far-away targets are only a few dozen pixels tall, too small for a whole-frame
/// look. So each frame is searched in three steps, stopping at the first hit:
/// 1. a zoomed-in region around where the target was last seen,
/// 2. the whole frame,
/// 3. overlapping tiles (3 × 2, then 5 × 4), each analysed on its own — a digital
///    zoom that lets distant targets fill enough of the image to be recognised.
public enum TargetDetector {
    /// Overlapping tiles covering the frame (normalised, top-left origin): a coarse
    /// 3 × 2 grid, then — only if that finds nothing — a fine 5 × 4 grid for very
    /// distant targets.
    static let coarseTiles = grid(columns: 3, rows: 2, size: CGSize(width: 0.45, height: 0.6))
    static let fineTiles = grid(columns: 5, rows: 4, size: CGSize(width: 0.28, height: 0.36))

    static func grid(columns: Int, rows: Int, size: CGSize) -> [CGRect] {
        (0..<rows).flatMap { r in
            (0..<columns).map { c in
                CGRect(x: (1 - size.width) * CGFloat(c) / CGFloat(max(columns - 1, 1)),
                       y: (1 - size.height) * CGFloat(r) / CGFloat(max(rows - 1, 1)),
                       width: size.width, height: size.height)
            }
        }
    }

    public static func detect(_ image: CGImage, target: FollowTarget, near previous: CGRect?,
                              search: Bool = true) -> Detection? {
        if let p = previous, let roi = regionOfInterest(around: p),
           let d = detect(in: image, region: roi, target: target, near: p) {
            return d
        }
        if let d = detect(in: image, region: nil, target: target, near: previous) { return d }
        guard search else { return nil }
        for tiles in [coarseTiles, fineTiles] {
            if let best = tiles.compactMap({ detect(in: image, region: $0, target: target, near: nil) })
                .max(by: { $0.confidence < $1.confidence }) {
                return best
            }
        }
        return nil
    }

    /// A square-ish window about three times the last box, at least 40 % of the frame.
    static func regionOfInterest(around box: CGRect) -> CGRect? {
        let w = min(1, max(0.4, box.width * 3)), h = min(1, max(0.4, box.height * 3))
        guard w * h < 0.8 else { return nil }                 // no gain over the whole frame
        let x = (box.midX - w / 2).clamped(to: 0...(1 - w))
        let y = (box.midY - h / 2).clamped(to: 0...(1 - h))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Runs one pass on `region` of the image (nil = all of it); boxes come back in frame coordinates.
    static func detect(in image: CGImage, region: CGRect?, target: FollowTarget, near previous: CGRect?) -> Detection? {
        var input = image
        if let r = region {
            let px = CGRect(x: r.minX * CGFloat(image.width), y: r.minY * CGFloat(image.height),
                            width: r.width * CGFloat(image.width), height: r.height * CGFloat(image.height)).integral
            guard let cropped = image.cropping(to: px) else { return nil }
            input = cropped
        }
        let toLocal: (CGRect) -> CGRect = { b in
            guard let r = region else { return b }
            return CGRect(x: (b.minX - r.minX) / r.width, y: (b.minY - r.minY) / r.height,
                          width: b.width / r.width, height: b.height / r.height)
        }
        let toFrame: (CGRect) -> CGRect = { b in
            guard let r = region else { return b }
            return CGRect(x: r.minX + b.minX * r.width, y: r.minY + b.minY * r.height,
                          width: b.width * r.width, height: b.height * r.height)
        }
        guard let d = pass(input, target: target, near: previous.map(toLocal)) else { return nil }
        return Detection(label: d.label, confidence: d.confidence, box: toFrame(d.box), source: d.source)
    }

    /// Detection on one image, boxes relative to that image.
    static func pass(_ image: CGImage, target: FollowTarget, near previous: CGRect?) -> Detection? {
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
