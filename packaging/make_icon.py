"""Generates packaging/studio.ico: a canopy-height skyline in the app's colour ramp."""
import os, random
from PIL import Image, ImageDraw

S = 1024
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
# rounded dark-green tile
d.rounded_rectangle((0, 0, S - 1, S - 1), radius=210, fill=(23, 61, 48, 255))
d.rounded_rectangle((0, 0, S - 1, S // 2), radius=210, fill=(32, 85, 68, 255))
d.rectangle((0, 210, S, S // 2), fill=(32, 85, 68, 255))
d.rectangle((0, S // 2, S, S), fill=(23, 61, 48, 255))
d.rounded_rectangle((0, S - 260, S - 1, S - 1), radius=210, fill=(23, 61, 48, 255))

ramp = [(255, 211, 175), (251, 224, 110), (160, 200, 96), (109, 170, 85), (32, 85, 68)]  # low -> tall canopy
def colour(t):
    x = min(max(t, 0), 1) * (len(ramp) - 1); i = min(int(x), len(ramp) - 2); f = x - i
    return tuple(int(ramp[i][k] * (1 - f) + ramp[i + 1][k] * f) for k in range(3)) + (255,)

random.seed(7)
n, margin, base = 11, 150, S - 170
w = (S - 2 * margin) / n
for i in range(n):
    # taller in the middle, like a forested ridge
    ridge = 1 - abs(i - (n - 1) / 2) / ((n - 1) / 2) * 0.55
    h = (0.35 + 0.65 * random.random()) * ridge
    top = base - h * 640
    x0 = margin + i * w
    # light side + shaded side give a 3D bar look
    d.polygon([(x0, base), (x0, top), (x0 + w * 0.5, top - 38), (x0 + w * 0.5, base - 38)], fill=colour(h))
    d.polygon([(x0 + w * 0.5, top - 38), (x0 + w, top), (x0 + w, base), (x0 + w * 0.5, base - 38)],
              fill=tuple(int(c * 0.72) for c in colour(h)[:3]) + (255,))
    d.polygon([(x0, top), (x0 + w * 0.5, top - 38), (x0 + w, top), (x0 + w * 0.5, top + 38)],
              fill=tuple(min(255, int(c * 1.12)) for c in colour(h)[:3]) + (255,))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "studio.ico")
img.save(out, sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (24, 24), (16, 16)])
img.resize((256, 256), Image.LANCZOS).save(out.replace(".ico", "-preview.png"))
print("wrote", out, os.path.getsize(out), "bytes")
