"""Create the bundled alarm, relief and sensor PCM sounds."""
from pathlib import Path
import math
import struct
import wave

rate = 22050
sounds_dir = Path("Sounds")
sounds_dir.mkdir(parents=True, exist_ok=True)
payload = Path("build/Payload/Nivvi.app")
payload.mkdir(parents=True, exist_ok=True)


def write_wav(path, samples):
    with wave.open(str(path), "wb") as sound:
        sound.setnchannels(1)
        sound.setsampwidth(2)
        sound.setframerate(rate)
        sound.writeframes(samples)


def write_siren(path, seconds, frequencies, amplitude, switches_per_sec=2):
    samples = bytearray()
    phase = 0.0
    for i in range(int(rate * seconds)):
        t = i / rate
        frequency = frequencies[int(t * switches_per_sec) % len(frequencies)]
        phase += 2 * math.pi * frequency / rate
        envelope = min(1.0, t / 0.02, (seconds - t) / 0.02)
        value = int(amplitude * 32767 * max(0, envelope) * math.sin(phase))
        samples.extend(struct.pack("<h", value))
    write_wav(path, samples)


def write_relief(path, notes, seconds=4.5, gain=0.16, decay=0.85, attack=0.08):
    samples = bytearray()
    peak = 0
    for i in range(int(rate * seconds)):
        t = i / rate
        value = 0.0
        for onset, frequency in notes:
            age = t - onset
            if age < 0:
                continue
            envelope = (1 - math.exp(-age / attack)) * math.exp(-age / decay)
            bell = (
                math.sin(2 * math.pi * frequency * age)
                + 0.20 * math.sin(2 * math.pi * frequency * 2.01 * age)
                + 0.06 * math.sin(2 * math.pi * frequency * 3.98 * age)
            )
            value += gain * envelope * bell
        value *= min(1.0, max(0.0, (seconds - t) / 0.6))
        sample = int(max(-32767, min(32767, value * 32767)))
        peak = max(peak, abs(sample))
        samples.extend(struct.pack("<h", sample))
    assert 0 < peak < int(32767 * 0.45)
    write_wav(path, samples)


def write_sensor(path):
    seconds = 2.8
    samples = bytearray()
    peak = 0
    for i in range(int(rate * seconds)):
        t = i / rate
        value = 0.0
        for onset, hz in [(0.0, 392.0), (0.8, 440.0)]:
            age = t - onset
            if age >= 0:
                envelope = (1 - math.exp(-age / 0.10)) * math.exp(-age / 0.55)
                value += 0.12 * envelope * math.sin(2 * math.pi * hz * age)
        value *= min(1.0, max(0.0, (seconds - t) / 0.4))
        sample = int(value * 32767)
        peak = max(peak, abs(sample))
        samples.extend(struct.pack("<h", sample))
    assert 0 < peak < int(32767 * 0.20)
    write_wav(path, samples)


sirens = {
    "NivviSiren.wav": ([760, 1100], 0.8, 2),
    "NivviSirenUrgent.wav": ([880, 1400], 0.85, 4),
    "NivviSirenPulse.wav": ([520, 780, 1040], 0.8, 3),
    "NivviSirenDeep.wav": ([380, 560], 0.85, 1.5),
    "NivviSirenHigh.wav": ([1000, 1600], 0.75, 3),
}
reliefs = {
    "NivviRelief.wav": ([(0.0, 523.25), (0.85, 659.25), (1.7, 783.99)], 4.5, 0.16, 0.85, 0.08),
    "NivviReliefWarm.wav": ([(0.0, 392.0), (0.9, 523.25), (1.8, 659.25)], 4.8, 0.15, 1.0, 0.10),
    "NivviReliefBright.wav": ([(0.0, 783.99), (0.55, 987.77), (1.1, 1174.66)], 3.6, 0.14, 0.55, 0.05),
    "NivviReliefPiano.wav": ([(0.0, 523.25), (1.1, 783.99)], 4.2, 0.18, 0.95, 0.04),
    "NivviReliefHush.wav": ([(0.0, 329.63), (1.2, 392.00)], 5.0, 0.14, 1.2, 0.14),
}

for name, (freqs, amp, speed) in sirens.items():
    write_siren(sounds_dir / name, 8, freqs, amp, speed)
for name, args in reliefs.items():
    write_relief(sounds_dir / name, *args)
write_sensor(sounds_dir / "NivviSensor.wav")
write_wav(sounds_dir / "NivviHold.wav", struct.pack("<h", 0) * int(rate * 2))

for wav in sounds_dir.glob("*.wav"):
    target = payload / wav.name
    target.write_bytes(wav.read_bytes())

print("Wrote 5 sirens, 5 relief chimes and 1 sensor advisory")
