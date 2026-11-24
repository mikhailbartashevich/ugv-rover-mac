# Mock rover

A stand-in for the rover's host program (`ugv_rpi/app.py`) with the same HTTP routes and
Socket.IO channels. It reports fake telemetry, remembers modes, and logs every command
it receives to `data/commands.log`.

```bash
python3 -m venv .venv && .venv/bin/pip install -r Tools/mock-rover/requirements.txt
.venv/bin/python Tools/mock-rover/mock_rover.py 5055
```

Add some JPEGs to `Tools/mock-rover/data/frames/` for a camera feed. In the app, set the rover
address to `127.0.0.1:5055`. To run the integration tests against the mock:

```bash
UGV_TEST_ROVER=127.0.0.1:5055 swift test
```
