# A tiny "world" for the mock rover's camera: a photo of the target pasted into a room,
# viewed through a window that pans when the rover turns and zooms when it drives forward.
# Lets the Follow feature be tested in a closed loop without a real rover.
import io, math, threading, time
from PIL import Image, ImageDraw, ImageFilter

class Sim:
    OUT = (640, 480)           # camera frame

    def __init__(self, photo_path, start_offset=0.22, target_scale=1.0):
        photo = Image.open(photo_path).convert('RGB')
        ow, oh = photo.size
        # Canvas twice the photo's size. The background is a heavily blurred stretch of the
        # photo's right side (no cat there), so the scene stays natural.
        self.W, self.H = ow * 2, oh * 2
        background = photo.crop((int(ow * 0.55), 0, ow, oh))
        world = background.resize((self.W, self.H)).filter(ImageFilter.GaussianBlur(40))
        # target_scale < 1 shrinks the photo: the cat looks far away.
        pw, ph = max(16, int(ow * target_scale)), max(12, int(oh * target_scale))
        sharp = photo.resize((pw, ph))
        feather = max(2, int(24 * target_scale))
        mask = Image.new('L', (pw, ph), 0)
        ImageDraw.Draw(mask).rectangle((feather, feather, pw - feather, ph - feather), fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(max(1, int(16 * target_scale))))
        ox, oy = (self.W - pw) // 2, (self.H - ph) // 2
        world.paste(sharp, (ox, oy), mask)
        self.world = world
        # Where the target is (for /sim reporting): the cat in the sample frame.
        self.target_center = (ox + 0.30 * pw, oy + 0.55 * ph)
        self.max_zoom = 2.6 / max(target_scale, 0.05)

        self.base_vw = ow * 1.25
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
        self.zoom = min(self.max_zoom, max(1.0, self.zoom * math.exp(lin * 3.0 * dt)))
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
