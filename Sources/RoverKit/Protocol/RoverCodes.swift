/// Action codes the rover's host program accepts on the Socket.IO `/ctrl` channel
/// (`{"A": code, "B": 0, "C": 0}`), as defined in ugv_rpi's config.yaml.
public enum RoverCode {
    public static let capturePhoto = 10201
    public static let recordStart = 10202
    public static let recordStop = 10203
    public static let movementLock = 10501
    public static let movementUnlock = 10502
    public static let chassisLightOff = 10407
    public static let chassisLightOn = 10408
}

/// Computer-vision mode. Only one can be active at a time.
public enum VisionMode: Int, CaseIterable, Identifiable, Sendable {
    case none = 10301
    case motion = 10302
    case faces = 10303
    case objects = 10304
    case color = 10305
    case hands = 10306
    case autoDrive = 10307
    case faceMesh = 10308
    case pose = 10309

    public var id: Int { rawValue }

    public enum Group: String, CaseIterable, Sendable {
        case basic = "Detection"
        case advanced = "Advanced Vision"
        case mediapipe = "MediaPipe"
    }

    public var group: Group {
        switch self {
        case .none, .motion, .faces: .basic
        case .objects, .color, .hands, .autoDrive: .advanced
        case .faceMesh, .pose: .mediapipe
        }
    }

    public var title: String {
        switch self {
        case .none: "Off"
        case .motion: "Motion"
        case .faces: "Faces"
        case .objects: "Objects"
        case .color: "Color"
        case .hands: "Hand Gestures"
        case .autoDrive: "Auto Drive"
        case .faceMesh: "Face Mesh"
        case .pose: "Body Pose"
        }
    }

    public var symbol: String {
        switch self {
        case .none: "eye.slash"
        case .motion: "figure.walk.motion"
        case .faces: "person.crop.square"
        case .objects: "shippingbox"
        case .color: "paintpalette"
        case .hands: "hand.raised"
        case .autoDrive: "steeringwheel"
        case .faceMesh: "face.dashed"
        case .pose: "figure.arms.open"
        }
    }
}

/// What the rover does when the vision mode detects something.
public enum DetectionReaction: Int, CaseIterable, Identifiable, Sendable {
    case none = 10401, capture = 10402, record = 10403
    public var id: Int { rawValue }
    public var title: String {
        switch self { case .none: "Nothing"; case .capture: "Take Photo"; case .record: "Record Video" }
    }
    public var symbol: String {
        switch self { case .none: "minus.circle"; case .capture: "camera"; case .record: "video" }
    }
}

public enum HeadLight: Int, CaseIterable, Identifiable, Sendable {
    case off = 0, auto = 1, on = 2
    public var id: Int { rawValue }
    public var code: Int { [10404, 10405, 10406][rawValue] }
    public var title: String { ["Off", "Auto", "On"][rawValue] }
    public var symbol: String { ["lightbulb.slash", "lightbulb.min", "lightbulb.max.fill"][rawValue] }
}

public enum CameraZoom: Int, CaseIterable, Identifiable, Sendable {
    case x1 = 1, x2 = 2, x4 = 4
    public var id: Int { rawValue }
    public var code: Int { switch self { case .x1: 10104; case .x2: 10105; case .x4: 10106 } }
    public var title: String { "\(rawValue)×" }
    public var next: CameraZoom { switch self { case .x1: .x2; case .x2: .x4; case .x4: .x1 } }
}

/// Speed presets, matching the web UI's Slow / Middle / Fast (min/mid/max_rate).
public enum SpeedPreset: String, CaseIterable, Identifiable, Sendable {
    case slow, middle, fast
    public var id: String { rawValue }
    public var rate: Double { switch self { case .slow: 0.3; case .middle: 0.66; case .fast: 1.0 } }
    public var title: String { switch self { case .slow: "Slow"; case .middle: "Middle"; case .fast: "Fast" } }
}

public enum RoverLimits {
    /// m/s at 100 % rate (config.yaml `max_speed`).
    public static let maxWheelSpeed = 1.3
    /// Inner wheel speed when driving in an arc (config.yaml `slow_speed`).
    public static let arcInnerWheelSpeed = 0.2
    public static let panRange: ClosedRange<Double> = -180...180
    public static let tiltRange: ClosedRange<Double> = -30...90
}
