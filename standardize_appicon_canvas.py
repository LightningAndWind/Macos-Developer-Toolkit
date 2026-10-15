#!/usr/bin/env python3
"""Conform the devkit app icon to the macOS standard icon grid (v3).

Problem
-------
The artwork is full-bleed: the squircle fills the whole 1024x1024 canvas
with zero margin, so in Dock / Launchpad it reads one size step larger
than every neighboring app.

Standard (macOS Big Sur+ grid, verified against Edge's shipped icns:
solid shape exactly 824x824 at (100,100) on a 1024 canvas):
  * canvas 1024x1024, visible squircle 824x824 centered -> 100px margin
  * corner radius 185.4 (fraction 0.225 of the squircle)
devkit's current corner fits a circular radius of ~229/1024 = 0.2247 --
the same fraction as the standard -- so a uniform downscale is exact.

Fix
---
Uniformly rescale the whole artwork 1024 -> 824, center it on a
transparent 1024 canvas, then regenerate every AppIcon size from it.

Note: the source has RGB=(0,0,0) under transparent pixels, so all
resampling goes through premultiplied alpha to avoid dark fringes.
"""
import shutil
from PIL import Image
import numpy as np

SET = '/Users/cai/Documents/develop/doc/code/macos-app/Macos-Developer-Toolkit/devkit/devkit/Assets.xcassets/AppIcon.appiconset/'
MASTER = SET + 'icon_512x512@2x.png'
CANVAS = 1024
CONTENT = 824
MARGIN = (CANVAS - CONTENT) // 2  # 100

SIZES = {
    'icon_16x16.png': 16,   'icon_16x16@2x.png': 32,
    'icon_32x32.png': 32,   'icon_32x32@2x.png': 64,
    'icon_128x128.png': 128, 'icon_128x128@2x.png': 256,
    'icon_256x256.png': 256, 'icon_256x256@2x.png': 512,
    'icon_512x512.png': 512, 'icon_512x512@2x.png': 1024,
}


def resize_rgba(im, size):
    """LANCZOS resize through premultiplied alpha (avoids black fringes)."""
    a = np.asarray(im).astype(np.float64)
    al = a[:, :, 3:4]
    pm = np.empty_like(a)
    pm[:, :, :3] = np.round(a[:, :, :3] * al / 255.0)
    pm[:, :, 3:4] = al
    out = np.asarray(
        Image.fromarray(pm.astype(np.uint8), 'RGBA').resize(size, Image.LANCZOS)
    ).astype(np.float64)
    al2 = out[:, :, 3]
    res = np.zeros_like(out)
    nz = al2 > 0
    res[nz, :3] = np.clip(np.round(out[nz, :3] * 255.0 / al2[nz, None]), 0, 255)
    res[:, :, 3] = al2
    return Image.fromarray(res.astype(np.uint8), 'RGBA')


master = Image.open(MASTER).convert('RGBA')
assert master.size == (CANVAS, CANVAS), master.size

# 1. uniform downscale of the entire artwork 1024 -> 824
content = resize_rgba(master, (CONTENT, CONTENT))

# 2. center on a transparent 1024 canvas
canvas = Image.new('RGBA', (CANVAS, CANVAS), (0, 0, 0, 0))
canvas.alpha_composite(content, (MARGIN, MARGIN))
canvas.save(MASTER)

# 3. regenerate every size from the new master
for name, size in SIZES.items():
    resize_rgba(canvas, (size, size)).save(SET + name)
print('regenerated', len(SIZES), 'sizes')

# ---------- 4. verify ----------
chk = np.asarray(Image.open(MASTER).convert('RGBA'))
alpha = chk[:, :, 3]
ys, xs = np.nonzero(alpha >= 200)
bbox = (xs.min(), ys.min(), xs.max(), ys.max())
print('solid bbox:', bbox, 'size:', xs.max() - xs.min() + 1, 'x', ys.max() - ys.min() + 1)
assert bbox == (MARGIN, MARGIN, CANVAS - MARGIN - 1, CANVAS - MARGIN - 1), 'content not on the standard grid!'

outside = np.ones((CANVAS, CANVAS), bool)
outside[MARGIN:CANVAS - MARGIN, MARGIN:CANVAS - MARGIN] = False
assert alpha[outside].max() == 0, 'margin is not fully transparent!'
print('margins: fully transparent 100px on all sides  OK')

# gradient must still be purely vertical: sample bg-only side windows
# (clear of the corner curves and of the central glyph) at many heights
for y in range(200, 850, 50):
    left = chk[y, 160:240, :3].astype(int)
    right = chk[y, 780:860, :3].astype(int)
    assert left.max() - left.min() <= 8 and right.max() - right.min() <= 8, f'row {y} banding'
    assert abs(int(left.mean()) - int(right.mean())) <= 3, f'row {y} not vertical'
print('background gradient: still vertical  OK')

# corner radius proportion preserved (leftmost opaque x on content top row)
row0 = np.nonzero(alpha[MARGIN] >= 128)[0]
f = (row0.min() - MARGIN) / CONTENT
print(f'corner profile: leftmost opaque on top row = {row0.min()} '
      f'(offset {row0.min() - MARGIN}px, fraction {f:.4f}; expected ~0.21)')

# small-size spot check
small = np.asarray(Image.open(SET + 'icon_16x16@2x.png').convert('RGBA'))
ys2, xs2 = np.nonzero(small[:, :, 3] >= 200)
print('32px icon solid bbox:', (xs2.min(), ys2.min(), xs2.max(), ys2.max()),
      f'(expected ~(3,3)-(28,28), content frac {(xs2.max()-xs2.min()+1)/32:.3f})')
print('DONE')
