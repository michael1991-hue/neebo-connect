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
    assert client.put(path + "/latest", headers=reader, json=snapshot()).status_code == 200
    assert client.delete(path, headers=reader).status_code == 404
    assert client.post(path + "/invites", headers=reader, json={"email": "other@example.com"}).status_code == 404
    assert client.put(path + "/latest", headers=owner, json=snapshot()).status_code == 200
    packed = snapshot()
    packed["history"] = [{"t": packed["captured"] - 60, "hr": 94, "o2": 97}]
    assert client.put(path + "/latest", headers=owner, json=packed).status_code == 200
    remote = client.get(path + "/latest", headers=reader).json()["snapshot"]
    assert remote["heart_rate"] == 100
    assert remote["history"][0]["hr"] == 94
    assert client.delete(path + "/members/" + reader_id, headers=owner).status_code == 200
    assert client.get(path + "/latest", headers=reader).status_code == 404


def test_stale_ordering_and_recovery(client):
    owner, _ = account(client, "owner@example.com")
    family = group(client, owner)
    path = f"/families/{family}/latest"
    assert client.put(path, headers=owner, json=snapshot(captured=time.time()-120)).status_code == 400
    assert client.put(path, headers=owner, json=snapshot(captured=time.time()+60)).status_code == 400
    now = time.time()
    assert client.put(path, headers=owner, json=snapshot("high", now)).status_code == 200
    assert client.put(path, headers=owner, json=snapshot(captured=now-1)).status_code == 409
    assert client.put(path, headers=owner, json=snapshot(hr=None)).status_code == 200
    with relay.db() as c:
        assert c.execute("SELECT kind FROM pushes").fetchone()[0] == "attention"
        data = snapshot(captured=now-50)
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


def test_invite_stores_family_relation(client):
    owner, _ = account(client, "owner@example.com")
    nan, _ = account(client, "nan@example.com")
    family = group(client, owner)
    code = client.post(
        f"/families/{family}/invites",
        headers=owner,
        json={"email": "nan@example.com", "relation": "nan"},
    ).json()["code"]
    assert client.post("/invites/accept", headers=nan, json={"code": code}).status_code == 200
    people = client.get(f"/families/{family}/members", headers=owner).json()
    assert people[0]["relation"] == "nan"
    assert people[0]["role"] == "watcher"
    carer_code = client.post(
        f"/families/{family}/invites",
        headers=owner,
        json={"email": "carer@example.com", "relation": "carer"},
    ).json()["code"]
    carer, _ = account(client, "carer@example.com")
    assert client.post("/invites/accept", headers=carer, json={"code": carer_code}).status_code == 200
    people = client.get(f"/families/{family}/members", headers=owner).json()
    roles = {row["email"]: row for row in people}
    assert roles["carer@example.com"]["role"] == "carer"
    assert roles["carer@example.com"]["relation"] == "carer"


def test_monitoring_handover_is_exclusive(client):
    owner, _ = account(client, "mum@example.com")
    carer, _ = account(client, "nan@example.com")
    family = group(client, owner)
    code = client.post(
        f"/families/{family}/invites",
        headers=owner,
        json={"email": "nan@example.com", "relation": "carer"},
    ).json()["code"]
    assert client.post("/invites/accept", headers=carer, json={"code": code}).status_code == 200
    first = client.post(f"/families/{family}/host", headers=owner, json={"relation": "mum"}).json()
    assert first["stream_id"]
    packed = snapshot()
    packed["stream_id"] = first["stream_id"]
    packed["seq"] = 1
    assert client.put(f"/families/{family}/latest", headers=owner, json=packed).status_code == 200
    second = client.post(f"/families/{family}/host", headers=carer, json={"relation": "nan"}).json()
    stale = snapshot()
    stale["stream_id"] = first["stream_id"]
    stale["seq"] = 2
    assert client.put(f"/families/{family}/latest", headers=owner, json=stale).status_code == 409
    live = snapshot()
    live["stream_id"] = second["stream_id"]
    live["seq"] = 1
    assert client.put(f"/families/{family}/latest", headers=carer, json=live).status_code == 200
    assert client.post(f"/families/{family}/ack", headers=owner).status_code == 200
    remote = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert remote["acknowledged"] is True
    watcher, _ = account(client, "auntie@example.com")
    watch_code = client.post(
        f"/families/{family}/invites",
        headers=owner,
        json={"email": "auntie@example.com", "relation": "auntie"},
    ).json()["code"]
    assert client.post("/invites/accept", headers=watcher, json={"code": watch_code}).status_code == 200
    assert client.post(f"/families/{family}/host", headers=watcher, json={"relation": "auntie"}).status_code == 200


def test_share_link_live_view(client):
    owner, _ = account(client, "mum@example.com")
    family = group(client, owner)
    link = client.post(f"/families/{family}/share-link", headers=owner).json()
    token = link["token"]
    assert "/join/" + token in link["url"]
    page = client.get("/join/" + token)
    assert page.status_code == 200
    assert "Nivvi" in page.text
    waiting = client.get("/join/" + token + "/live").json()
    assert waiting["waiting"] is True
    packed = snapshot()
    packed["stream_id"] = "s1"
    packed["seq"] = 1
    assert client.put(f"/families/{family}/latest", headers=owner, json=packed).status_code == 200
    live = client.get("/join/" + token + "/live").json()
    assert live["heart_rate"] == 100
    assert live["waiting"] is False
    assert client.get("/join/not-a-real-token/live").status_code == 404
    assert client.put(f"/families/{family}/profile", headers=owner, json={"child_name": "Delilah Faith", "place": "home", "low_enabled": True, "low_threshold": 80}).status_code == 200
    listed = client.get("/families", headers=owner).json()[0]
    assert listed["child_name"] == "Delilah Faith"
    assert listed["low_enabled"] is True
    assert listed["low_threshold"] == 80
    assert "Delilah Faith" in client.get("/join/" + token).text


def test_one_short_family_code_joins_everyone(client):
    mum, _ = account(client, "mum@example.com")
    dad, _ = account(client, "dad@example.com")
    nan, _ = account(client, "nan@example.com")
    family = group(client, mum)
    code = client.get("/families", headers=mum).json()[0]["join_code"]
    assert len(code) == 6
    assert client.post("/invites/accept", headers=dad, json={"code": code, "relation": "dad"}).status_code == 200
    assert client.post("/invites/accept", headers=nan, json={"code": code.lower(), "relation": "nan"}).status_code == 200
    people = client.get(f"/families/{family}/members", headers=mum).json()
    emails = {row["email"]: row["relation"] for row in people}
    assert emails == {"dad@example.com": "dad", "nan@example.com": "nan"}
    assert client.post("/invites/accept", headers=mum, json={"code": code}).status_code == 400



def test_short_password_explains_422(client):
    result = client.post("/auth/register", json={"email": "short@example.com", "password": "tiny"})
    assert result.status_code == 422
    assert "12 characters" in result.json()["detail"]





