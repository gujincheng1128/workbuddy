#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""LongCut 0.2.10 - generate a 15-second vertical short film.

All source material comes from this repository (logo + editor screenshots);
all intermediate files, the audio and the final MP4 stay inside the project
directory. No downloads and no writes outside the workspace.

The soundtrack is built by tools/make_15s_audio.py: an original 15-second
synth BGM plus five lines of offline Chinese narration, ducked under the
voice and mixed into a single stereo WAV before muxing.

    python tools/make_15s_short.py

Output:
    dist/media/LongCut-0.2.10-15s.mp4      1080x1920, 30 fps, H.264 + AAC, 15.000 s
    dist/media/LongCut-0.2.10-15s-cover.png
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FFBIN = ROOT / "tools" / "ffmpeg" / "ffmpeg-master-latest-win64-gpl-shared" / "bin"
FFMPEG = FFBIN / "ffmpeg.exe"
FFPROBE = FFBIN / "ffprobe.exe"
TMP = ROOT / "tools" / "_tmp" / "short15"
CARDS = TMP / "cards"
OUTDIR = ROOT / "dist" / "media"
MP4 = OUTDIR / "LongCut-0.2.10-15s.mp4"
COVER = OUTDIR / "LongCut-0.2.10-15s-cover.png"
WAV = TMP / "soundtrack.wav"

W, H = 1080, 1920
FPS = 30
SEG = 3.0
SEG_FRAMES = int(SEG * FPS)  # 90
N = 5
DURATION = SEG * N  # 15.000 s

BG_TOP = (10, 10, 12)
BG_BOTTOM = (18, 25, 36)
ACCENT = (46, 168, 255)  # LongCut accent blue, dark.slint:139
FG = (245, 245, 247)  # dark.slint:115
MUTED = (161, 161, 166)  # dark.slint:116
DIM = (110, 110, 118)


def font(size: int, bold: bool = True) -> ImageFont.FreeTypeFont:
    candidates = [
        "C:/Windows/Fonts/msyhbd.ttc" if bold else "C:/Windows/Fonts/msyh.ttc",
        "C:/Windows/Fonts/simhei.ttf",
        "C:/Windows/Fonts/arialbd.ttf" if bold else "C:/Windows/Fonts/arial.ttf",
    ]
    for path in candidates:
        if Path(path).is_file():
            return ImageFont.truetype(path, size)
    raise RuntimeError("no CJK font found on this machine")


def base(top=BG_TOP, bottom=BG_BOTTOM) -> Image.Image:
    img = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(img)
    for y in range(H):
        f = y / (H - 1)
        colour = tuple(int(top[i] + (bottom[i] - top[i]) * f) for i in range(3))
        draw.line([(0, y), (W, y)], fill=colour)
    return img


