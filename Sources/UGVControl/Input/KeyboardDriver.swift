import AppKit
import RoverKit

/// Single-key controls, active whenever no text field has focus:
/// WASD / arrows drive, ⇧+arrows move the camera, Space stops, and more (see KeyboardHelp).
@MainActor
final class KeyboardDriver {
    private var monitor: Any?
    private var held = Set<UInt16>()
    private weak var rover: RoverClient?
    private weak var follow: FollowController?

    // macOS virtual key codes (layout-independent).
    private enum Key {
        static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
        static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124
        static let space: UInt16 = 49
        static let c: UInt16 = 8, l: UInt16 = 37, b: UInt16 = 11, g: UInt16 = 5
        static let p: UInt16 = 35, r: UInt16 = 15, z: UInt16 = 6, f: UInt16 = 3
        static let one: UInt16 = 18, two: UInt16 = 19, three: UInt16 = 20
        static let arrows: Set<UInt16> = [up, down, left, right]
        static let drive: Set<UInt16> = [w, a, s, d, up, down, left, right]
    }

    func start(rover: RoverClient, follow: FollowController) {
        guard monitor == nil else { return }
        self.rover = rover
        self.follow = follow
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self else { return e }
            if NSApp.keyWindow?.firstResponder is NSText { return e }   // typing in a field
            if e.modifierFlags.contains(.command) { return e }          // menu shortcuts
            return self.handle(e) ? nil : e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.held.removeAll()
                self?.rover?.setDrive(forward: 0, turn: 0)
            }
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let rover else { return false }
        let k = e.keyCode
        let isDown = e.type == .keyDown
        let shift = e.modifierFlags.contains(.shift)

        if Key.arrows.contains(k) && shift && isDown {
            let step = 5.0
            switch k {
            case Key.up: rover.nudgeGimbal(dx: 0, dy: step)
            case Key.down: rover.nudgeGimbal(dx: 0, dy: -step)
            case Key.left: rover.nudgeGimbal(dx: -step, dy: 0)
            default: rover.nudgeGimbal(dx: step, dy: 0)
            }
            return true
        }

        if Key.drive.contains(k) {
            if isDown { held.insert(k) } else { held.remove(k) }
            let fwd = held.contains(Key.w) || held.contains(Key.up)
            let back = held.contains(Key.s) || held.contains(Key.down)
            let right = held.contains(Key.d) || held.contains(Key.right)
            let left = held.contains(Key.a) || held.contains(Key.left)
            rover.setDrive(forward: (fwd ? 1 : 0) - (back ? 1 : 0), turn: (right ? 1 : 0) - (left ? 1 : 0))
            return true
        }

        guard isDown else { return [Key.space, Key.c, Key.l, Key.b, Key.g, Key.p, Key.r, Key.z, Key.f, Key.one, Key.two, Key.three].contains(k) }
        if e.isARepeat && k != Key.space { return true }

        switch k {
        case Key.space: held.removeAll(); rover.emergencyStop()
        case Key.c: rover.lookAhead()
        case Key.l: rover.toggleHeadLight()
        case Key.b: rover.setChassisLight(!rover.chassisLightOn)
        case Key.g: rover.setSteady(!rover.steady)
        case Key.p: rover.capturePhoto()
        case Key.r: rover.toggleRecording()
        case Key.z: rover.cycleZoom()
        case Key.f: follow?.toggle()
        case Key.one: rover.setSpeedPreset(.slow)
        case Key.two: rover.setSpeedPreset(.middle)
        case Key.three: rover.setSpeedPreset(.fast)
        default: return false
        }
        return true
    }
}
