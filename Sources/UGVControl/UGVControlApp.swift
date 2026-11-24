import SwiftUI
import AppKit

@main
struct UGVControlApp: App {
    // App is created once, so plain lets are fine (SwiftUI's @State macro
    // isn't available with Command Line Tools only).
    private let rover = RoverClient()
    private let net = NetworkStatus()
    private let video = MJPEGStream()
    private let provisioner = RoverProvisioner()

    init() {
        // Running as a plain SwiftPM binary needs this to get a Dock icon / key window.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("UGV Control") {
            ContentView()
                .environment(rover)
                .environment(net)
                .environment(video)
                .environment(provisioner)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 760)
    }
}

/// Tracks held keys app-wide: WASD / arrows drive, Shift+arrows move the camera.
@MainActor
final class KeyboardDriver {
    private var monitor: Any?
    private var held = Set<UInt16>()
    weak var rover: RoverClient?

    // macOS virtual key codes
    private let W: UInt16 = 13, A: UInt16 = 0, S: UInt16 = 1, D: UInt16 = 2
    private let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124
    private let space: UInt16 = 49, L: UInt16 = 37, C: UInt16 = 8

    func start(rover: RoverClient) {
        self.rover = rover
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] e in
            guard let self else { return e }
            // Don't hijack typing in text fields.
            if NSApp.keyWindow?.firstResponder is NSText { return e }
            if e.modifierFlags.contains(.command) { return e }
            return self.handle(e) ? nil : e
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.held.removeAll()
                self?.rover?.setDrive(forward: 0, turn: 0)
            }
        }
    }

    private func handle(_ e: NSEvent) -> Bool {
        guard let rover else { return false }
        let k = e.keyCode
        let down = e.type == .keyDown
        let isArrow = [up, self.down, left, right].contains(k)
        let shift = e.modifierFlags.contains(.shift)
        switch k {
        case W, A, S, D, up, self.down, left, right where !(isArrow && shift && down):
            // WASD and plain arrow keys drive; Shift+arrows move the camera.
            if down { held.insert(k) } else { held.remove(k) }
            let fwd = held.contains(W) || held.contains(up)
            let back = held.contains(S) || held.contains(self.down)
            let r = held.contains(D) || held.contains(right)
            let l = held.contains(A) || held.contains(left)
            rover.setDrive(forward: (fwd ? 1 : 0) - (back ? 1 : 0), turn: (r ? 1 : 0) - (l ? 1 : 0))
            return true
        case space:
            if down { held.removeAll(); rover.emergencyStop() }
            return true
        case up, self.down, left, right:
            if down {
                let step = 5.0
                switch k {
                case up: rover.nudgeGimbal(dx: 0, dy: step)
                case self.down: rover.nudgeGimbal(dx: 0, dy: -step)
                case left: rover.nudgeGimbal(dx: -step, dy: 0)
                default: rover.nudgeGimbal(dx: step, dy: 0)
                }
            }
            return true
        case L:
            if down && !e.isARepeat { rover.toggleLights() }
            return true
        case C:
            if down && !e.isARepeat { rover.centerGimbal() }
            return true
        default:
            return false
        }
    }
}
