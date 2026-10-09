import importlib.util
import os
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

os.environ["NIVVI_TESTING"] = "1"
os.environ["NIVVI_CHARGER_SECRET"] = "test-charger-secret"
spec = importlib.util.spec_from_file_location("relay", Path(__file__).parents[1] / "app.py")
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


@pytest.fixture
def client(tmp_path):
    relay.DB = str(tmp_path / "test.sqlite")
    relay.OUTBOX.clear()
    with TestClient(relay.app) as value:
        yield value


def account(client, email):
    credentials = {"email": email, "password": "test-password-123"}
    assert client.post("/auth/register", json=credentials).status_code == 200
    code = relay.OUTBOX[-1][2]
    assert client.post("/auth/verify", json={**credentials, "code": code}).status_code == 200
    result = client.post("/auth/login", json=credentials).json()
    return {"Authorization": "Bearer " + result["token"]}


def test_charger_stays_inside_the_family_that_claimed_it(client):
    owner = account(client, "charger-owner@example.com")
    other = account(client, "other-parent@example.com")
    family = client.post("/families", headers=owner, json={"label": "Home"}).json()["id"]
    stranger = client.post("/families", headers=other, json={"label": "Other"}).json()["id"]
    headers = {"X-Nivvi-Charger": "test-charger-secret"}
    reading = {"serial": "11298", "heart_rate": 83, "heart_state": 0, "oxygen": 97, "oxygen_state": 0, "temperature": 25.8, "battery": 81}
    assert client.post("/internal/charger", headers=headers, json=reading).json()["skipped"] == "unclaimed"
    assert client.post(f"/families/{family}/charger-claim", headers=owner).status_code == 200
    assert client.post(f"/families/{stranger}/charger-claim", headers=other).status_code == 200
    assert client.post("/internal/charger", headers=headers, json=reading).json()["skipped"] == "ambiguous"
    relay_db = __import__("sqlite3").connect(relay.DB)
    relay_db.execute("DELETE FROM charger_claims WHERE family=?", (stranger,))
    relay_db.commit()
    posted = client.post("/internal/charger", headers=headers, json=reading)
    assert posted.status_code == 200 and posted.json()["ok"] is True
    snap = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert snap["source"] == "charger" and snap["heart_rate"] == 83 and snap["host_relation"] == "Charger"
    assert client.get(f"/families/{stranger}/latest", headers=other).json()["snapshot"] is None
    assert client.post("/internal/charger", headers=headers, json={"serial": "99999", "heart_rate": 80, "heart_state": 0}).json()["skipped"] == "unclaimed"
    again = client.post("/internal/charger", headers=headers, json=reading)
    assert again.json().get("skipped") != "unclaimed"
    assert client.get(f"/families/{stranger}/latest", headers=other).json()["snapshot"] is None


def test_charger_pushes_the_lock_screen(client):
    relay.ACTIVITY_PUSHES.clear()
    relay.ACTIVITY_GATE.clear()
    owner = account(client, "charger-lock@example.com")
    family = client.post("/families", headers=owner, json={"label": "Home"}).json()["id"]
    secret = "e" * 32
    token = "f" * 64
    assert client.post("/live-activity/token", json={"secret": secret, "token": token, "kind": "watcher"}).status_code == 200
    now = __import__("time").time()
    phone = {
        "captured": now - 30,
        "heart_rate": 80,
        "heart_rate_at": now - 30,
        "oxygen": 97,
        "source": "phone",
        "alarm": "none",
        "connection": "receiving",
        "activity_secret": secret,
        "seq": 1,
    }
    assert client.put(f"/families/{family}/latest", headers=owner, json=phone).status_code == 200
    relay.ACTIVITY_PUSHES.clear()
    assert client.post(f"/families/{family}/charger-claim", headers=owner).status_code == 200
    headers = {"X-Nivvi-Charger": "test-charger-secret"}
    reading = {"serial": "11298", "heart_rate": 91, "heart_state": 0, "oxygen": 98, "oxygen_state": 0, "temperature": 31.5, "battery": 66, "sleep": True, "sleep_sec": 194}
    posted = client.post("/internal/charger", headers=headers, json=reading)
    assert posted.status_code == 200 and posted.json()["ok"] is True
    assert relay.ACTIVITY_PUSHES, "a charger reading must update the lock screen"
    assert relay.ACTIVITY_PUSHES[-1]["token"] == token
    assert "91" in relay.ACTIVITY_PUSHES[-1]["state"]["heartRate"]
    assert relay.ACTIVITY_PUSHES[-1]["state"]["sleep"] == "Asleep · 3 min"
    snap = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert snap["activity_secret"] == secret and snap["source"] == "charger" and snap["sleep"] == "Asleep · 3 min"


