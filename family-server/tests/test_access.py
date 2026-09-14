import importlib.util
import os
import time
from pathlib import Path

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
    assert client.post("/auth/login", json=credentials).status_code == 401
    code = relay.OUTBOX[-1][2]
    assert client.post("/auth/verify", json={**credentials, "code": code}).status_code == 200
    result = client.post("/auth/login", json=credentials).json()
    return {"Authorization": "Bearer " + result["token"]}, result["user_id"]


def group(client, owner):
    return client.post("/families", headers=owner, json={"label": "Test family"}).json()["id"]


def invitation(client, owner, family, address):
    return client.post(f"/families/{family}/invites", headers=owner, json={"email": address}).json()["code"]


def snapshot(alarm="none", captured=None, hr=100):
    return {"captured": captured or time.time(), "heart_rate": hr, "oxygen": 98, "source": "test", "alarm": alarm, "connection": "receiving"}


def test_access_isolation_invites_and_revocation(client):
    owner, _ = account(client, "owner@example.com")
    reader, reader_id = account(client, "reader@example.com")
    outsider, _ = account(client, "other@example.com")
    family = group(client, owner)
    path = f"/families/{family}"
    assert client.get(path + "/latest").status_code == 401
    assert client.get(path + "/latest", headers=outsider).status_code == 404
    assert client.get("/families", headers=outsider).json() == []
    code = invitation(client, owner, family, "reader@example.com")
    assert client.post("/invites/accept", headers=outsider, json={"code": code}).status_code == 400
    assert client.post("/invites/accept", headers=reader, json={"code": code}).status_code == 200
    assert client.post("/invites/accept", headers=reader, json={"code": code}).status_code == 400
    assert client.put(path + "/latest", headers=reader, json=snapshot()).status_code == 404
    assert client.delete(path, headers=reader).status_code == 404
    assert client.post(path + "/invites", headers=reader, json={"email": "other@example.com"}).status_code == 404
    assert client.put(path + "/latest", headers=owner, json=snapshot()).status_code == 200
    assert client.get(path + "/latest", headers=reader).json()["snapshot"]["heart_rate"] == 100
    assert client.delete(path + "/members/" + reader_id, headers=owner).status_code == 200
    assert client.get(path + "/latest", headers=reader).status_code == 404


def test_stale_ordering_and_recovery(client):
    owner, _ = account(client, "owner@example.com")
    family = group(client, owner)
    path = f"/families/{family}/latest"
    assert client.put(path, headers=owner, json=snapshot(captured=time.time()-60)).status_code == 400
    assert client.put(path, headers=owner, json=snapshot(captured=time.time()+60)).status_code == 400
    now = time.time()
    assert client.put(path, headers=owner, json=snapshot("high", now)).status_code == 200
    assert client.put(path, headers=owner, json=snapshot(captured=now-1)).status_code == 409
    assert client.put(path, headers=owner, json=snapshot(hr=None)).status_code == 200
    with relay.db() as c:
        assert c.execute("SELECT kind FROM pushes").fetchone()[0] == "attention"
        data = snapshot(captured=now-40)
        import json
        c.execute("UPDATE latest SET payload=?", (json.dumps(data),))
    assert client.get(path, headers=owner).json()["fresh"] is False
    assert client.put(path, headers=owner, json=snapshot("sensor")).status_code == 200
    with relay.db() as c:
        assert c.execute("SELECT kind FROM pushes").fetchone()[0] == "sensor"


def test_expired_invites_and_account_delete(client):
    owner, owner_id = account(client, "owner@example.com")
    reader, _ = account(client, "reader@example.com")
    family = group(client, owner)
    code = invitation(client, owner, family, "reader@example.com")
    with relay.db() as c:
        c.execute("UPDATE invites SET expires=0")
    assert client.post("/invites/accept", headers=reader, json={"code": code}).status_code == 400
    assert client.put(f"/families/{family}/latest", headers=owner, json=snapshot()).status_code == 200
    assert client.delete("/account", headers=owner).status_code == 200
    assert client.get("/families", headers=owner).status_code == 401
    with relay.db() as c:
        for table in ("families", "latest", "invites", "members", "sessions"):
            if table == "sessions":
                assert c.execute("SELECT count(*) FROM sessions WHERE user_id=?", (owner_id,)).fetchone()[0] == 0
            else:
                assert c.execute("SELECT count(*) FROM " + table).fetchone()[0] == 0


def test_password_reset_revokes_sessions_and_notification_tokens(client):
    owner, _ = account(client, "owner@example.com")
    token = "a" * 64
    assert client.put("/devices", headers=owner, json={"token": token}).status_code == 200
    assert client.post("/auth/reset-request", json={"email": "owner@example.com"}).status_code == 200
    code = relay.OUTBOX[-1][2]
    result = client.post("/auth/reset", json={"email": "owner@example.com", "code": code, "password": "changed-password-123"})
    assert result.status_code == 200
    assert client.get("/families", headers=owner).status_code == 401
    with relay.db() as c:
        assert c.execute("SELECT count(*) FROM devices").fetchone()[0] == 0


def test_auth_rate_limit(client):
    for _ in range(30):
        client.post("/auth/login", json={"email": "missing@example.com", "password": "incorrect-password"})
    assert client.post("/auth/login", json={"email": "missing@example.com", "password": "incorrect-password"}).status_code == 429


def test_verification_binds_mailbox_owners_password(client):
    client.post("/auth/register", json={"email": "owner@example.com", "password": "attacker-password"})
    code = relay.OUTBOX[-1][2]
    assert client.post("/auth/verify", json={"email": "owner@example.com", "code": code, "password": "owners-new-password"}).status_code == 200
    assert client.post("/auth/login", json={"email": "owner@example.com", "password": "attacker-password"}).status_code == 401
    assert client.post("/auth/login", json={"email": "owner@example.com", "password": "owners-new-password"}).status_code == 200


def test_sensor_recovery_is_not_a_heart_rate_recovery(client):
    owner, _ = account(client, "owner@example.com")
    family = group(client, owner)
    path = f"/families/{family}/latest"
    assert client.put(path, headers=owner, json=snapshot("sensor")).status_code == 200
    assert client.put(path, headers=owner, json=snapshot("none")).status_code == 200
    with relay.db() as c:
        assert c.execute("SELECT kind FROM pushes").fetchone()[0] == "sensor-restored"
    assert client.put(path, headers=owner, json=snapshot("high")).status_code == 200
    assert client.put(path, headers=owner, json=snapshot("none", hr=None)).status_code == 200
    assert client.get(path, headers=owner).json()["snapshot"]["alarm"] == "high"
    assert client.put(path, headers=owner, json=snapshot("none")).status_code == 200
    with relay.db() as c:
        assert c.execute("SELECT kind FROM pushes").fetchone()[0] == "recovery"