def glow(img: Image.Image, cx: int, cy: int, radius: int,
         colour=ACCENT, alpha: int = 70) -> Image.Image:
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(layer).ellipse(
        [cx - radius, cy - radius, cx + radius, cy + radius],
        fill=(*colour, alpha),
    )
    layer = layer.filter(ImageFilter.GaussianBlur(radius // 2))
    return Image.alpha_composite(img.convert("RGBA"), layer).convert("RGB")


def centre(draw: ImageDraw.ImageDraw, y: int, text: str, fnt, fill) -> None:
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text(((W - (box[2] - box[0])) / 2 - box[0], y), text, font=fnt, fill=fill)


def progress(draw: ImageDraw.ImageDraw, active: int) -> None:
    """Five short rules along the bottom, one lit per 3-second chapter."""
    gap, width, thickness = 22, 176, 7
    total = N * width + (N - 1) * gap
    x0 = (W - total) / 2
    y = 1810
    for i in range(N):
        x = x0 + i * (width + gap)
        colour = ACCENT if i == active else (58, 58, 64)
        draw.rounded_rectangle(
            [x, y, x + width, y + thickness], radius=thickness // 2, fill=colour
        )


def logo(size: int = 300) -> Image.Image:
    src = Image.open(ROOT / "assets" / "concat_logo_512.png").convert("RGBA")
    return src.resize((size, size), Image.Resampling.LANCZOS)


def fit_cover(src: Image.Image, width: int, height: int) -> Image.Image:
    scale = max(width / src.width, height / src.height)
    big = src.resize((int(src.width * scale) + 1, int(src.height * scale) + 1),
                     Image.Resampling.LANCZOS)
    left = (big.width - width) // 2
    top = (big.height - height) // 2
    return big.crop((left, top, left + width, top + height))


def chapter_label(draw: ImageDraw.ImageDraw, text: str) -> None:
    centre(draw, 250, text, font(36, True), ACCENT)
    draw.line([(W // 2 - 90, 330), (W // 2 + 90, 330)], fill=(58, 58, 64), width=3)


def card_opening() -> Image.Image:
    img = glow(base(), W // 2, 700, 430, ACCENT, 78)
    draw = ImageDraw.Draw(img)
    draw.line([(120, 170), (W - 120, 170)], fill=ACCENT, width=3)
    mark = logo(300)
    img.paste(mark, ((W - 300) // 2, 545), mark)
    centre(draw, 940, "龙儿剪辑", font(112, True), FG)
    centre(draw, 1090, "LongCut", font(72, True), ACCENT)
    centre(draw, 1190, "0.2.10", font(40, False), MUTED)
    centre(draw, 1540, "开源视频编辑器", font(46, False), MUTED)
    centre(draw, 1640, "基于 Concat 引擎 · AGPL-3.0", font(32, False), DIM)
    progress(draw, 0)
    return img


def screenshot_card(asset: str, tag: str, title: str, subtitle: str,
                    active: int) -> Image.Image:
    src = Image.open(ROOT / "assets" / asset).convert("RGB")
    bg = fit_cover(src, W, H).filter(ImageFilter.GaussianBlur(45))
    bg = Image.blend(bg, Image.new("RGB", (W, H), (8, 9, 12)), 0.62)
    bg = glow(bg, W // 2, 900, 520, ACCENT, 42)

    fw = 980
    fh = int(src.height * fw / src.width)
    fg_img = src.resize((fw, fh), Image.Resampling.LANCZOS).convert("RGBA")
    mask = Image.new("L", (fw, fh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, fw - 1, fh - 1], radius=30, fill=255)
    fg_img.putalpha(mask)

    shadow = Image.new("RGBA", (fw + 60, fh + 60), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [30, 30, fw + 30, fh + 30], radius=30, fill=(0, 0, 0, 190)
    )
    shadow = shadow.filter(ImageFilter.GaussianBlur(32))
    x, y = (W - fw) // 2, 690
    bg.paste(shadow, (x - 30, y - 30), shadow)
    bg.paste(fg_img, (x, y), fg_img)

    draw = ImageDraw.Draw(bg)
    chapter_label(draw, tag)
    centre(draw, 1440, title, font(70, True), FG)
    centre(draw, 1560, subtitle, font(38, False), MUTED)
    progress(draw, active)
    return bg


def card_numbers() -> Image.Image:
    img = glow(base(), W // 2, 700, 460, ACCENT, 62)
    draw = ImageDraw.Draw(img)
    chapter_label(draw, "03 / QUALITY")
    centre(draw, 530, "962", font(250, True), FG)
    centre(draw, 850, "项单元测试 · 全部通过", font(50, False), MUTED)

    labels = [("15", "项发布门禁"), ("0", "失败"), ("RC=0", "端到端")]
    gap, bw = 36, 296
    x0 = (W - (3 * bw + 2 * gap)) / 2
    for i, (big, small) in enumerate(labels):
        x = x0 + i * (bw + gap)
        draw.rounded_rectangle([x, 1030, x + bw, 1290], radius=26,
                              fill=(30, 32, 38), outline=(58, 60, 68), width=2)
        centre_at(draw, (x + x + bw) / 2, 1090, big,
                  font(66, True), ACCENT)
        centre_at(draw, (x + x + bw) / 2, 1200, small,
                  font(32, False), MUTED)

    centre(draw, 1460, "可发布 · 已验收", font(76, True), ACCENT)
    centre(draw, 1600, "clean-PATH 冒烟 / Windows GNU 工具链", font(30, False), DIM)
    progress(draw, 3)
    return img


def centre_at(draw: ImageDraw.ImageDraw, cx: float, y: int, text: str, fnt, fill) -> None:
    box = draw.textbbox((0, 0), text, font=fnt)
    draw.text((cx - (box[2] - box[0]) / 2 - box[0], y), text, font=fnt, fill=fill)


def card_outro() -> Image.Image:
    img = glow(base((10, 10, 12), (20, 34, 52)), W // 2, 820, 470, ACCENT, 82)
    draw = ImageDraw.Draw(img)
    mark = logo(260)
    img.paste(mark, ((W - 260) // 2, 500), mark)
    centre(draw, 880, "LongCut 0.2.10", font(84, True), FG)
    centre(draw, 1020, "15 秒，看清一个编辑器", font(50, False), ACCENT)
    draw.line([(W // 2 - 160, 1160), (W // 2 + 160, 1160)], fill=ACCENT, width=4)
    centre(draw, 1250, "时间线 · 模板 · 一键成片", font(40, False), MUTED)
    centre(draw, 1340, "导出 / 便携包 / 安装包 全链路", font(40, False), MUTED)
    centre(draw, 1600, "开源基座 Concat · AGPL-3.0", font(34, False), DIM)
    progress(draw, 4)
    return img


def build_soundtrack() -> None:
    """BGM + Chinese narration, produced by the companion audio script."""
    script = ROOT / "tools" / "make_15s_audio.py"
    subprocess.run([sys.executable, str(script)], check=True)
    print(f"[audio] using {WAV.name}")


def build_cards() -> list[Path]:
    CARDS.mkdir(parents=True, exist_ok=True)
    makers = [
        card_opening,
        lambda: screenshot_card("editor-dark.png", "01 / EDITOR",
                                "多轨时间线 · 实时预览",
                                "剪、切、转场、调色，一屏完成", 1),
        lambda: screenshot_card("editor.png", "02 / TEMPLATE",
                                "模板 · 一键成片",
                                "套用模板，素材自动绑定", 2),
        card_numbers,
        card_outro,
    ]
    paths = []
    for i, make in enumerate(makers, 1):
        path = CARDS / f"card-{i}.png"
        make().save(path, "PNG", optimize=True)
        paths.append(path)
        print(f"[card] {i}/{N} {path.name}")
    return paths


def render(cards: list[Path]) -> None:
    OUTDIR.mkdir(parents=True, exist_ok=True)
    cmd = [str(FFMPEG), "-y", "-hide_banner", "-loglevel", "error"]
    for card in cards:
        cmd += ["-i", str(card)]
    cmd += ["-i", str(WAV)]

    chains = []
    for i in range(N):
        chains.append(
            f"[{i}:v]scale={W}:{H},setsar=1,"
            f"zoompan=z='min(zoom+0.00065,1.06)':d={SEG_FRAMES}:"
            f"x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':"
            f"s={W}x{H}:fps={FPS},"
            f"fade=t=in:st=0:d=0.35,"
            f"fade=t=out:st={SEG - 0.35}:d=0.35,"
            f"format=yuv420p[v{i}]"
        )
    chains.append(
        "".join(f"[v{i}]" for i in range(N)) + f"concat=n={N}:v=1:a=0[vout]"
    )
    cmd += [
        "-filter_complex", ";".join(chains),
        "-map", "[vout]", "-map", f"{N}:a",
        "-c:v", "libx264", "-preset", "medium", "-crf", "19",
        "-pix_fmt", "yuv420p", "-r", str(FPS),
        "-c:a", "aac", "-b:a", "128k", "-ar", "44100",
        "-movflags", "+faststart", "-t", f"{DURATION:.3f}",
        str(MP4),
    ]
    print(f"[render] {N} chapters x {SEG:.1f}s -> {MP4}")
    subprocess.run(cmd, check=True)


def verify() -> None:
    raw = subprocess.check_output([
        str(FFPROBE), "-v", "error",
        "-show_entries",
        "format=duration,size:stream=index,codec_name,codec_type,width,height,r_frame_rate,nb_frames",
        "-of", "json", str(MP4),
    ], text=True)
    info = json.loads(raw)
    print(f"[verify] duration={info['format']['duration']}s "
          f"size={info['format']['size']} bytes")
    for stream in info["streams"]:
        print("         " + " ".join(
            f"{k}={stream.get(k)}" for k in
            ("index", "codec_type", "codec_name", "width", "height",
             "r_frame_rate", "nb_frames") if stream.get(k) is not None
        ))
    for t in (1.5, 4.5, 7.5, 10.5, 13.5):
        out = TMP / f"preview-{t:04.1f}.png"
        subprocess.run([
            str(FFMPEG), "-y", "-hide_banner", "-loglevel", "error",
            "-ss", str(t), "-i", str(MP4), "-frames:v", "1", str(out),
        ], check=True)
        print(f"[frame] t={t:>4.1f}s -> {out.name}")


def main() -> int:
    for tool in (FFMPEG, FFPROBE):
        if not tool.is_file():
            raise RuntimeError(f"missing {tool}")
    TMP.mkdir(parents=True, exist_ok=True)
    OUTDIR.mkdir(parents=True, exist_ok=True)
    print(f"[short] LongCut 0.2.10 / {W}x{H} / {FPS} fps / {DURATION:.3f}s")
    build_soundtrack()
    cards = build_cards()
    # Cover: the opening card, downscaled for chat/preview.
    Image.open(cards[0]).resize((540, 960), Image.Resampling.LANCZOS).save(COVER)
    render(cards)
    verify()
    print(f"[done] {MP4}")
    return 0


if __name__ == "__main__":
    sys_exit = main()
    raise SystemExit(sys_exit)
