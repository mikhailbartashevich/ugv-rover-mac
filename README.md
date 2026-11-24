# UGV Control (macOS)

Native macOS 26+ app for the Waveshare UGV Rover (Raspberry Pi host + ESP32).

## Build

```bash
./build-app.sh        # needs only Command Line Tools; produces UGVControl.app
open UGVControl.app
```

## First-time setup — keep your internet

1. On the Mac, join the rover's Wi‑Fi **AccessPopup** (password `1234567890`).
2. In the app, open **Network** (globe icon in the toolbar), enter your home Wi‑Fi name and password, and press **Move Rover to My Wi‑Fi**.
3. The app opens a terminal on the rover via its JupyterLab (`:8888`, no token on the stock image), adds a NetworkManager profile `ugv-home`, then has AccessPopup switch the rover to your Wi‑Fi. Next it puts the Mac back on your Wi‑Fi and finds the rover's new IP (`<hostname>.local`, or by scanning port 5000).

The rover joins that network on every boot. When no known network is in range, it falls back to the AccessPopup hotspot.
If the rover's user needs a password for `sudo`, enter it under **Advanced**.

## Controls

| Keys | Action |
|---|---|
| W A S D / ← ↑ ↓ → | drive (hold) |
| Space | stop |
| ⇧ + arrows | camera pan/tilt |
| C | center camera |
| L | lights |

## How it talks to the rover

- Commands: `POST http://<rover>:5000/send_command` with form `command=base -c {"T":1,"L":0.3,"R":0.3}`. Drive commands are re-sent every 150 ms while a key is held; the ESP32 stops on its own when they stop coming.
- Video: MJPEG at `http://<rover>:5000/video_feed`.
- Wi‑Fi setup: JupyterLab terminal websocket at `:8888`.
