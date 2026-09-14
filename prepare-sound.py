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
# A short descending two-note confirmation used only after a fresh in-range reading.
write_tone(out_dir / 'NivviRelief.wav', 1.2, [1046, 784], 0.55)
print('Bundled alarm siren and heart-rate-normal relief sound')
