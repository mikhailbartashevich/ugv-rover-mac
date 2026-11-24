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
- One-button Wi‑Fi setup (see below)
- Game controller support (Xbox, PlayStation, MFi)
- Save the current frame to your Mac (⌘S), and download media from the rover
- Low-battery warning, connection status, auto-reconnect
- Full keyboard control and a Rover menu

## First-time setup — keep your internet

1. On the Mac, join the rover's Wi‑Fi **AccessPopup** (password `1234567890`).
2. Open the inspector (⌥⌘I) → **Network**. Enter your home Wi‑Fi name and password, then press **Move Rover to My Wi‑Fi**.
3. The app opens a terminal on the rover through its JupyterLab (`:8888`, no token on the stock image) and adds a NetworkManager profile. AccessPopup then switches the rover to your Wi‑Fi. Next the app puts the Mac back on your Wi‑Fi and finds the rover's new IP.

When no known network is in range, the rover falls back to the AccessPopup hotspot. If the rover's user needs a password for `sudo`, enter it under **Advanced**.

## Controls

| Keys | Action |
|---|---|
| W A S D / ← ↑ ↓ → | drive (hold) |
| Space, ⌘. | stop |
| ⇧ + arrows | aim camera |
| C / G | look ahead / camera stabilisation |
| 1 2 3 | Slow / Middle / Fast |
| P / R / Z | photo / record / zoom on the rover |
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

```bash
swift build
swift test                                        # unit tests
# against the mock rover (Tools/mock-rover/README.md):
UGV_TEST_ROVER=127.0.0.1:5055 UGV_TEST_ROVER_LOG=$PWD/Tools/mock-rover/data/commands.log swift test
# layout snapshots without touching the screen:
UGV_SNAPSHOT=/tmp/shot UGV_SNAPSHOT_TABS=hud,modes,media,network,console UGV_SNAPSHOT_QUIT=1 \
  UGVControl.app/Contents/MacOS/UGVControl
```
