#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Soundtrack for the LongCut 15-second short: BGM + Chinese narration.

Both layers are generated locally - no downloads, no licensed audio, no
external API calls:

  * BGM      - a 15.000 s original synth cue (Am-F-C-G-Am-F, pad / bass /
               arpeggio / kick / hat), written with the stdlib `wave` module.
  * Narration - five short Chinese lines via the machine's offline SAPI voice
               (Microsoft Huihui). Each line is time-normalised to <= 2.70 s
               and placed 0.25 s into its 3-second chapter. The BGM ducks
               automatically while a line is speaking.

The bean-shaped cloud TTS path is deliberately not used: the configured
VOLCENGINE_SPEECH_API_KEY was verified to return HTTP 401 (Invalid X-Api-Key).
To upgrade to a natural voice later, replace `sapi_voices()` only.

Output: tools/_tmp/short15/soundtrack.wav (44100 Hz, stereo, 15.000 s)
"""

from __future__ import annotations

import json
import math
import random
import subprocess
import sys
import wave
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FFBIN = ROOT / "tools" / "ffmpeg" / "ffmpeg-master-latest-win64-gpl-shared" / "bin"
FFMPEG = FFBIN / "ffmpeg.exe"
FFPROBE = FFBIN / "ffprobe.exe"
TMP = ROOT / "tools" / "_tmp" / "short15"
VOICE = TMP / "voice"
BGM = TMP / "bgm.wav"
SOUNDTRACK = TMP / "soundtrack.wav"

RATE = 44100
TAU = 2.0 * math.pi
DURATION = 15.0
N = 5
SEG = 3.0
MAX_VOICE = 2.70
VOICE_OFFSET = 0.25

LINES = [
    "龙儿剪辑，开机即剪。",
    "多轨时间线，实时预览。",
    "模板一键成片。",
    "九百六十二项测试全绿。",
    "开源基座，剪得更顺手。",
]

# Six bars of 2.5 s each: Am - F - C - G - Am - F. (root, triad)
BAR = 2.5
BEAT = BAR / 4.0
CHORDS = [
    (220.00, (220.00, 261.63, 329.63)),
    (174.61, (174.61, 220.00, 261.63)),
    (261.63, (261.63, 329.63, 392.00)),
    (196.00, (196.00, 246.94, 293.66)),
    (220.00, (220.00, 261.63, 329.63)),
    (174.61, (174.61, 220.00, 261.63)),
]


def ffprobe_duration(path: Path) -> float:
    raw = subprocess.check_output([
        str(FFPROBE), "-v", "error", "-show_entries", "format=duration",
        "-of", "json", str(path),
    ], text=True)
    return float(json.loads(raw)["format"]["duration"])


def synth_bgm() -> None:
    """Deterministic six-bar synth cue, exactly DURATION seconds."""
    frames = int(DURATION * RATE)
    buf = array("h")
    rng = random.Random(20261107)
    for i in range(frames):
        t = i / RATE
        bar = min(int(t / BAR), len(CHORDS) - 1)
        tb = t - bar * BAR
        beat = tb / BEAT
        beat_index = int(beat)
        within = (beat - beat_index) * BEAT
        root, triad = CHORDS[bar]

        # Pad: triad with a soft attack/release per bar, slightly detuned.
        env_bar = min(1.0, tb / 0.25) * min(1.0, (BAR - tb) / 0.35)
        pad = sum(math.sin(TAU * f * t + 0.35 * j) for j, f in enumerate(triad)) / 3.0
        pad = 0.105 * pad * env_bar + 0.022 * math.sin(TAU * triad[1] * 1.005 * t) * env_bar

        # Bass: root one octave down, one pluck per beat.
        bass = 0.10 * math.sin(TAU * (root / 2.0) * t) * math.exp(-within * 5.0)

        # Arpeggio: eighth notes over the triad, one octave up.
        eighth = int(tb / (BEAT / 2.0))
        te = tb - eighth * (BEAT / 2.0)
        arp_freq = triad[eighth % 3] * 2.0
        arp = 0.055 * math.sin(TAU * arp_freq * t) * math.exp(-te * 9.0)

        # Kick on beats 1 and 3, with a falling pitch.
        kick = 0.0
        if beat_index % 2 == 0:
            kick_freq = 48.0 + 55.0 * math.exp(-within * 30.0)
            kick = 0.16 * math.sin(TAU * kick_freq * within) * math.exp(-within * 14.0)

        # Closed hat on every eighth note.
        hat = 0.0
        if te < 0.035:
            hat = 0.020 * (rng.random() * 2.0 - 1.0) * math.exp(-te * 90.0)

        master = min(1.0, t / 0.6) * min(1.0, (DURATION - t) / 1.5)
        mono = (pad + bass + arp + kick + hat) * master
        left = mono + 0.030 * arp
        right = mono - 0.030 * arp
        buf.append(int(max(-1.0, min(1.0, left)) * 32767))
        buf.append(int(max(-1.0, min(1.0, right)) * 32767))

    with wave.open(str(BGM), "wb") as wav:
        wav.setnchannels(2)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        wav.writeframes(buf.tobytes())
    print(f"[bgm] {BGM.name}: {DURATION:.3f}s / 6 bars / {BGM.stat().st_size} bytes")


# One line per short-lived process. SAPI's SpFileStream hangs on this machine
# (a 0-byte WAV and a 60 s timeout); SpMemoryStream works reliably. Running
# each line in a fresh process also keeps COM state from leaking between lines.
SAPI_ONE = r'''
import json
import struct
import sys
import win32com.client
from pathlib import Path

lines = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
text = lines[int(sys.argv[2])]
out = Path(sys.argv[3])
engine = win32com.client.Dispatch("SAPI.SpVoice")
engine.Voice = engine.GetVoices().Item(0)  # Microsoft Huihui, zh-CN
engine.Rate = 0
stream = win32com.client.Dispatch("SAPI.SpMemoryStream")
engine.AudioOutputStream = stream
engine.Speak(text, 0)
data = bytes(stream.GetData())
if data[:4] != b"RIFF":
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt "
    header += struct.pack("<IHHIIHH", 16, 1, 1, 22050, 44100, 2, 16)
    header += b"data" + struct.pack("<I", len(data))
    data = header + data
out.write_bytes(data)
print("OK %d bytes" % len(data), flush=True)
'''


def sapi_voices() -> list[Path]:
    """Five narration lines via the offline Chinese SAPI voice."""
    lines_file = VOICE / "lines.json"
    lines_file.write_text(json.dumps(LINES, ensure_ascii=False), encoding="utf-8")
    print("[voice] SAPI: Microsoft Huihui (zh-CN), SpMemoryStream, 1 process/line")

    paths = []
    for index, text in enumerate(LINES, 1):
        path = VOICE / f"line-{index}-raw.wav"
        try:
            proc = subprocess.run(
                [sys.executable, "-c", SAPI_ONE,
                 str(lines_file), str(index - 1), str(path)],
                capture_output=True, text=True, timeout=90,
            )
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError(f"SAPI line {index} timed out") from exc
        if proc.returncode != 0 or not path.is_file() or path.stat().st_size < 1000:
            raise RuntimeError(
                f"SAPI line {index} failed (rc={proc.returncode}): "
                f"{proc.stdout.strip()} {proc.stderr.strip()}"
            )
        paths.append(path)
        print(f"[voice] {index}/{N} {text} -> {ffprobe_duration(path):.2f}s")
    return paths


def normalise(raw_paths: list[Path]) -> list[tuple[Path, float]]:
    """Resample to 44.1k stereo and tempo-fit every line into <= MAX_VOICE s."""
    result = []
    for index, path in enumerate(raw_paths, 1):
        source_duration = ffprobe_duration(path)
        tempo = min(1.5, max(1.0, source_duration / MAX_VOICE))
        out = VOICE / f"line-{index}.wav"
        subprocess.run([
            str(FFMPEG), "-y", "-hide_banner", "-loglevel", "error",
            "-i", str(path),
            "-af", f"atempo={tempo:.4f},volume=1.7,aresample={RATE}",
            "-ac", "2", "-ar", str(RATE), str(out),
        ], check=True)
        duration = ffprobe_duration(out)
        print(f"[voice] {index}/{N} normalised: {source_duration:.2f}s "
              f"-> {duration:.2f}s (atempo={tempo:.2f})")
        result.append((out, duration))
    return result


def mix(lines: list[tuple[Path, float]]) -> None:
    """BGM bed, ducked under the narration, with a limiter on the master."""
    cmd = [str(FFMPEG), "-y", "-hide_banner", "-loglevel", "error",
           "-i", str(BGM)]
    for path, _ in lines:
        cmd += ["-i", str(path)]

    duck_terms = "+".join(
        f"between(t,{VOICE_OFFSET + i * SEG:.2f},"
        f"{VOICE_OFFSET + i * SEG + MAX_VOICE:.2f})"
        for i in range(N)
    )
    volume_expr = f"0.55-0.28*min(1,{duck_terms})"
    chains = [
        f"[0:a]volume='{volume_expr}':eval=frame,"
        f"afade=t=in:st=0:d=0.6,afade=t=out:st=13.5:d=1.5[bg]"
    ]
    for i in range(N):
        delay = int((VOICE_OFFSET + i * SEG) * 1000)
        chains.append(
            f"[{i + 1}:a]adelay={delay}|{delay},afade=t=in:st=0:d=0.04[v{i}]"
        )
    inputs = "[bg]" + "".join(f"[v{i}]" for i in range(N))
    chains.append(
        f"{inputs}amix=inputs={N + 1}:duration=first:normalize=0,"
        f"loudnorm=I=-16:TP=-1.5:LRA=11,alimiter=limit=0.95[mix]"
    )
    cmd += [
        "-filter_complex", ";".join(chains),
        "-map", "[mix]", "-ac", "2", "-ar", str(RATE),
        "-t", f"{DURATION:.3f}", str(SOUNDTRACK),
    ]
    subprocess.run(cmd, check=True)
    print(f"[mix] {SOUNDTRACK.name}: {ffprobe_duration(SOUNDTRACK):.3f}s "
          f"/ {SOUNDTRACK.stat().st_size} bytes")


def chart() -> None:
    """Waveform picture + loudness numbers, so the audio can be reviewed."""
    from PIL import Image, ImageDraw, ImageFont

    with wave.open(str(SOUNDTRACK), "rb") as wav:
        rate, frames = wav.getframerate(), wav.getnframes()
        pcm = array("h")
        pcm.frombytes(wav.readframes(frames))
    window = rate // 20  # 50 ms, stereo interleaved
    energy = []
    for start in range(0, len(pcm), window * 2):
        block = pcm[start:start + window * 2]
        if not block:
            break
        energy.append(math.sqrt(sum((s / 32768.0) ** 2 for s in block) / len(block)))
    peak = max(abs(s) for s in pcm) / 32768.0
    print(f"[audio] peak={peak:.4f} rms_mean={sum(energy) / len(energy):.4f} "
          f"silent_windows={sum(1 for e in energy if e < 0.001)}/{len(energy)}")

    width, height, pad = 1200, 300, 30
    img = Image.new("RGB", (width, height), (12, 12, 15))
    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("C:/Windows/Fonts/arial.ttf", 16)
    except OSError:
        font = None
    scale = (height - 2 * pad) / 2 / max(max(energy), 0.001)
    middle = height / 2
    for index, value in enumerate(energy):
        x = pad + index / len(energy) * (width - 2 * pad)
        amplitude = value * scale
        draw.line([(x, middle - amplitude), (x, middle + amplitude)],
                  fill=(46, 168, 255), width=2)
    for chapter in range(N):
        x = pad + (chapter * SEG + VOICE_OFFSET) / DURATION * (width - 2 * pad)
        draw.line([(x, pad), (x, height - pad)], fill=(255, 111, 163), width=1)
        draw.text((x + 4, pad + 2), str(chapter + 1), fill=(255, 143, 184), font=font)
    draw.line([(pad, middle), (width - pad, middle)], fill=(70, 70, 76), width=1)
    for second in range(0, 16, 3):
        x = pad + second / DURATION * (width - 2 * pad)
        draw.text((x + 2, height - pad + 6), f"{second}s", fill=(161, 161, 166), font=font)
    draw.text((pad, 8),
              "LongCut 0.2.10 / 15s soundtrack - blue: waveform, pink: narration start",
              fill=(200, 200, 205), font=font)
    out = ROOT / "dist" / "media" / "LongCut-0.2.10-15s-audio.png"
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out, "PNG", optimize=True)
    print(f"[audio] chart -> {out.name}")


def main() -> int:
    if not FFMPEG.is_file():
        raise RuntimeError(f"missing {FFMPEG}")
    TMP.mkdir(parents=True, exist_ok=True)
    VOICE.mkdir(parents=True, exist_ok=True)
    synth_bgm()
    raw = sapi_voices()
    lines = normalise(raw)
    mix(lines)
    chart()
    print(f"[audio] done -> {SOUNDTRACK}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
