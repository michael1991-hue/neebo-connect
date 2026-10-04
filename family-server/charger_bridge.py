"""Listen to the Neebo charger and post a real pulse to the family server.

Run on the Droplet, after NIVVI_CHARGER_SECRET is set and the family service is rebuilt:

    python3 charger_bridge.py
"""
import json
import os
import socket
import time
import urllib.error
import urllib.request

MQTT_HOST = os.environ.get("NIVVI_MQTT_HOST", "127.0.0.1")
MQTT_PORT = int(os.environ.get("NIVVI_MQTT_PORT", "1883"))
FAMILY_URL = os.environ.get("NIVVI_FAMILY_CHARGER_URL", "http://127.0.0.1:8000/internal/charger")
SECRET = os.environ.get("NIVVI_CHARGER_SECRET", "")
TOPIC = "/nbo_charger/#"


def encode_length(n):
    out = bytearray()
    while True:
        digit = n % 128
        n //= 128
        if n:
            digit |= 0x80
        out.append(digit)
        if not n:
            return bytes(out)


def encode_text(value):
    raw = value.encode()
    return len(raw).to_bytes(2, "big") + raw


def connect_packet():
    body = encode_text("MQTT") + bytes([4, 2, 0, 60]) + encode_text("nivvi-charger-bridge")
    return bytes([0x10]) + encode_length(len(body)) + body


def subscribe_packet():
    body = (1).to_bytes(2, "big") + encode_text(TOPIC) + bytes([0])
    return bytes([0x82]) + encode_length(len(body)) + body


def read_exact(sock, count):
    buf = b""
    while len(buf) < count:
        chunk = sock.recv(count - len(buf))
        if not chunk:
            raise ConnectionError("MQTT closed")
        buf += chunk
    return buf


def read_packet(sock):
    header = read_exact(sock, 1)[0]
    value = 0
    shift = 0
    while True:
        digit = read_exact(sock, 1)[0]
        value += (digit & 0x7F) << shift
        if not digit & 0x80:
            break
        shift += 7
    return header, read_exact(sock, value)


def payload_of(packet):
    if len(packet) < 2:
        return None
    size = int.from_bytes(packet[:2], "big")
    start = 2 + size
    return packet[start:] if len(packet) >= start else None


def reading_from(raw):
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    vitals = {}
    for item in data.get("vitals") or []:
        if isinstance(item, dict):
            vitals.update(item)
    heart = vitals.get("hr") or {}
    oxygen = vitals.get("ox") or {}
    temp = vitals.get("temp") or {}
    if not isinstance(heart, dict):
        return None
    rate = heart.get("value")
    if not isinstance(rate, (int, float)) or not 1 <= rate <= 250 or heart.get("state") not in (None, 0):
        return None
    body = {
        "serial": str(data.get("serial_number") or ""),
        "heart_rate": rate,
        "heart_state": heart.get("state"),
        "battery": data.get("battery") if isinstance(data.get("battery"), int) else None,
    }
    if isinstance(oxygen, dict):
        body["oxygen"] = oxygen.get("value")
        body["oxygen_state"] = oxygen.get("state")
    if isinstance(temp, dict):
        body["temperature"] = temp.get("value")
    return body


def post(body):
    if not SECRET:
        raise SystemExit("Set NIVVI_CHARGER_SECRET before starting the bridge.")
    req = urllib.request.Request(
        FAMILY_URL,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "X-Nivvi-Charger": SECRET},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as reply:
            print(reply.read().decode()[:160], flush=True)
    except urllib.error.HTTPError as error:
        print(f"Post failed: {error.code} {error.read().decode()[:180]}", flush=True)


def listen():
    sock = socket.create_connection((MQTT_HOST, MQTT_PORT), timeout=10)
    sock.settimeout(20)
    sock.sendall(connect_packet())
    kind, _ = read_packet(sock)
    if kind != 0x20:
        raise SystemExit("MQTT did not accept the connection")
    sock.sendall(subscribe_packet())
    print(f"Listening on {MQTT_HOST}:{MQTT_PORT}", flush=True)
    while True:
        try:
            kind, packet = read_packet(sock)
        except socket.timeout:
            sock.sendall(b"\xc0\x00")
            continue
        if kind & 0xF0 != 0x30:
            continue
        raw = payload_of(packet)
        if not raw:
            continue
        body = reading_from(raw)
        if body is None:
            continue
        try:
            post(body)
        except Exception as error:
            print(f"Post failed: {error}", flush=True)


if __name__ == "__main__":
    while True:
        try:
            listen()
        except ConnectionError as error:
            print(f"MQTT closed: {error}. Retrying.", flush=True)
            time.sleep(2)
