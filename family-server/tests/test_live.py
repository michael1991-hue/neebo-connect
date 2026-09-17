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


def test_revoke_closes_live_socket(client):
    owner, _, _ = account(client, "revoke-owner@example.com")
    reader, _, reader_id = account(client, "revoke-reader@example.com")
    family = client.post("/families", headers=owner, json={"label": "Revoke"}).json()["id"]
    code = client.post(f"/families/{family}/invites", headers=owner, json={"email": "revoke-reader@example.com"}).json()["code"]
    assert client.post("/invites/accept", headers=reader, json={"code": code}).status_code == 200
    with client.websocket_connect(f"/families/{family}/live", headers=reader) as ws:
        ws.receive_json()
        assert client.delete(f"/families/{family}/members/{reader_id}", headers=owner).status_code == 200
        payload = ws.receive_json()
        if payload.get("type") == "ping":
            payload = ws.receive_json()
        assert payload["type"] == "revoked"
    assert client.get(f"/families/{family}/latest", headers=reader).status_code == 404


def test_same_value_updates_timestamp(client):
    owner, _, _ = account(client, "same@example.com")
    family = client.post("/families", headers=owner, json={"label": "Same"}).json()["id"]
    first_at = time.time() - 2
    later = time.time()
    assert client.put(
        f"/families/{family}/latest",
        headers=owner,
        json=snapshot(captured=later, heart_rate=104, heart_rate_at=first_at, oxygen=None, seq=1),
    ).status_code == 200
    assert client.put(
        f"/families/{family}/latest",
        headers=owner,
        json=snapshot(captured=later, heart_rate=104, heart_rate_at=later, oxygen=None, seq=2),
    ).status_code == 200
    data = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert data["heart_rate"] == 104
    assert data["heart_rate_at"] == later


def test_out_of_order_stream_and_unauthorised_socket(client):
    owner, _, _ = account(client, "order@example.com")
    outsider, _, _ = account(client, "outsider@example.com")
    family = client.post("/families", headers=owner, json={"label": "Order"}).json()["id"]
    now = time.time()
    assert client.put(f"/families/{family}/latest", headers=owner, json=snapshot(captured=now, seq=3, stream_id="stream-a")).status_code == 200
    assert client.put(f"/families/{family}/latest", headers=owner, json=snapshot(captured=now, seq=2, stream_id="stream-a")).status_code == 409
    assert client.put(f"/families/{family}/latest", headers=owner, json=snapshot(captured=now, seq=1, stream_id="stream-b")).status_code == 200
    with client.websocket_connect(f"/families/{family}/live", headers=outsider) as ws:
        payload = ws.receive_json()
        assert payload["type"] == "revoked"


def test_missing_heart_rate_does_not_recover_alarm(client):
    owner, _, _ = account(client, "gap@example.com")
    family = client.post("/families", headers=owner, json={"label": "Gap"}).json()["id"]
    now = time.time()
    assert client.put(f"/families/{family}/latest", headers=owner, json=snapshot(captured=now, alarm="high", heart_rate=160, seq=1)).status_code == 200
    assert client.put(f"/families/{family}/latest", headers=owner, json=snapshot(captured=now, alarm="none", heart_rate=None, seq=2)).status_code == 200
    data = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert data["alarm"] == "high"
    assert data["heart_rate"] == 160
