# Mock of waveshareteam/ugv_rpi app.py (branch refactor/debian12-2025.10.01-py3.11,
# Flask-SocketIO + mediamtx) for developing the Mac app without a rover.
# See Tools/mock-rover/README.md.
import os, sys, json, time, random, threading, datetime, argparse
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from flask import Flask, Response, request, jsonify, send_from_directory
from flask_socketio import SocketIO
HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
for d in ('pictures', 'videos', 'frames'): os.makedirs(os.path.join(HERE, d), exist_ok=True)
LOG = open(os.path.join(HERE, 'commands.log'), 'a', buffering=1)
def log(*a): LOG.write(time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a) + '\n')
# Camera frames: any JPEGs in data/frames/ (they cycle while the rover "drives").
FRAMES = [open(os.path.join(HERE, 'frames', f), 'rb').read() for f in sorted(os.listdir(os.path.join(HERE, 'frames'))) if f.lower().endswith('.jpg')]
ap = argparse.ArgumentParser()
ap.add_argument('port', nargs='?', type=int, default=5055)
ap.add_argument('--host', default='127.0.0.1', help='address to listen on')
ap.add_argument('--target-scale', type=float, default=1.0, help='with --world: shrink the target so it looks far away (e.g. 0.15)')
ap.add_argument('--charging', action='store_true', help='battery voltage rises over time, as on the charger')
ap.add_argument('--world', help='photo of a cat/dog/person: simulate a camera that turns and moves (needs Pillow)')
ap.add_argument('--rtsp-port', type=int, help='RTSP video port (default: port + 3554, so 5000 -> 8554 like the rover)')
args = ap.parse_args()
SIM = None
if args.world:
    from sim import Sim
    SIM = Sim(args.world, target_scale=args.target_scale)
STARTED = time.time()
app = Flask(__name__)
socketio = SocketIO(app, async_mode='threading')
st = dict(detect_type=10301.0, detect_react=10401.0, led_mode=0, base_light=0, lock=True, pan=0, tilt=0, frame=0, zoom=1, recording=False)
def update():
    # Like the rover: 101/103 echo the float `mode` they were set with; 102 is 0/1/2 (off/auto/on).
    socketio.emit('update', {'104': 1.2, '105': 4.5, '106': random.randint(8, 35), '107': 48.0 + random.random()*4,
        '108': 31, '111': -52 + random.randint(-3, 3), '102': st['led_mode'], '101': st['detect_type'], '103': st['detect_react'],
        '109': st['pan'], '110': st['tilt'], '112': (int(1050 + (time.time() - STARTED) * 0.08) if args.charging else 1105) + random.randint(-2, 2), '113': 24.6, '114': st['lock'], '115': st['base_light']}, namespace='/ctrl')
@app.route('/')
def index(): return '<html><script src="socket.io.js"></script>UGV Rover</html>'
@app.route('/config')
def config(): return 'video:\n  default_res_h: 480\n  default_res_w: 640\n'
# Camera: H.264 over RTSP like the rover's mediamtx (rtsp://host:<port+3554>/cam).
from rtsp import H264Source, RTSPServer
def camera_frame():
    if SIM: return SIM.frame()
    return FRAMES[st['frame'] % len(FRAMES)] if FRAMES else None
if SIM or FRAMES:
    RTSPServer(H264Source(camera_frame, 15 if SIM else 20), args.host, args.rtsp_port or args.port + 3554, log=log)
else:
    print('mock rover: put JPEGs in Tools/mock-rover/data/frames/ for a camera feed')
@app.route('/sim')
def sim_state(): return jsonify(SIM.state() if SIM else {})
@app.route('/sim/reset', methods=['POST'])
def sim_reset():
    if SIM: SIM.reset()
    return jsonify(SIM.state() if SIM else {})
@app.route('/send_command', methods=['POST'])
def send_command():
    log('HTTP', request.form['command']); return jsonify(status='success')
@app.route('/get_photo_names')
def photos(): return jsonify(sorted(os.listdir(os.path.join(HERE, 'pictures')), reverse=True))
@app.route('/get_video_names')
def videos(): return jsonify(sorted([f for f in os.listdir(os.path.join(HERE, 'videos')) if f.endswith('.mp4')], reverse=True))
@app.route('/media/pictures/<path:f>')
def picture(f): return send_from_directory(os.path.join(HERE, 'pictures'), f)
@app.route('/videos/<path:f>')
def video(f): return send_from_directory(os.path.join(HERE, 'videos'), f)
@app.route('/delete_photo', methods=['POST'])
def del_photo():
    log('DELETE photo', request.form.get('filename')); os.remove(os.path.join(HERE, 'pictures', request.form.get('filename'))); return jsonify(success=True)
@app.route('/delete_video', methods=['POST'])
def del_video():
    log('DELETE video', request.form.get('filename')); os.remove(os.path.join(HERE, 'videos', request.form.get('filename'))); return jsonify(success=True)
@socketio.on('json', namespace='/json')
def on_json(data):
    log('JSON', json.dumps(data, separators=(',', ':')))
    if SIM and data.get('T') == 13: SIM.command(data.get('X', 0), data.get('Z', 0))
    if SIM and data.get('T') == 1: SIM.command((data.get('L', 0) + data.get('R', 0)) / 2, (data.get('R', 0) - data.get('L', 0)) / 0.2)
    if data.get('T') == 133: st['pan'], st['tilt'] = data.get('X', 0), data.get('Y', 0)
    if data.get('T') == 1 and (data.get('L') or data.get('R')): st['frame'] += 1
# Same dispatch as the rover's handle_socket_cmd: {"cmd": X, "mode": Y}, both read as floats.
@socketio.on('message', namespace='/ctrl')
def on_msg(message):
    d = json.loads(message); cmd = float(d.get('cmd', 0)); mode = float(d.get('mode', 0))
    log('CTRL', json.dumps(d, separators=(',', ':')))
    if cmd == 101: st['detect_type'] = mode
    elif cmd == 103: st['detect_react'] = mode
    elif cmd == 102:
        m = {10404: 0, 10405: 1, 10406: 2}.get(int(mode))
        if m is not None: st['led_mode'] = m
        elif int(mode) == 10409 and st['led_mode'] != 1: st['led_mode'] = 0 if st['led_mode'] else 2
    elif cmd == 115: st['base_light'] = int(mode)
    elif cmd == 10410: st['base_light'] = 0 if st['base_light'] else 255
    elif cmd == 114: st['lock'] = int(mode) != 10502
    elif cmd == 10104: st['zoom'] = max(1, int(mode))
    elif cmd == 10203: st['recording'] = mode == 1
    elif cmd == 10201:
        jpeg = camera_frame()
        if jpeg:
            with open(os.path.join(HERE, 'pictures', 'photo_' + datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S') + '.jpg'), 'wb') as f:
                f.write(jpeg)
    if cmd in (101, 102, 103, 114, 115, 10410): update()
def loop():
    while True: update(); time.sleep(2)
threading.Thread(target=loop, daemon=True).start()
socketio.run(app, host=args.host, port=args.port, allow_unsafe_werkzeug=True)
