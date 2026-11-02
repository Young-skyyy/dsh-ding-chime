"""Compose the GitHub social preview image (1280x640).

Run:  python plugins/ding-chime/tools/make-social.py
Output: <repo>/assets/social-preview.png
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
BG_TOP = (11, 18, 32)
BG_BOTTOM = (22, 33, 54)
AMBER = (232, 161, 58)
WHITE = (241, 245, 249)
MUTED = (148, 163, 184)

FONT_BOLD = r"C:\Windows\Fonts\msyhbd.ttc"
FONT_REGULAR = r"C:\Windows\Fonts\msyh.ttc"


def gradient(size: tuple[int, int]) -> Image.Image:
    image = Image.new("RGB", size, BG_TOP)
    draw = ImageDraw.Draw(image)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(BG_TOP, BG_BOTTOM))
        draw.line([(0, y), (size[0], y)], fill=color)
    return image


def draw_bell(draw: ImageDraw.ImageDraw, cx: int, cy: int, scale: float) -> None:
    """A chunky bell in amber, roughly the tray icon at 4x."""
    def s(v: float) -> float:
        return v * scale

    # hat
    draw.ellipse([cx - s(1.5), cy - s(10), cx + s(1.5), cy - s(6.5)], fill=AMBER)
    # dome
    draw.ellipse([cx - s(7), cy - s(7), cx + s(7), cy + s(6)], fill=AMBER)
    # skirt
    draw.polygon(
        [
            (cx - s(6.6), cy + s(0.5)),
            (cx + s(6.6), cy + s(0.5)),
            (cx + s(9.5), cy + s(8.5)),
            (cx - s(9.5), cy + s(8.5)),
        ],
        fill=AMBER,
    )
    # rim
    draw.rounded_rectangle(
        [cx - s(10.5), cy + s(7.5), cx + s(10.5), cy + s(11)], radius=s(1.6), fill=AMBER
    )
    # clapper
    draw.ellipse([cx - s(2.6), cy + s(10.5), cx + s(2.6), cy + s(14.5)], fill=AMBER)


def main() -> None:
    root = pathlib.Path(__file__).resolve().parent.parent
    image = gradient((W, H))
    draw = ImageDraw.Draw(image)

    # soft glow behind the bell
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    for radius, alpha in ((260, 26), (200, 30), (140, 34)):
        glow_draw.ellipse(
            [200 - radius, 320 - radius, 200 + radius, 320 + radius],
            fill=(232, 161, 58, alpha),
        )
    image = Image.alpha_composite(image.convert("RGBA"), glow).convert("RGB")
    draw = ImageDraw.Draw(image)

    draw_bell(draw, 200, 300, 4.6)

    title_font = ImageFont.truetype(FONT_BOLD, 82)
    sub_font = ImageFont.truetype(FONT_REGULAR, 34)
    tag_font = ImageFont.truetype(FONT_REGULAR, 26)

    draw.text((420, 210), "DSH 完成提示音", font=title_font, fill=WHITE)
    draw.text((424, 316), "每轮结束响一声 · 任务栏按钮闪一下", font=sub_font, fill=MUTED)
    draw.text((424, 370), "托盘可静音 · 10 种音色 · 音量自适应", font=sub_font, fill=MUTED)

    # bottom tag line
    draw.line([(424, 452), (1180, 452)], fill=(51, 65, 85), width=2)
    draw.text((424, 476), "deepseek-harness  ·  Windows  ·  MIT", font=tag_font, fill=MUTED)
    draw.text((424, 516), "github.com/Young-skyyy/dsh-ding-chime", font=tag_font, fill=(251, 191, 36))

    out = root / "assets" / "social-preview.png"
    image.save(out, optimize=True)
    print(f"wrote {out} ({out.stat().st_size} bytes, {image.size[0]}x{image.size[1]})")


if __name__ == "__main__":
    main()
