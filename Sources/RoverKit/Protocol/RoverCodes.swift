/// A command on the rover's Socket.IO `/ctrl` channel: `{"cmd": X, "mode": Y}`, the way
/// the stock web UI's `cmdSend(cmd, mode)` sends it. `cmd` picks the action and `mode`
/// is its argument; both are codes from ugv_rpi's config.yaml (`code:` and `fb:`).
public struct CtrlCommand: Equatable, Sendable {
    public let cmd: Int
    public let mode: Int

    public init(_ cmd: Int, mode: Int = 0) {
        self.cmd = cmd
        self.mode = mode
    }

    public var json: String { #"{"cmd":\#(cmd),"mode":\#(mode)}"# }

    public static let capturePhoto = CtrlCommand(RoverCode.capturePhoto)
    public static func recording(_ on: Bool) -> CtrlCommand { CtrlCommand(RoverCode.video, mode: on ? 1 : 0) }
    public static func zoom(_ z: CameraZoom) -> CtrlCommand { CtrlCommand(RoverCode.zoom, mode: z.rawValue) }
    public static func vision(_ m: VisionMode) -> CtrlCommand { CtrlCommand(RoverCode.detectType, mode: m.rawValue) }
    public static func reaction(_ r: DetectionReaction) -> CtrlCommand { CtrlCommand(RoverCode.detectReact, mode: r.rawValue) }
    public static func headLight(_ l: HeadLight) -> CtrlCommand { CtrlCommand(RoverCode.headLight, mode: l.code) }
    public static func movementLocked(_ locked: Bool) -> CtrlCommand {
        CtrlCommand(RoverCode.movementLock, mode: locked ? RoverCode.lockOn : RoverCode.lockOff)
    }
    /// Chassis lights: `mode` is the PWM value, 0…255.
    public static func chassisLight(_ pwm: Int) -> CtrlCommand { CtrlCommand(RoverCode.chassisLight, mode: pwm) }
}

/// Codes from ugv_rpi's config.yaml.
public enum RoverCode {
    // Commands (`cmd`). Feedback keys double as the command that sets them.
    public static let detectType = 101       // fb.detect_type, mode = VisionMode
    public static let headLight = 102        // fb.led_mode, mode = led_off/led_aut/led_ton
    public static let detectReact = 103      // fb.detect_react, mode = DetectionReaction
    public static let movementLock = 114     // fb.cv_movtion_mode, mode = mc_lock/mc_unlo
    public static let chassisLight = 115     // fb.base_light, mode = PWM 0…255
    public static let zoom = 10104           // mode = 1, 2 or 4
    public static let capturePhoto = 10201
    public static let video = 10203          // mode = 1 start, 0 stop
    // Arguments (`mode`).
    public static let lockOn = 10501
    public static let lockOff = 10502
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
    /// The `mode` that selects it (config.yaml led_off / led_aut / led_ton). Telemetry
    /// key 102 reports the raw value (0 / 1 / 2).
    public var code: Int { [10404, 10405, 10406][rawValue] }
    public var title: String { ["Off", "Auto", "On"][rawValue] }
    public var symbol: String { ["lightbulb.slash", "lightbulb.min", "lightbulb.max.fill"][rawValue] }
}

public enum CameraZoom: Int, CaseIterable, Identifiable, Sendable {
    case x1 = 1, x2 = 2, x4 = 4
    public var id: Int { rawValue }
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
