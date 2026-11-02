"""Draw the tray icons for the chime (bell on / bell muted / bell ringing).

Run:  python plugins/ding-chime/tools/make-icons.py
Output: assets/tray-on.png, assets/tray-off.png, assets/tray-ring.png  (32x32 RGBA)
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

SIZE = 32
AMBER = (232, 161, 58, 255)
GREY = (150, 156, 165, 255)
RED = (226, 92, 82, 255)


def bell(draw: ImageDraw.ImageDraw, color: tuple[int, int, int, int]) -> None:
    # Hat
    draw.ellipse((14.0, 4.0, 18.0, 8.0), fill=color)
    # Dome
    draw.ellipse((9.0, 7.0, 23.0, 20.0), fill=color)
    # Skirt: straight sides flaring out to the rim
    draw.polygon([(9.4, 15.0), (22.6, 15.0), (25.5, 23.0), (6.5, 23.0)], fill=color)
    # Rim
    draw.rounded_rectangle((5.5, 22.0, 26.5, 25.5), radius=1.6, fill=color)
    # Clapper
    draw.ellipse((13.6, 24.5, 18.4, 29.0), fill=color)


def main() -> None:
    out = pathlib.Path(__file__).resolve().parent.parent / "assets"
    out.mkdir(parents=True, exist_ok=True)

    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    bell(ImageDraw.Draw(canvas), AMBER)
    canvas.save(out / "tray-on.png")

    muted = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(muted)
    bell(draw, GREY)
    draw.line((5.0, 5.0, 27.0, 27.0), fill=RED, width=3)
    muted.save(out / "tray-off.png")

    ringing = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    draw = ImageDraw.Draw(ringing)
    bell(draw, AMBER)
    draw.ellipse((23.0, 3.0, 30.0, 10.0), fill=RED)
    ringing.save(out / "tray-ring.png")

    for name in ("tray-on.png", "tray-off.png", "tray-ring.png"):
        path = out / name
        print(f"wrote {path} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
