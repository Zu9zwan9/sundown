#!/usr/bin/env python3
"""Generate Sundown.iconset.

The mark: a disc crossing a horizon. Literal — the app is called Sundown and
it ends things. Two shapes and one line, because an icon that isn't legible at
16pt in a Dock isn't an icon.

Everything is drawn at 4x and downsampled, which is cheaper than fighting
PIL's aliasing.

Run:  python3 Scripts/make_icon.py
Then: iconutil -c icns build/Sundown.iconset -o build/Sundown.icns   (macOS only)
"""

import math
from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SS = 4                      # supersample factor
SIZE = 1024
CANVAS = SIZE * SS

# Dusk, not night. The sun is still up, which is the moment the app is named
# for — the end of the working day, not the middle of the night.
SKY_TOP = (18, 22, 48)
SKY_BOTTOM = (86, 44, 82)
GROUND = (12, 14, 32)
SUN_TOP = (255, 206, 122)
SUN_BOTTOM = (255, 122, 69)
HORIZON = (255, 168, 96)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def superellipse_mask(size, n=5.0, inset=0.0):
    """Apple's icon silhouette is a squircle, not a rounded rectangle. The
    difference is invisible in isolation and obvious beside real app icons."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    half = size / 2 - inset
    cx = cy = size / 2
    points = []
    steps = 720
    for i in range(steps):
        t = 2 * math.pi * i / steps
        ct, st = math.cos(t), math.sin(t)
        x = cx + half * (abs(ct) ** (2 / n)) * (1 if ct >= 0 else -1)
        y = cy + half * (abs(st) ** (2 / n)) * (1 if st >= 0 else -1)
        points.append((x, y))
    draw.polygon(points, fill=255)
    return mask


def build():
    img = Image.new("RGB", (CANVAS, CANVAS), SKY_TOP)
    draw = ImageDraw.Draw(img)

    horizon_y = int(CANVAS * 0.62)

    # Sky: vertical gradient, one line at a time.
    for y in range(horizon_y):
        draw.line([(0, y), (CANVAS, y)], fill=lerp(SKY_TOP, SKY_BOTTOM, y / horizon_y))

    # Ground: flat and much darker, so the horizon reads as an edge rather
    # than a seam.
    draw.rectangle([0, horizon_y, CANVAS, CANVAS], fill=GROUND)

    # Sun, drawn on its own layer so it can be clipped to the sky.
    sun_r = int(CANVAS * 0.185)
    sun_cx = CANVAS // 2
    sun_cy = horizon_y - int(sun_r * 0.42)   # crossing the line, mostly above

    sun = Image.new("RGB", (CANVAS, CANVAS), SKY_TOP)
    sd = ImageDraw.Draw(sun)
    for y in range(sun_cy - sun_r, sun_cy + sun_r):
        t = (y - (sun_cy - sun_r)) / (2 * sun_r)
        sd.line([(0, y), (CANVAS, y)], fill=lerp(SUN_TOP, SUN_BOTTOM, t))

    disc = Image.new("L", (CANVAS, CANVAS), 0)
    ImageDraw.Draw(disc).ellipse(
        [sun_cx - sun_r, sun_cy - sun_r, sun_cx + sun_r, sun_cy + sun_r], fill=255
    )
    # Clip the disc at the horizon — the bottom of the sun is behind the world.
    ImageDraw.Draw(disc).rectangle([0, horizon_y, CANVAS, CANVAS], fill=0)
    img.paste(sun, (0, 0), disc)

    # Glow above the horizon. Blur a bright band and screen it back in, which
    # is what stops the composition reading as two flat rectangles.
    glow = Image.new("RGB", (CANVAS, CANVAS), (0, 0, 0))
    ImageDraw.Draw(glow).rectangle(
        [0, horizon_y - int(CANVAS * 0.02), CANVAS, horizon_y], fill=HORIZON
    )
    glow = glow.filter(ImageFilter.GaussianBlur(CANVAS * 0.045))
    # Screen, not add-with-scale. `add(scale=1.6)` divides the sum by 1.6,
    # which darkens and desaturates the whole image — it turned the sun brown.
    img = ImageChops.screen(img, glow)

    # Crisp horizon rule on top of the glow.
    draw = ImageDraw.Draw(img)
    lw = max(1, int(CANVAS * 0.006))
    draw.rectangle([0, horizon_y - lw // 2, CANVAS, horizon_y + lw // 2], fill=HORIZON)

    # Squircle silhouette with the standard macOS margin.
    margin = CANVAS * 0.085
    mask = superellipse_mask(CANVAS, n=5.0, inset=margin)
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(img, (0, 0), mask)

    return out.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    root = Path(__file__).resolve().parent.parent
    iconset = root / "build" / "Sundown.iconset"
    iconset.mkdir(parents=True, exist_ok=True)

    master = build()
    (root / "Assets").mkdir(exist_ok=True)
    master.save(root / "Assets" / "icon-1024.png")

    for base in (16, 32, 128, 256, 512):
        master.resize((base, base), Image.LANCZOS).save(
            iconset / f"icon_{base}x{base}.png"
        )
        master.resize((base * 2, base * 2), Image.LANCZOS).save(
            iconset / f"icon_{base}x{base}@2x.png"
        )

    print(f"✓ {iconset}")
    print(f"✓ {root / 'Assets' / 'icon-1024.png'}")
    print("\nOn macOS, finish with:")
    print(f"  iconutil -c icns '{iconset}' -o '{root / 'build' / 'Sundown.icns'}'")


if __name__ == "__main__":
    main()
