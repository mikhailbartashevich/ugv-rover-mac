import GameController
import RoverKit

/// Xbox / PlayStation / MFi controllers: left stick drives, right stick aims the
/// camera, face buttons trigger actions. Only active while the app is frontmost.
@MainActor
final class GamepadDriver {
    private weak var rover: RoverClient?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private let deadZone: Float = 0.15

    func start(rover: RoverClient) {
        guard self.rover == nil else { return }
        self.rover = rover
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                if let c = n.object as? GCController { self?.attach(c) }
            }
        })
        observers.append(nc.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.rover?.analogDrive(linear: 0, angular: 0)
                self?.rover?.show("Controller disconnected", symbol: "gamecontroller")
            }
        })
        GCController.controllers().forEach(attach)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        rover?.show("\(controller.vendorName ?? "Controller") connected", symbol: "gamecontroller.fill")
        onPress(pad.buttonA) { $0.capturePhoto() }
        onPress(pad.buttonB) { $0.emergencyStop() }
        onPress(pad.buttonX) { $0.toggleHeadLight() }
        onPress(pad.buttonY) { $0.lookAhead() }
        onPress(pad.rightShoulder) { $0.toggleRecording() }
        onPress(pad.leftShoulder) { $0.cycleZoom() }
        onPress(pad.dpad.up) { r in
            let all = SpeedPreset.allCases
            let i = all.firstIndex(of: r.speedPreset ?? .middle) ?? 1
            r.setSpeedPreset(all[min(i + 1, all.count - 1)])
        }
        onPress(pad.dpad.down) { r in
            let all = SpeedPreset.allCases
            let i = all.firstIndex(of: r.speedPreset ?? .middle) ?? 1
            r.setSpeedPreset(all[max(i - 1, 0)])
        }
    }

    private func onPress(_ button: GCControllerButtonInput, _ action: @escaping (RoverClient) -> Void) {
        button.pressedChangedHandler = { [weak self] _, _, pressed in
            guard pressed else { return }
            MainActor.assumeIsolated {
                if let rover = self?.rover { action(rover) }
            }
        }
    }

    private func poll() {
        guard let rover, let pad = GCController.current?.extendedGamepad else { return }
        let ly = filtered(pad.leftThumbstick.yAxis.value)
        let lx = filtered(pad.leftThumbstick.xAxis.value)
        rover.analogDrive(linear: Double(ly), angular: Double(-lx))

        let rx = filtered(pad.rightThumbstick.xAxis.value)
        let ry = filtered(pad.rightThumbstick.yAxis.value)
        if rx != 0 || ry != 0 {
            rover.nudgeGimbal(dx: Double(rx) * 6, dy: Double(ry) * 4)
        }
    }

    private func filtered(_ v: Float) -> Float { abs(v) < deadZone ? 0 : v }
}
