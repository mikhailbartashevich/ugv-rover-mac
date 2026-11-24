# Mock rover

A stand-in for the rover's host program (`ugv_rpi/app.py`, branch
`refactor/debian12-2025.10.01-py3.11`) with the same HTTP routes, Socket.IO channels
(`/ctrl` takes `{"cmd":X,"mode":Y}`) and an H.264 RTSP camera like the rover's mediamtx
(`rtsp://127.0.0.1:<port + 3554>/cam`, e.g. :8609 for :5055; `--rtsp-port` overrides it). It reports fake telemetry, remembers modes, and logs every command
it receives to `data/commands.log`.

```bash
python3 -m venv .venv && .venv/bin/pip install -r Tools/mock-rover/requirements.txt
.venv/bin/python Tools/mock-rover/mock_rover.py 5055
```

Options: `--world cat.jpg` simulates a camera that turns and moves (needs Pillow), `--target-scale 0.15` makes that target look far away, `--charging` makes the battery voltage rise, and `--host` sets the listen address.

Add some JPEGs to `Tools/mock-rover/data/frames/` for a camera feed. The video is encoded with
`ffmpeg` (libx264, keyframe every second), so it needs `brew install ffmpeg`. In the app, set the rover
address to `127.0.0.1:5055`. To run the integration tests against the mock:

```bash
UGV_TEST_ROVER=127.0.0.1:5055 Tools/test.sh
```
