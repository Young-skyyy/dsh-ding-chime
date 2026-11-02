"""Synthesize the selectable completion chimes as PCM WAV files.

Run:  python plugins/ding-chime/tools/make-chime.py
Output: assets/sounds/<id>.wav          full-scale master (scaled at playback)
        assets/sounds/<id>-soft.wav     fixed soft fallback (no CoreAudio probe)

Every voice is mono, 44.1 kHz, 16-bit.
"""

from __future__ import annotations

import pathlib
import wave

import numpy as np

SR = 44100
FALLBACK_PEAK = 0.20

# (frequency, start seconds, gain, decay tau, length seconds)
VOICES: dict[str, dict] = {
    # Warm wooden bell, the current default.
    "bell": {
        "duration": 1.45,
        "cutoff": 2400.0,
        "echo": 0.14,
        "partials": ((1.00, 1.00), (2.00, 0.22), (2.76, 0.06), (3.00, 0.07), (4.00, 0.02)),
        "strikes": ((587.33, 0.000, 0.90, 0.55, 1.20), (440.00, 0.140, 0.75, 0.65, 1.25)),
    },
    # Low, round gong — the "do not startle me" option.
    "deep": {
        "duration": 1.90,
        "cutoff": 1100.0,
        "echo": 0.18,
        "partials": ((1.00, 1.00), (2.00, 0.18), (3.00, 0.05)),
        "strikes": ((349.23, 0.000, 0.95, 0.95, 1.80), (261.63, 0.200, 0.80, 1.10, 1.85)),
    },
    # Two crisp electronic blips, rising.
    "tech": {
        "duration": 0.85,
        "cutoff": 5200.0,
        "echo": 0.0,
        "partials": ((1.00, 1.00), (3.00, 0.24), (5.00, 0.10)),
        "strikes": ((880.00, 0.000, 0.85, 0.16, 0.34), (1174.66, 0.120, 0.90, 0.20, 0.42)),
    },
}


def lowpass(x: np.ndarray, cutoff: float, order: int = 2) -> np.ndarray:
    """Zero-phase Butterworth-shaped low pass."""
    spectrum = np.fft.rfft(x)
    freqs = np.fft.rfftfreq(x.size, 1.0 / SR)
    response = 1.0 / np.sqrt(1.0 + (freqs / cutoff) ** (2 * order))
    return np.fft.irfft(spectrum * response, n=x.size)


def strike(
    freq: float,
    start: float,
    gain: float,
    tau: float,
    length: float,
    partials: tuple[tuple[float, float], ...],
    total: int,
) -> np.ndarray:
    out = np.zeros(total, dtype=np.float64)
    begin = int(start * SR)
    span = min(total - begin, int(length * SR))
    if span <= 0:
        return out
    t = np.arange(span) / SR

    for ratio, amp in partials:
        f = freq * ratio
        if f > SR / 2:
            continue
        # Upper partials die away faster, like a struck body.
        decay = np.exp(-t / (tau / (1.0 + 0.6 * (ratio - 1.0))))
        out[begin: begin + span] += amp * gain * decay * np.sin(2 * np.pi * f * t)

    attack = int(0.012 * SR)
    if attack < span:
        out[begin: begin + attack] *= np.sin(0.5 * np.pi * np.arange(attack) / attack) ** 2

    thump = min(span, int(0.09 * SR))
    out[begin: begin + thump] += (
        0.10 * gain
        * np.exp(-np.arange(thump) / SR / 0.035)
        * np.sin(2 * np.pi * (freq / 2.0) * np.arange(thump) / SR)
    )
    return out


def render(voice: dict) -> np.ndarray:
    total = int(SR * voice["duration"])
    signal = np.zeros(total, dtype=np.float64)
    for freq, start, gain, tau, length in voice["strikes"]:
        signal += strike(freq, start, gain, tau, length, voice["partials"], total)

    signal = lowpass(signal, voice["cutoff"])
    if voice["echo"] > 0:
        delay = int(0.085 * SR)
        echo = np.zeros_like(signal)
        echo[delay:] = signal[:-delay] * voice["echo"]
        signal = lowpass(signal + echo, voice["cutoff"] * 0.85)

    fade = int(0.10 * SR)
    signal[-fade:] *= np.linspace(1.0, 0.0, fade)
    peak = np.max(np.abs(signal)) or 1.0
    return signal / peak * 0.95


def write_wav(path: pathlib.Path, data: np.ndarray) -> None:
    pcm = np.clip(data * 32767.0, -32768, 32767).astype("<i2")
    with wave.open(str(path), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(SR)
        wav.writeframes(pcm.tobytes())


def main() -> None:
    out_dir = pathlib.Path(__file__).resolve().parent.parent / "assets" / "sounds"
    out_dir.mkdir(parents=True, exist_ok=True)

    for name, voice in VOICES.items():
        signal = render(voice)
        write_wav(out_dir / f"{name}.wav", signal)
        write_wav(out_dir / f"{name}-soft.wav", signal * FALLBACK_PEAK)
        size = (out_dir / f"{name}.wav").stat().st_size
        print(f"{name:8s} {voice['duration']:.2f}s  {size} bytes")


if __name__ == "__main__":
    main()
