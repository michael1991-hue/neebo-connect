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
