# Mock of waveshareteam/ugv_rpi app.py (Flask-SocketIO) for developing the Mac app
# without a rover. See Tools/mock-rover/README.md.
import os, sys, json, time, random, threading, datetime
from flask import Flask, Response, request, jsonify, send_from_directory
from flask_socketio import SocketIO
HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'data')
for d in ('pictures', 'videos', 'frames'): os.makedirs(os.path.join(HERE, d), exist_ok=True)
LOG = open(os.path.join(HERE, 'commands.log'), 'a', buffering=1)
def log(*a): LOG.write(time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a) + '\n')
# Camera frames: any JPEGs in data/frames/ (they cycle while the rover "drives").
FRAMES = [open(os.path.join(HERE, 'frames', f), 'rb').read() for f in sorted(os.listdir(os.path.join(HERE, 'frames'))) if f.lower().endswith('.jpg')]
app = Flask(__name__)
socketio = SocketIO(app, async_mode='threading')
st = dict(detect_type=10301, detect_react=10401, led_mode=0, base_light=0, lock=False, pan=0, tilt=0, frame=0)
CTRL = {10301,10302,10303,10304,10305,10306,10307,10308,10309}
def update():
    socketio.emit('update', {'104': 1.2, '105': 4.5, '106': random.randint(8, 35), '107': 48.0 + random.random()*4,
        '108': 31, '111': -52 + random.randint(-3, 3), '102': st['led_mode'], '101': st['detect_type'], '103': st['detect_react'],
        '109': st['pan'], '110': st['tilt'], '112': 1105 + random.randint(-5, 5), '113': 24.6, '114': st['lock'], '115': st['base_light']}, namespace='/ctrl')
@app.route('/')
def index(): return '<html><script src="socket.io.js"></script>UGV Rover</html>'
@app.route('/video_feed')
def video_feed():
    if not FRAMES: return 'Put JPEGs in Tools/mock-rover/data/frames/', 404
    def gen():
        while True:
            yield b'--frame\r\nContent-Type: image/jpeg\r\n\r\n' + FRAMES[st['frame'] % len(FRAMES)] + b'\r\n'
            time.sleep(1/20)
    return Response(gen(), mimetype='multipart/x-mixed-replace; boundary=frame')
@app.route('/send_command', methods=['POST'])
def send_command():
    log('HTTP', request.form['command']); return jsonify(status='success')
@app.route('/get_photo_names')
def photos(): return jsonify(sorted(os.listdir(os.path.join(HERE, 'pictures')), reverse=True))
@app.route('/get_video_names')
def videos(): return jsonify(sorted([f for f in os.listdir(os.path.join(HERE, 'videos')) if f.endswith('.mp4')], reverse=True))
@app.route('/pictures/<path:f>')
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
    if data.get('T') == 133: st['pan'], st['tilt'] = data.get('X', 0), data.get('Y', 0)
    if data.get('T') == 1 and (data.get('L') or data.get('R')): st['frame'] += 1
@socketio.on('message', namespace='/ctrl')
def on_msg(message):
    d = json.loads(message); a = int(d.get('A', 0)); log('CTRL', a)
    if a in CTRL: st['detect_type'] = a
    elif a in (10401, 10402, 10403): st['detect_react'] = a
    elif a in (10404, 10405, 10406): st['led_mode'] = a - 10404
    elif a == 10407: st['base_light'] = 0
    elif a == 10408: st['base_light'] = 255
    elif a == 10501: st['lock'] = True
    elif a == 10502: st['lock'] = False
    elif a == 10201:
        if FRAMES:
            with open(os.path.join(HERE, 'pictures', datetime.datetime.now().strftime('%Y-%m-%d_%H-%M-%S') + '.jpg'), 'wb') as f:
                f.write(FRAMES[st['frame'] % len(FRAMES)])
    update()
def loop():
    while True: update(); time.sleep(2)
threading.Thread(target=loop, daemon=True).start()
socketio.run(app, host='127.0.0.1', port=int(sys.argv[1]) if len(sys.argv) > 1 else 5055, allow_unsafe_werkzeug=True)
