"""Create the bundled alarm and relief PCM sounds."""
from pathlib import Path
import math
import struct
import wave

out_dir = Path('build/Payload/Nivvi.app')
out_dir.mkdir(parents=True, exist_ok=True)
rate = 22050

def write_tone(path, seconds, frequencies, amplitude):
    samples = bytearray()
    phase = 0.0
    for i in range(int(rate * seconds)):
        t = i / rate
        frequency = frequencies[int(t * 2) % len(frequencies)]
        phase += 2 * math.pi * frequency / rate
        # Brief fades at the file boundaries prevent playback clicks.
        envelope = min(1.0, t / 0.02, (seconds - t) / 0.02)
        value = int(amplitude * 32767 * max(0, envelope) * math.sin(phase))
        samples.extend(struct.pack('<h', value))
    with wave.open(str(path), 'wb') as sound:
        sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(rate)
        sound.writeframes(samples)
    with wave.open(str(path), 'rb') as sound:
        assert sound.getnframes() == int(rate * seconds)
        assert sound.getnchannels() == 1 and sound.getsampwidth() == 2

write_tone(out_dir / 'NivviSiren.wav', 8, [760, 1100], 0.8)
# Soft, overlapping bell partials with slow attacks and long natural decays.
# No alternating alarm pitches, sharp transients or repeating playback.
def write_relief(path):
    seconds = 4.5
    notes = [(0.0, 523.25), (0.85, 659.25), (1.7, 783.99)]
    samples = bytearray()
    peak = 0
    for i in range(int(rate * seconds)):
        t = i / rate
        value = 0.0
        for onset, frequency in notes:
            age = t - onset
            if age < 0:
                continue
            envelope = (1 - math.exp(-age / 0.08)) * math.exp(-age / 0.85)
            bell = (math.sin(2 * math.pi * frequency * age)
                    + 0.20 * math.sin(2 * math.pi * frequency * 2.01 * age)
                    + 0.06 * math.sin(2 * math.pi * frequency * 3.98 * age))
            value += 0.16 * envelope * bell
        value *= min(1.0, max(0.0, (seconds - t) / 0.6))
        sample = int(value * 32767)
        assert -32768 <= sample <= 32767
        peak = max(peak, abs(sample))
        samples.extend(struct.pack('<h', sample))
    assert 0 < peak < int(32767 * 0.35)
    with wave.open(str(path), 'wb') as sound:
        sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(rate)
        sound.writeframes(samples)
    with wave.open(str(path), 'rb') as sound:
        assert sound.getnframes() == int(rate * seconds)

write_relief(out_dir / 'NivviRelief.wav')
print('Bundled alarm siren and soft recovery bell chime')
