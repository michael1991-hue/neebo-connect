"""Create the bundled 8-second PCM siren for local notifications and foreground tests."""
from pathlib import Path
import math
import struct
import wave

out = Path('build/Payload/Nivvi.app/NivviSiren.wav')
out.parent.mkdir(parents=True, exist_ok=True)
rate, seconds = 22050, 8
samples = bytearray()
phase = 0.0
for i in range(rate * seconds):
    t = i / rate
    frequency = 760 if int(t * 2) % 2 == 0 else 1100
    phase += 2 * math.pi * frequency / rate
    # Brief fades at the file boundaries prevent playback clicks; volume stays user-controlled.
    envelope = min(1.0, t / 0.02, (seconds - t) / 0.02)
    value = int(0.8 * 32767 * max(0, envelope) * math.sin(phase))
    samples.extend(struct.pack('<h', value))
with wave.open(str(out), 'wb') as sound:
    sound.setnchannels(1); sound.setsampwidth(2); sound.setframerate(rate)
    sound.writeframes(samples)
with wave.open(str(out), 'rb') as sound:
    assert sound.getnframes() / sound.getframerate() == 8
    assert sound.getnchannels() == 1 and sound.getsampwidth() == 2
print('Bundled 8-second PCM notification siren')
