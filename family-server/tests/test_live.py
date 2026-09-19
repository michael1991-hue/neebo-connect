import os
import time
from pathlib import Path
import importlib.util
import pytest
from fastapi.testclient import TestClient

os.environ["NIVVI_TESTING"] = "1"
spec = importlib.util.spec_from_file_location("relay", Path(__file__).parents[1] / "app.py")
relay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(relay)


@pytest.fixture
def client(tmp_path):
    relay.DB = str(tmp_path / "test.sqlite")
    relay.OUTBOX.clear()
    relay.ACTIVITY_PUSHES.clear()
    with TestClient(relay.app) as value:
        yield value


def account(client, email):
    credentials = {"email": email, "password": "test-password-123"}
    assert client.post("/auth/register", json=credentials).status_code == 200
    code = relay.OUTBOX[-1][2]
    assert client.post("/auth/verify", json={**credentials, "code": code}).status_code == 200
    result = client.post("/auth/login", json=credentials).json()
    return {"Authorization": "Bearer " + result["token"]}, result["token"], result["user_id"]


def snapshot(**extra):
    body = {"captured": time.time(), "heart_rate": 101, "oxygen": 98, "source": "test", "alarm": "none", "connection": "receiving", "stream_id": "stream-a", "seq": 1}
    body.update(extra)
    return body


def test_live_socket_snapshot_then_event_and_seq(client):
    owner, owner_token, _ = account(client, "owner@example.com")
    reader, reader_token, reader_id = account(client, "reader@example.com")
    family = client.post("/families", headers=owner, json={"label": "Live"}).json()["id"]
    code = client.post(f"/families/{family}/invites", headers=owner, json={"email": "reader@example.com"}).json()["code"]
    assert client.post("/invites/accept", headers=reader, json={"code": code}).status_code == 200
    now = time.time()
    first = snapshot(captured=now, heart_rate=110, heart_rate_at=now, oxygen=None, seq=1)
    assert client.put(f"/families/{family}/latest", headers=owner, json=first).status_code == 200
    with client.websocket_connect(f"/families/{family}/live", headers=reader) as ws:
        opening = ws.receive_json()
        assert opening["type"] == "snapshot"
        assert opening.get("snapshot", opening).get("heart_rate") == 110
        later = now + 0.2
        second = snapshot(captured=later, heart_rate=110, heart_rate_at=later, oxygen=97, oxygen_at=later, seq=2)
        assert client.put(f"/families/{family}/latest", headers=owner, json=second).status_code == 200
        event = ws.receive_json()
        if event.get("type") == "ping":
            event = ws.receive_json()
        assert event["type"] == "live"
        assert event["seq"] == 2
        assert event["heart_rate"] == 110
        assert event["oxygen"] == 97
        assert event["heart_rate_at"] >= event["oxygen_at"] - 1
    stale = snapshot(captured=later + 0.1, seq=2)
    assert client.put(f"/families/{family}/latest", headers=owner, json=stale).status_code == 409
    remote = client.get(f"/families/{family}/latest", headers=reader).json()
    assert remote["heart_rate_fresh"] is True
    assert remote["oxygen_fresh"] is True


def test_oxygen_does_not_refresh_stale_heart_rate(client):
    owner, _, _ = account(client, "split@example.com")
    family = client.post("/families", headers=owner, json={"label": "Split"}).json()["id"]
    now = time.time()
    assert client.put(f"/families/{family}/latest", headers=owner, json=snapshot(captured=now, heart_rate=118, heart_rate_at=now - 20, oxygen=None, seq=1)).status_code == 200
    o2 = snapshot(captured=now, heart_rate=None, oxygen=96, oxygen_at=now, seq=2)
    assert client.put(f"/families/{family}/latest", headers=owner, json=o2).status_code == 200
    data = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert data["heart_rate"] == 118
    assert data["oxygen"] == 96
    assert data["heart_rate_at"] < data["oxygen_at"]


def test_live_activity_seq_and_token(client):
    secret = "a" * 32
    token = "b" * 64
    assert client.post("/live-activity/token", json={"secret": secret, "token": token}).status_code == 200
    now = time.time()
    first = {
        "secret": secret,
        "seq": 1,
        "measured_at": now,
        "heart_rate": "104 bpm",
        "oxygen": "98%",
        "connection": "Shared over Wi‑Fi",
        "session": "Jane",
        "title": "Jane",
    }
    assert client.post("/live-activity/publish", json=first).status_code == 200
    assert relay.ACTIVITY_PUSHES[-1]["token"] == token
    assert relay.ACTIVITY_PUSHES[-1]["state"]["heartRate"] == "104 bpm"
    assert relay.ACTIVITY_PUSHES[-1]["state"]["seq"] == 1
    older = dict(first)
    older["heart_rate"] = "90 bpm"
    older["measured_at"] = now + 0.2
    assert client.post("/live-activity/publish", json=older).status_code == 409
    newer = dict(first)
    newer["seq"] = 2
    newer["heart_rate"] = "106 bpm"
    newer["measured_at"] = now + 0.3
    assert client.post("/live-activity/publish", json=newer).status_code == 200
    assert relay.ACTIVITY_PUSHES[-1]["state"]["heartRate"] == "106 bpm"


def test_family_latest_fans_out_activity_push(client):
    owner, _, _ = account(client, "host@example.com")
    family = client.post("/families", headers=owner, json={"label": "Push"}).json()["id"]
    secret = "c" * 32
    token = "d" * 64
    assert client.post("/live-activity/token", json={"secret": secret, "token": token}).status_code == 200
    now = time.time()
    body = snapshot(captured=now, heart_rate=112, heart_rate_at=now, oxygen=97, oxygen_at=now, seq=1)
    body["activity_secret"] = secret
    assert client.put(f"/families/{family}/latest", headers=owner, json=body).status_code == 200
    assert relay.ACTIVITY_PUSHES[-1]["token"] == token
    assert "112" in relay.ACTIVITY_PUSHES[-1]["state"]["heartRate"]


def test_carer_can_publish_watcher_cannot(client):
    owner, _, _ = account(client, "parents@example.com")
    carer, _, _ = account(client, "nan@example.com")
    watcher, _, _ = account(client, "aunt@example.com")
    family = client.post("/families", headers=owner, json={"label": "Jane"}).json()["id"]
    carer_code = client.post(f"/families/{family}/invites", headers=owner, json={"email": "nan@example.com", "role": "carer"}).json()["code"]
    watch_code = client.post(f"/families/{family}/invites", headers=owner, json={"email": "aunt@example.com", "role": "watcher"}).json()["code"]
    assert client.post("/invites/accept", headers=carer, json={"code": carer_code}).status_code == 200
    assert client.post("/invites/accept", headers=watcher, json={"code": watch_code}).status_code == 200
    now = time.time()
    body = snapshot(captured=now, heart_rate=108, heart_rate_at=now, seq=1, place="carer")
    assert client.put(f"/families/{family}/latest", headers=carer, json=body).status_code == 200
    assert client.put(f"/families/{family}/latest", headers=watcher, json=snapshot(captured=now + 0.2, seq=2)).status_code == 404
    listed = client.get("/families", headers=carer).json()
    assert listed[0]["role"] == "carer"
