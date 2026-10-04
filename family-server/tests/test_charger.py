import importlib.util
import os
import time
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


def test_charger_replaces_a_stale_phone_and_skips_a_fresh_one(client):
    owner = account(client, "charger-owner@example.com")
    family = client.post("/families", headers=owner, json={"label": "Home"}).json()["id"]
    headers = {"X-Nivvi-Charger": "test-charger-secret"}
    stale = {"captured": time.time() - 40, "heart_rate": 90, "heart_rate_at": time.time() - 40, "oxygen": 98, "source": "phone", "alarm": "none", "connection": "receiving", "stream_id": "phone", "seq": 1}
    assert client.put(f"/families/{family}/latest", headers=owner, json=stale).status_code == 200
    reading = {"serial": "11298", "heart_rate": 83, "heart_state": 0, "oxygen": 97, "oxygen_state": 0, "temperature": 25.8, "battery": 81}
    posted = client.post("/internal/charger", headers=headers, json=reading)
    assert posted.status_code == 200 and posted.json()["ok"] is True
    snap = client.get(f"/families/{family}/latest", headers=owner).json()["snapshot"]
    assert snap["source"] == "charger"
    assert snap["heart_rate"] == 83
    assert snap["oxygen"] == 97
    assert snap["host_relation"] == "Charger"
    assert snap["alarm"] == "none"
    fresh = {"captured": time.time(), "heart_rate": 82, "heart_rate_at": time.time(), "oxygen": 96, "source": "phone", "alarm": "none", "connection": "receiving", "stream_id": "phone", "seq": snap["seq"] + 1}
    assert client.put(f"/families/{family}/latest", headers=owner, json=fresh).status_code == 200
    assert client.post("/internal/charger", headers=headers, json=reading).json()["skipped"] == "phone"
    assert client.post("/internal/charger", json=reading).status_code == 404
    assert client.post("/internal/charger", headers=headers, json={"serial": "11298", "heart_rate": 0, "heart_state": 0}).json()["skipped"] == "no pulse"
