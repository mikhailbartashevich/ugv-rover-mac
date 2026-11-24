import Foundation
import Observation

public struct CameraResolution: Hashable, Identifiable, Sendable {
    public let width: Int
    public let height: Int
    public var id: String { "\(width)x\(height)" }
    public var title: String { "\(width) × \(height)" }

    /// 4:3 sizes keep the camera's full field of view.
    public static let options = [
        CameraResolution(width: 640, height: 480),
        CameraResolution(width: 1024, height: 768),
        CameraResolution(width: 1280, height: 960),
    ]
    /// The rover's default (ugv_rpi config.yaml).
    public static let standard = options[2]
}

/// Changes the camera resolution in the rover's config.yaml (`video.default_res_w/h`)
/// through its JupyterLab terminal, then restarts the rover's program (and the mediamtx
/// and ffmpeg it runs for the H.264 stream) so it takes effect. The original config is
/// kept as config.yaml.bak-ugvcontrol.
@MainActor
@Observable
public final class CameraSetup {
    public private(set) var isRunning = false
    public private(set) var status: String?
    public private(set) var error: String?
    /// The resolution in the rover's config (read from its `/config`), or what this app last applied.
    public private(set) var applied: CameraResolution

    public init() {
        let saved = UserDefaults.standard.string(forKey: "cameraResolution")
        applied = CameraResolution.options.first { $0.id == saved } ?? .standard
    }

    /// Reads the configured resolution from the rover (`GET /config` returns its config.yaml).
    public func refresh(rover: RoverClient) async {
        guard !isRunning, let url = rover.baseURL?.appendingPathComponent("config") else { return }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let res = Self.resolution(inConfig: String(decoding: data, as: UTF8.self)) else { return }
        setApplied(res)
    }

    nonisolated static func resolution(inConfig yaml: String) -> CameraResolution? {
        func value(_ key: String) -> Int? {
            for line in yaml.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(key + ":") { return Int(t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)) }
            }
            return nil
        }
        guard let w = value("default_res_w"), let h = value("default_res_h") else { return nil }
        return CameraResolution(width: w, height: h)
    }

    private func setApplied(_ res: CameraResolution) {
        applied = res
        UserDefaults.standard.set(res.id, forKey: "cameraResolution")
    }

    public func apply(_ res: CameraResolution, rover: RoverClient) async {
        isRunning = true
        error = nil
        defer { isRunning = false }
        do {
            status = "Connecting to the rover's JupyterLab…"
            guard let base = URL(string: "http://\(rover.hostIP):8888") else { throw ProvisionError("Bad rover address.") }
            let term = JupyterTerminal(base: base)
            do { try await term.open() } catch {
                throw ProvisionError("Can't reach JupyterLab on the rover (port 8888): \(error.localizedDescription)")
            }
            status = "Updating config.yaml and restarting the rover's program…"
            let out = try await term.runScript(Self.script(res), timeout: 40)
            await term.close()
            if let reason = ProvisionScript.value(after: ProvisionScript.failMarker, in: out) {
                throw ProvisionError("The rover couldn't change the resolution: \(reason)")
            }
            setApplied(res)

            status = "Waiting for the rover to come back…"
            let deadline = Date().addingTimeInterval(90)
            try await Task.sleep(for: .seconds(4))
            while Date() < deadline {
                await rover.connect()
                if rover.reachable == true { break }
                try await Task.sleep(for: .seconds(2))
            }
            guard rover.reachable == true else {
                throw ProvisionError("The rover's program hasn't come back yet. Give it a minute, or restart the rover.")
            }
            status = "Camera now at \(res.title)."
            rover.show("Camera resolution set to \(res.title)", symbol: "camera.aperture")
        } catch {
            self.error = error.localizedDescription
            status = nil
        }
    }

    /// Finds the running app.py, edits its config.yaml and restarts it the way the
    /// rover's crontab starts it (same Python, same script, output to ~/ugv.log).
    /// app.py runs mediamtx (RTSP/WebRTC server) and ffmpeg (H.264 encoder) as children;
    /// they're stopped too, so the new program can take the camera and the ports.
    nonisolated static func script(_ r: CameraResolution) -> String {
        """
        fail() { echo "\(ProvisionScript.failMarker) $1"; rm -f "$0"; exit 1; }
        # The crontab starts app.py through `sh -c`; we want the Python process itself.
        P=""
        for p in $(pgrep -f 'app\\.py'); do
          case "$(readlink /proc/$p/exe)" in *python*) P=$p; break ;; esac
        done
        [ -n "$P" ] || fail "the rover's program (app.py) isn't running"
        expand() { case "$1" in "~/"*) echo "$HOME/${1#??}" ;; /*) echo "$1" ;; *) echo "$(readlink -f /proc/$P/cwd)/$1" ;; esac; }
        PY=$(expand "$(tr '\\0' '\\n' < /proc/$P/cmdline | sed -n 1p)")
        APP=$(expand "$(tr '\\0' '\\n' < /proc/$P/cmdline | grep 'app\\.py$' | head -1)")
        DIR=$(dirname "$APP")
        CFG="$DIR/config.yaml"
        [ -f "$CFG" ] || fail "config.yaml not found next to $APP"
        [ -f "$CFG.bak-ugvcontrol" ] || cp "$CFG" "$CFG.bak-ugvcontrol"
        sed -i -E 's/^([[:space:]]*default_res_w:).*/\\1 \(r.width)/; s/^([[:space:]]*default_res_h:).*/\\1 \(r.height)/' "$CFG"
        grep -q "default_res_w: \(r.width)" "$CFG" && grep -q "default_res_h: \(r.height)" "$CFG" || fail "couldn't edit $CFG"
        echo "\(ProvisionScript.infoMarker) $CFG"
        # Children (mediamtx, ffmpeg) are reparented once app.py exits, so note them first.
        KIDS=$(pgrep -P "$P" | tr '\\n' ' ')
        kill "$P" $KIDS 2>/dev/null
        for i in 1 2 3 4 5 6; do
          ALIVE=""; for k in $P $KIDS; do kill -0 "$k" 2>/dev/null && ALIVE="$ALIVE $k"; done
          [ -z "$ALIVE" ] && break; sleep 0.5
        done
        [ -n "$ALIVE" ] && kill -9 $ALIVE 2>/dev/null
        pkill -9 -f "$DIR/controllers/Mediamtx/mediamtx" 2>/dev/null
        sleep 1
        export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
        cd "$HOME" && setsid nohup "$PY" "$APP" >> "$HOME/ugv.log" 2>&1 < /dev/null &
        rm -f "$0"
        echo "\(ProvisionScript.okMarker)"
        """
    }
}
