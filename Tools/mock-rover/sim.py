# A tiny "world" for the mock rover's camera: a photo of the target pasted into a room,
# viewed through a window that pans when the rover turns and zooms when it drives forward.
# Lets the Follow feature be tested in a closed loop without a real rover.
import io, math, threading, time
from PIL import Image, ImageDraw, ImageFilter

class Sim:
    OUT = (640, 480)           # camera frame

    def __init__(self, photo_path, start_offset=0.22):
        photo = Image.open(photo_path).convert('RGB')
        pw, ph = photo.size
        # The photo sits in the middle of a canvas twice its size, surrounded by a heavily
        # blurred stretch of itself, so the scene stays natural but the target looks small.
        self.W, self.H = pw * 2, ph * 2
        world = photo.resize((self.W, self.H)).filter(ImageFilter.GaussianBlur(60))
        mask = Image.new('L', (pw, ph), 0)
        ImageDraw.Draw(mask).rectangle((24, 24, pw - 24, ph - 24), fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(16))
        ox, oy = pw // 2, ph // 2
        world.paste(photo, (ox, oy), mask)
        self.world = world
        # Where the target is in the photo (for /sim reporting): the cat in the sample frame.
        self.target_center = (ox + 0.30 * pw, oy + 0.55 * ph)

        self.base_vw = pw * 1.25
        self.start_offset = start_offset
        self.cy = oy + ph * 0.5
        self.lock = threading.Lock()
        self.reset()

    def reset(self):
        """Back to the start: target near the left edge of the view, not zoomed."""
        with self.lock:
            self.zoom = 1.0
            self.cx = self.target_center[0] + self.start_offset * self.base_vw
            self.cmd = (0.0, 0.0)
            self.cmd_at = 0.0
            self.last = time.time()

    def command(self, linear, angular):
        with self.lock:
            self.cmd = (float(linear), float(angular))
            self.cmd_at = time.time()

    def step(self):
        now = time.time()
        dt, self.last = now - self.last, now
        with self.lock:
            lin, ang = self.cmd if now - self.cmd_at < 0.5 else (0.0, 0.0)   # ESP32-style timeout
        self.cx -= ang * 0.25 * self.W * dt / 1.0          # turning left pans the view left
        self.zoom = min(2.6, max(1.0, self.zoom * math.exp(lin * 3.0 * dt)))
        vw = self.base_vw / self.zoom
        self.cx = min(max(self.cx, vw / 2), self.W - vw / 2)

    def frame(self):
        self.step()
        vw = self.base_vw / self.zoom
        vh = vw * 3 / 4
        cy = min(max(self.cy, vh / 2), self.H - vh / 2)
        box = (int(self.cx - vw / 2), int(cy - vh / 2), int(self.cx + vw / 2), int(cy + vh / 2))
        img = self.world.crop(box).resize(self.OUT)
        buf = io.BytesIO()
        img.save(buf, 'JPEG', quality=70)
        return buf.getvalue()

    def state(self):
        vw = self.base_vw / self.zoom
        return {'zoom': round(self.zoom, 3),
                'target_x_in_view': round((self.target_center[0] - (self.cx - vw / 2)) / vw, 3),
                'cmd': self.cmd}