def test_charger_takes_the_shared_reading_while_the_phone_stays_connected(client):
    relay.ACTIVITY_PUSHES.clear()
    relay.ACTIVITY_GATE.clear()
    owner = account(client, "both-connected@example.com")
    family = client.post("/families", headers=owner, json={"label": "Home"}).json()["id"]
    secret = "a" * 32
    token = "b" * 64
    assert client.post("/live-activity/token", json={"secret": secret, "token": token, "kind": "watcher"}).status_code == 200
    now = __import__("time").time()
    phone = {
        "captured": now,
        "heart_rate": 80,
        "heart_rate_at": now,
        "oxygen": 97,
        "source": "phone",
        "alarm": "none",
        "connection": "receiving",
        "activity_secret": secret,
        "seq": 1,
        "stream_id": "phone-1",
    }
    assert client.put(f"/families/{family}/latest", headers=owner, json=phone).status_code == 200
    assert client.post(f"/families/{family}/charger-claim", headers=owner).status_code == 200
    headers = {"X-Nivvi-Charger": "test-charger-secret"}
    posted = client.post("/internal/charger", headers=headers, json={"serial": "11298", "heart_rate": 91, "heart_state": 0, "oxygen": 98, "oxygen_state": 0})
    assert posted.json()["ok"] is True and posted.json().get("skipped") != "phone"
    snap = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert snap["source"] == "charger" and snap["heart_rate"] == 91
    phone["heart_rate"] = 70
    phone["seq"] = 2
    phone["captured"] = now + 1
    phone["heart_rate_at"] = now + 1
    held = client.put(f"/families/{family}/latest", headers=owner, json=phone)
    assert held.status_code == 200 and held.json().get("skipped") == "charger"
    assert client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]["heart_rate"] == 91
    relay.ACTIVITY_PUSHES.clear()
    direct = client.post("/live-activity/publish", json={
        "secret": secret, "seq": 9, "measured_at": now + 1, "heart_rate": "70 bpm", "oxygen": "97%",
        "connection": "Connected", "session": "Home", "title": "Home",
    })
    assert direct.status_code == 200 and direct.json().get("skipped") == "charger"
    assert relay.ACTIVITY_PUSHES == []


