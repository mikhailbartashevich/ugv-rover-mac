# The mock rover's camera, served like the real rover's mediamtx: H.264 over RTSP with RTP
# interleaved on the TCP connection (rtsp://<host>:<port>/cam). JPEG frames from the mock
# are encoded by ffmpeg (libx264, keyframe every second) and sent to every playing client.
import base64, socket, struct, subprocess, sys, threading, time


class H264Source:
    """Feeds JPEGs to ffmpeg and splits its Annex-B output into access units."""

    def __init__(self, next_jpeg, fps):
        self.next_jpeg, self.fps = next_jpeg, fps
        self.sps = self.pps = None
        self.listeners = []
        self.lock = threading.Lock()
        cmd = ['ffmpeg', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', str(fps), '-c:v', 'mjpeg', '-i', '-',
               '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-pix_fmt', 'yuv420p', '-c:v', 'libx264',
               '-preset', 'ultrafast', '-tune', 'zerolatency', '-g', str(fps),
               '-x264-params', 'aud=1:sliced-threads=0:repeat-headers=1', '-f', 'h264', '-']
        try:
            self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        except FileNotFoundError:
            print('mock rover: ffmpeg not found (brew install ffmpeg) - no video', file=sys.stderr)
            self.proc = None
            return
        threading.Thread(target=self._feed, daemon=True).start()
        threading.Thread(target=self._read, daemon=True).start()

    def _feed(self):
        while True:
            try:
                self.proc.stdin.write(self.next_jpeg()); self.proc.stdin.flush()
            except (BrokenPipeError, OSError):
                return
            time.sleep(1 / self.fps)

    def _read(self):
        buf, unit = b'', []
        while True:
            chunk = self.proc.stdout.read1(65536) if hasattr(self.proc.stdout, 'read1') else self.proc.stdout.read(4096)
            if not chunk: return
            buf += chunk
            parts = buf.split(b'\x00\x00\x01')
            buf = b'\x00\x00\x01' + parts.pop()        # the last NAL may be incomplete
            for nal in parts:
                nal = nal.rstrip(b'\x00')
                if not nal: continue
                t = nal[0] & 0x1F
                if t == 9:                             # access unit delimiter: a new frame starts
                    if unit: self._emit(unit)
                    unit = []
                    continue
                if t == 7: self.sps = nal
                if t == 8: self.pps = nal
                unit.append(nal)

    def _emit(self, unit):
        with self.lock:
            for f in list(self.listeners): f(unit)

    def subscribe(self, f):
        with self.lock: self.listeners.append(f)

    def unsubscribe(self, f):
        with self.lock:
            if f in self.listeners: self.listeners.remove(f)


class RTSPServer:
    def __init__(self, source, host, port, log=print):
        self.source, self.log = source, log
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind((host, port)); self.sock.listen(8)
        threading.Thread(target=self._accept, daemon=True).start()

    def _accept(self):
        while True:
            conn, _ = self.sock.accept()
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            threading.Thread(target=self._client, args=(conn,), daemon=True).start()

    def _client(self, conn):
        wlock = threading.Lock()
        state = dict(seq=0, keyframe=False)
        start = time.time()

        def send_unit(unit):
            if not state['keyframe']:
                if not any(n[0] & 0x1F == 5 for n in unit): return
                state['keyframe'] = True
            ts = int((time.time() - start) * 90000) & 0xFFFFFFFF
            packets = []
            for i, nal in enumerate(unit):
                last = i == len(unit) - 1
                if len(nal) <= 1400:
                    packets.append((nal, last))
                else:                                   # FU-A fragments
                    head, body = nal[0], nal[1:]
                    chunks = [body[j:j + 1400] for j in range(0, len(body), 1400)]
                    for k, c in enumerate(chunks):
                        fu = (0x80 if k == 0 else 0) | (0x40 if k == len(chunks) - 1 else 0) | (head & 0x1F)
                        packets.append((bytes([(head & 0xE0) | 28, fu]) + c, last and k == len(chunks) - 1))
            try:
                with wlock:
                    for payload, marker in packets:
                        state['seq'] = (state['seq'] + 1) & 0xFFFF
                        rtp = struct.pack('!BBHII', 0x80, (0x80 if marker else 0) | 96, state['seq'], ts, 0x12345678) + payload
                        conn.sendall(b'$\x00' + struct.pack('!H', len(rtp)) + rtp)
            except OSError:
                self.source.unsubscribe(send_unit)

        buf = b''
        try:
            while True:
                while b'\r\n\r\n' not in buf:
                    d = conn.recv(4096)
                    if not d: raise OSError
                    buf += d
                head, buf = buf.split(b'\r\n\r\n', 1)
                lines = head.decode(errors='replace').split('\r\n')
                method, url = lines[0].split(' ')[:2]
                hdr = {l.split(':', 1)[0].strip().lower(): l.split(':', 1)[1].strip() for l in lines[1:] if ':' in l}
                n = int(hdr.get('content-length', 0))
                while len(buf) < n: buf += conn.recv(4096)
                buf = buf[n:]
                self.log('RTSP', method)
                extra, body = [], b''
                if method == 'OPTIONS':
                    extra = ['Public: OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN']
                elif method == 'DESCRIBE':
                    for _ in range(50):
                        if self.source.sps and self.source.pps: break
                        time.sleep(0.1)
                    if not (self.source.sps and self.source.pps):
                        self._reply(conn, wlock, hdr, '404 Not Found'); continue
                    sprop = ','.join(base64.b64encode(x).decode() for x in (self.source.sps, self.source.pps))
                    base = url.rstrip('/') + '/'
                    body = ('v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=cam\r\nc=IN IP4 0.0.0.0\r\nt=0 0\r\n'
                            'm=video 0 RTP/AVP 96\r\na=control:trackID=0\r\na=rtpmap:96 H264/90000\r\n'
                            f'a=fmtp:96 packetization-mode=1; sprop-parameter-sets={sprop}\r\n').encode()
                    extra = ['Content-Type: application/sdp', f'Content-Base: {base}']
                elif method == 'SETUP':
                    extra = ['Transport: RTP/AVP/TCP;unicast;interleaved=0-1', 'Session: 4242;timeout=60']
                elif method == 'PLAY':
                    extra = ['Session: 4242']
                    self._reply(conn, wlock, hdr, '200 OK', extra)
                    self.source.subscribe(send_unit)
                    continue
                elif method == 'TEARDOWN':
                    self._reply(conn, wlock, hdr, '200 OK'); break
                self._reply(conn, wlock, hdr, '200 OK', extra, body)
        except (OSError, ValueError):
            pass
        finally:
            self.source.unsubscribe(send_unit)
            conn.close()

    @staticmethod
    def _reply(conn, wlock, hdr, status, extra=(), body=b''):
        lines = [f'RTSP/1.0 {status}', f"CSeq: {hdr.get('cseq', '0')}", *extra, f'Content-Length: {len(body)}']
        with wlock: conn.sendall(('\r\n'.join(lines) + '\r\n\r\n').encode() + body)
