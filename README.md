# UGV Control (macOS)

Native macOS 26+ app for the [Waveshare UGV Rover](https://www.waveshare.com/wiki/UGV-Rover)
(Raspberry Pi host + ESP32). It covers the rover's stock web UI and adds a few things
of its own. It can also move the rover onto your home Wi‑Fi, so your Mac keeps its internet.

## Build & install

```bash
./build-app.sh                 # Command Line Tools are enough; produces UGVControl.app
cp -R UGVControl.app /Applications/
```

`Tools/make-icon.sh` re-renders the icon (`Tools/make-icon.swift`) into `Resources/AppIcon.icns`.

## Features

From the stock web UI:
- Live video with the centre reticle
- Telemetry: battery voltage and %, CPU, RAM, temperature, Wi‑Fi signal, FPS, storage used
- Driving with Slow / Middle / Fast presets; camera pan-tilt with Steady and Look Ahead
- Photo, video recording and zoom (1× / 2× / 4×) on the rover
- Vision modes: Motion, Faces, Objects, Color, Hand Gestures, Auto Drive, MediaPipe Face Mesh and Body Pose
- Detection reactions (photo / record), movement lock, head light Off / Auto / On, chassis lights, stream quality
- Photo and video gallery, plus a command console

New in this app:
- **Follow** a cat, dog or person on its own (see below)
- One-button Wi‑Fi setup (see below)
- Game controller support (Xbox, PlayStation, MFi)
- Save the current frame to your Mac (⌘S), and download media from the rover
- Low-battery warning, charging indicator, connection status, auto-reconnect, and **auto-discovery**: if the saved address doesn't answer, the app tries the rover's `.local` name, its hotspot (192.168.50.5) and every address on the Mac's networks
- Full keyboard control and a Rover menu

## First-time setup — keep your internet

1. On the Mac, join the rover's Wi‑Fi **AccessPopup** (password `1234567890`).
2. Open the inspector (⌥⌘I) → **Network**. Enter your home Wi‑Fi name and password, then press **Move Rover to My Wi‑Fi**.
3. The app opens a terminal on the rover through its JupyterLab (`:8888`, no token on the stock image) and adds a NetworkManager profile. AccessPopup then switches the rover to your Wi‑Fi. Next the app puts the Mac back on your Wi‑Fi and finds the rover's new IP.

When no known network is in range, the rover falls back to the AccessPopup hotspot. If the rover's user needs a password for `sudo`, enter it under **Advanced**.

## Move the rover to another Wi‑Fi

While the rover is on a normal network, Network → **Move Rover to Another Wi‑Fi** lists the networks the rover can see, and which of them it has saved. Pick one or type a name, enter its password, then press **Move Rover**. With **Move this Mac to it too** switched on, the Mac joins the same network afterwards and finds the rover there. With it off, the app waits to see whether the rover comes back and tells you how to reach it.

How it works on the rover (NetworkManager, through the JupyterLab terminal):
- Saved Wi‑Fi profiles are never deleted. The target network gets a profile (`ugv-<SSID>`), or its existing profile is updated. Its autoconnect priority is set above every other client profile, so the rover prefers it on boot. All the other profiles stay as fallbacks.
- The switch runs detached on the rover (`nmcli connection up`). If joining fails, the rover removes the profile it just created (or puts back the old priority and password) and returns to the previous network. If that also fails, AccessPopup opens the hotspot. The outcome is written to `/tmp/ugv_wifi_result`, and the app reads it to explain a failure, for example a wrong password.

## Follow the cat

Press **F**, the paw button, or *Follow* in the inspector. The rover keeps the target centred and creeps closer at up to 0.12 m/s. It stops once the target fills the chosen share of the frame, and it never reverses.
- **Lost target:** it turns slowly towards where it last saw the target for up to 12 s, then waits.
- **Stopping:** any manual drive key, Space or STOP ends Follow.

- **Detection** runs on the Mac with Apple's Vision framework, about 8 times a second. Each frame is searched in steps: a zoomed-in region around where the target was last seen, then the whole frame, then overlapping tiles (3 × 2, then 5 × 4). The tiles act as a digital zoom for far-away targets. On the rover's small, blurry frames the animal detector often misses, so the app falls back to the scene classifier ("there's a cat") combined with salient-object boxes.
- **Claude** (optional) looks at one frame every few seconds. It reports obstacles in the path, which block forward driving for 4 s, and where the target went, including a bounding box when the Mac's detector misses it. By default it runs through the **Claude Code installed on this Mac** (`claude -p` with the image over `--input-format stream-json`, `--json-schema`, tools off), using the account Claude Code is signed in with, so no API key is needed. Alternatively it can call the Messages API with an API key stored in the Keychain. Model: `claude-opus-5-5`, low effort.

### Range

On-device recognition needs the target to be roughly 50 px tall in the video, and image quality matters as much as size:

- **Video quality**: the rover streams at JPEG quality 20 by default, which smears distant detail into blocks. The app sets 70 on every connect (Modes › Camera › Video quality).
- **Camera resolution**: Modes › Camera › Camera resolution › Apply changes `default_res_w/h` in the rover's `config.yaml` through JupyterLab and restarts its program. The original is kept as `config.yaml.bak-ugvcontrol`. At 1280 × 960 a cat stays recognisable about twice as far away as at 640 × 480, at the cost of more Raspberry Pi CPU.
- **Claude as a spotter**: when the Mac sees nothing, Claude gets the full-size frame and finds targets far smaller than Vision can. Vision's object tracker then holds on to the target. The tracker can follow on its own for up to 10 s; after that the detector or Claude must confirm the target again.

In the simulator, a cat 10 % of the frame tall is found on-device. One about 6 % tall is found only with Claude's help.

## Battery

The rover reports only its battery voltage, so the app infers charging. If the voltage rises steadily (more than 0.006 V/min over a few minutes) while the wheels are still, the card shows **⚡ Charging**. Driving resets the estimate.

## Controls

| Keys | Action |
|---|---|
| W A S D / ← ↑ ↓ → | drive (hold) |
| Space, ⌘. | stop |
| ⇧ + arrows | aim camera |
| C / G | look ahead / camera stabilisation |
| 1 2 3 | Slow / Middle / Fast |
| P / R / Z | photo / record / zoom on the rover |
| F | follow the cat on / off |
| L / B | head / chassis lights |
| ⌘S | save frame to Mac |

Game controller: left stick drives, right stick aims the camera. A = photo, B = stop, X = light, Y = look ahead, RB = record, LB = zoom, D-pad ↑↓ = speed.

## Code layout

```
Sources/
  RoverKit/                    rover protocol & networking, no UI
    Protocol/                  action codes, ESP32 JSON commands
    Connection/                RoverClient, Socket.IO client, telemetry
    Video/                     MJPEG stream reader
    Media/                     photos & videos on the rover
    Network/                   Mac network status, rover scanner
    Provisioning/              Wi‑Fi setup through JupyterLab
    Autonomy/                  target detection, follow planner/controller, Claude vision
  UGVControl/                  SwiftUI app
    App/  Input/  Services/
    Views/{Toolbar,HUD,Inspector,Components}
Tests/RoverKitTests/           unit tests + live tests against a rover or the mock
Tools/                         icon renderer, mock rover
```

## How it talks to the rover

- **Socket.IO** (`:5000`, Engine.IO v4)
  - `/json` carries ESP32 commands such as `{"T":1,"L":0.3,"R":0.3}`. Drive commands repeat every 200 ms while held, because the ESP32 stops on its own when they stop coming.
  - `/ctrl` carries mode codes as `{"A":10303,"B":0,"C":0}`. Telemetry comes back as `update` events.
- **HTTP**
  - `POST /send_command` (`base -c {…}`) is the fallback for driving and powers the console.
  - `/video_feed` is the MJPEG camera stream.
  - `/get_photo_names`, `/pictures/…`, `/get_video_names`, `/videos/…`, `/delete_photo` and `/delete_video` serve the media gallery.
- **JupyterLab** (`:8888`): its terminal websocket is used for the Wi‑Fi setup.

## Development

Set `UGV_ROVER_HOST=127.0.0.1:5055` to point the app at a mock rover without touching the saved address.

```bash
swift build
Tools/test.sh                                     # unit tests (works around a SwiftPM cache bug)
# against the mock rover (Tools/mock-rover/README.md):
UGV_TEST_ROVER=127.0.0.1:5055 UGV_TEST_ROVER_LOG=$PWD/Tools/mock-rover/data/commands.log Tools/test.sh
# closed-loop Follow test: the mock simulates a camera that turns and moves
python Tools/mock-rover/mock_rover.py 5056 --world cat.jpg   # needs Pillow
UGV_TEST_SIM=127.0.0.1:5056 Tools/test.sh --filter Follow
# discovery: mock on this Mac's LAN address; live Claude Code call on a cat photo
UGV_TEST_DISCOVERY=192.168.0.10:5057 UGV_TEST_CLAUDE_CODE=cat.jpg Tools/test.sh
# layout snapshots without touching the screen:
UGV_SNAPSHOT=/tmp/shot UGV_SNAPSHOT_TABS=hud,modes,media,network,console UGV_SNAPSHOT_QUIT=1 \
  UGVControl.app/Contents/MacOS/UGVControl
```