def test_charger_keeps_history_while_the_phone_is_off(client):
    owner = account(client, "history-off@example.com")
    family = client.post("/families", headers=owner, json={"label": "Home"}).json()["id"]
    assert client.post(f"/families/{family}/charger-claim", headers=owner).status_code == 200
    headers = {"X-Nivvi-Charger": "test-charger-secret"}
    reading = {"serial": "11298", "heart_rate": 88, "heart_state": 0, "oxygen": 99, "oxygen_state": 0, "temperature": 32.1}
    assert client.post("/internal/charger", headers=headers, json=reading).status_code == 200
    first = client.get(f"/families/{family}/history", headers=owner).json()["points"]
    assert len(first) == 1 and first[0]["hr"] == 88
    import sqlite3
    store = sqlite3.connect(relay.DB)
    store.execute("UPDATE reading_log SET t=t-40 WHERE family=?", (family,))
    store.commit()
    reading["heart_rate"] = 91
    assert client.post("/internal/charger", headers=headers, json=reading).status_code == 200
    second = client.get(f"/families/{family}/history", headers=owner).json()["points"]
    assert [point["hr"] for point in second] == [88, 91]
    now = 2_000.0
    line, sec, held = relay.charger_sleep(True, 300, {}, now)
    assert line == "Asleep · 5 min" and sec == 300 and held == now
    kept, same, still = relay.charger_sleep(None, None, {"sleep": line, "sleep_sec": sec, "sleep_held": now}, now + 20)
    assert kept == "Asleep · 5 min" and same == 300 and still == now
    running, stuck, anchor = relay.charger_sleep(True, 300, {"sleep": line, "sleep_sec": sec, "sleep_held": now}, now + 65)
    assert stuck == 300 and anchor == now and "6 min" in running
    cleared, gone, dropped = relay.charger_sleep(False, 0, {"sleep": line, "sleep_sec": sec, "sleep_held": now}, now + 91)
    assert cleared == "" and gone is None and dropped is None
    now = 1_000.0
    limits = {"high_enabled": 1, "low_enabled": 1, "high_threshold": 100, "low_threshold": 60, "duration_seconds": 15}
    alarm, pending, since, clear = relay.charger_alarm(130, limits, {}, now)
    assert alarm == "none" and pending == "high" and since == now and clear is None
    held = {"source": "charger", "alarm": "none", "alarm_pending": "high", "alarm_since": now - 15}
    alarm, pending, since, clear = relay.charger_alarm(130, limits, held, now)
    assert alarm == "high" and clear is None
    still_high = {"source": "charger", "alarm": "high", "alarm_pending": "high", "alarm_since": now - 30}
    alarm, *_ = relay.charger_alarm(99, limits, still_high, now)
    assert alarm == "high"
    alarm, pending, since, clear = relay.charger_alarm(92, limits, still_high, now)
    assert alarm == "high" and clear == now
    cleared = dict(still_high)
    cleared["alarm_clear_since"] = now - 15
    alarm, *_ = relay.charger_alarm(92, limits, cleared, now)
    assert alarm == "none"
    alarm, pending, since, clear = relay.charger_alarm(50, limits, {"source": "charger"}, now)
    assert alarm == "none" and pending == "low"
    alarm, pending, since, clear = relay.charger_alarm(90, {"high_enabled": 0, "low_enabled": 0, "high_threshold": 100, "low_threshold": 60, "duration_seconds": 15}, {}, now)
    assert alarm == "none" and pending is None


def test_charger_reading_alerts_watching_phones(client):
    owner = account(client, "charger-alarm@example.com")
    family = client.post("/families", headers=owner, json={"label": "Home"}).json()["id"]
    assert client.put(f"/families/{family}/profile", headers=owner, json={
        "child_name": "A", "high_enabled": True, "high_threshold": 100, "duration_seconds": 15,
    }).status_code == 200
    assert client.post(f"/families/{family}/charger-claim", headers=owner).status_code == 200
    headers = {"X-Nivvi-Charger": "test-charger-secret"}
    reading = {"serial": "11298", "heart_rate": 130, "heart_state": 0, "oxygen": 98, "oxygen_state": 0}
    first = client.post("/internal/charger", headers=headers, json=reading)
    assert first.status_code == 200
    assert client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]["alarm"] == "none"
    import sqlite3
    store = sqlite3.connect(relay.DB)
    payload = store.execute("SELECT payload FROM latest WHERE family=?", (family,)).fetchone()[0]
    body = __import__("json").loads(payload)
    body["alarm_since"] = body["alarm_since"] - 15
    store.execute("UPDATE latest SET payload=? WHERE family=?", (__import__("json").dumps(body), family))
    store.commit()
    second = client.post("/internal/charger", headers=headers, json=reading)
    assert second.status_code == 200
    snap = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert snap["alarm"] == "high" and snap["source"] == "charger"
    kind = store.execute("SELECT kind FROM pushes WHERE family=?", (family,)).fetchone()[0]
    assert kind == "attention"
