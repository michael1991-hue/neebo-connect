"""Nivvi family relay. Single process, private persistent SQLite, TLS at ingress."""
import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import smtplib
import ssl
import sqlite3
import time
from contextlib import contextmanager, asynccontextmanager
from email.message import EmailMessage
from pathlib import Path

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request, Depends
from pydantic import BaseModel, Field

DB = os.environ.get("NIVVI_DATABASE", "/data/nivvi.sqlite")
TEST = os.environ.get("NIVVI_TESTING") == "1"
OUTBOX = []  # Tests only; production never stores verification messages here.


@contextmanager
def db():
    c = sqlite3.connect(DB, timeout=10)
    c.row_factory = sqlite3.Row
    c.execute("PRAGMA foreign_keys=ON")
    try:
        with c:
            yield c
    finally:
        c.close()


def initialize():
    Path(DB).parent.mkdir(parents=True, exist_ok=True)
    with db() as c:
        c.execute("PRAGMA journal_mode=WAL")
        c.executescript("""
        CREATE TABLE IF NOT EXISTS users(id TEXT PRIMARY KEY,email TEXT UNIQUE NOT NULL,password TEXT NOT NULL,verified INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS sessions(token TEXT PRIMARY KEY,user_id TEXT REFERENCES users ON DELETE CASCADE,expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS codes(email TEXT,purpose TEXT,token TEXT,expires REAL,PRIMARY KEY(email,purpose));
        CREATE TABLE IF NOT EXISTS limits(key TEXT PRIMARY KEY,count INTEGER,expires REAL);
        CREATE TABLE IF NOT EXISTS families(id TEXT PRIMARY KEY,owner TEXT UNIQUE REFERENCES users ON DELETE CASCADE,label TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS members(family TEXT REFERENCES families ON DELETE CASCADE,user_id TEXT REFERENCES users ON DELETE CASCADE,PRIMARY KEY(family,user_id));
        CREATE TABLE IF NOT EXISTS invites(token TEXT PRIMARY KEY,family TEXT REFERENCES families ON DELETE CASCADE,email TEXT NOT NULL,expires REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS latest(family TEXT PRIMARY KEY REFERENCES families ON DELETE CASCADE,payload TEXT NOT NULL,received REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS devices(token TEXT PRIMARY KEY,user_id TEXT REFERENCES users ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS pushes(id TEXT PRIMARY KEY,family TEXT REFERENCES families ON DELETE CASCADE,kind TEXT,created REAL,attempts INTEGER DEFAULT 0);
        """)
    os.chmod(DB, 0o600)


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def password_hash(value, salt=None):
    salt = salt or secrets.token_hex(16)
    result = hashlib.scrypt(value.encode(), salt=salt.encode(), n=16384, r=8, p=1).hex()
    return salt + ":" + result


def email(value):
    value = value.strip().lower()
    if len(value) > 254 or not re.fullmatch(r"[^\s@]+@[^\s@]+\.[^\s@]+", value):
        raise HTTPException(400, "Enter a valid email address")
    return value


def throttle(key, maximum=12, seconds=900):
    now = time.time()
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        c.execute("DELETE FROM limits WHERE expires < ?", (now,))
        row = c.execute("SELECT count FROM limits WHERE key=?", (key,)).fetchone()
        if row and row[0] >= maximum:
            raise HTTPException(429, "Too many attempts. Try again later.")
        c.execute("INSERT INTO limits VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1", (key, now + seconds))


def auth_limit(request):
    throttle("auth:" + digest(request.client.host), maximum=30)


def require_user(request: Request):
    token = request.headers.get("Authorization", "").removeprefix("Bearer ")
    with db() as c:
        row = c.execute("SELECT users.* FROM sessions JOIN users ON users.id=sessions.user_id WHERE token=? AND expires>? AND verified=1", (digest(token), time.time())).fetchone()
    if row is None:
        raise HTTPException(401, "Please sign in again")
    return dict(row)


def owner(c, family, user):
    if not c.execute("SELECT 1 FROM families WHERE id=? AND owner=?", (family, user["id"])).fetchone():
        raise HTTPException(404, "Family unavailable")


def member(c, family, user):
    if not c.execute("SELECT 1 FROM families WHERE id=? AND (owner=? OR EXISTS(SELECT 1 FROM members WHERE family=families.id AND user_id=?))", (family, user["id"], user["id"])).fetchone():
        raise HTTPException(404, "Family unavailable")


def send_code(address, purpose):
    token = secrets.token_urlsafe(24)
    with db() as c:
        c.execute("INSERT OR REPLACE INTO codes VALUES(?,?,?,?)", (address, purpose, digest(token), time.time() + 900))
    if TEST:
        OUTBOX.append((address, purpose, token))
        return
    msg = EmailMessage()
    msg["From"] = os.environ["NIVVI_SMTP_FROM"]
    msg["To"] = address
    msg["Subject"] = "Nivvi account verification" if purpose == "verify" else "Nivvi password reset"
    msg.set_content(f"Paste this code in Nivvi to {purpose} your account:\n\n{token}\n\nIt expires in 15 minutes. If you did not request it, ignore this message.")
    with smtplib.SMTP(os.environ["NIVVI_SMTP_HOST"], int(os.environ.get("NIVVI_SMTP_PORT", "587")), timeout=15) as smtp:
        smtp.starttls(context=ssl.create_default_context())
        smtp.login(os.environ["NIVVI_SMTP_USER"], os.environ["NIVVI_SMTP_PASSWORD"])
        smtp.send_message(msg)


class Credentials(BaseModel):
    email: str = Field(max_length=254)
    password: str = Field(min_length=12, max_length=128)


class Code(BaseModel):
    email: str = Field(max_length=254)
    code: str = Field(max_length=128)


class Reset(Code):
    password: str = Field(min_length=12, max_length=128)


class Address(BaseModel):
    email: str = Field(max_length=254)


class Family(BaseModel):
    label: str = Field(min_length=1, max_length=40)


class Invite(BaseModel):
    code: str = Field(min_length=20, max_length=128)


class Snapshot(BaseModel):
    # The capture time must come from the source device callback, never upload time.
    captured: float
    heart_rate: float | None = Field(default=None, ge=1, le=65535)
    oxygen: float | None = Field(default=None, ge=0, le=100)
    source: str = Field(max_length=80)
    alarm: str = Field(default="none", pattern="^(none|high|low|sensor)$")
    connection: str = Field(max_length=80)


class Device(BaseModel):
    token: str = Field(pattern="^[a-fA-F0-9]{64,256}$")


@asynccontextmanager
async def lifespan(app):
    if not TEST:
        for key in ["NIVVI_SMTP_HOST", "NIVVI_SMTP_FROM", "NIVVI_SMTP_USER", "NIVVI_SMTP_PASSWORD"]:
            if not os.environ.get(key):
                raise RuntimeError(f"Missing required configuration: {key}")
    initialize()
    worker = asyncio.create_task(push_worker())
    yield
    worker.cancel()
    try:
        await worker
    except asyncio.CancelledError:
        pass


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.middleware("http")
async def privacy_headers(request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


@app.get("/health")
def health():
    return {"status": "ok", "push_configured": bool(os.environ.get("NIVVI_APNS_KEY"))}


@app.post("/auth/register")
def register(body: Credentials, request: Request):
    auth_limit(request)
    address = email(body.email)
    throttle("email:" + digest(address), 4)
    with db() as c:
        c.execute("INSERT OR IGNORE INTO users VALUES(?,?,?,0)", (secrets.token_hex(16), address, password_hash(body.password)))
        row = c.execute("SELECT verified FROM users WHERE email=?", (address,)).fetchone()
    if not row[0]:
        send_code(address, "verify")
    return {"message": "Check your email for a code. If already registered, sign in or reset your password."}


def consume_code(c, address, purpose, token):
    row = c.execute("SELECT token,expires FROM codes WHERE email=? AND purpose=?", (address, purpose)).fetchone()
    if not row or row[1] <= time.time() or not hmac.compare_digest(row[0], digest(token.strip())):
        raise HTTPException(400, "Invalid or expired code")
    c.execute("DELETE FROM codes WHERE email=? AND purpose=?", (address, purpose))


@app.post("/auth/verify")
def verify(body: Reset, request: Request):
    auth_limit(request)
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        consume_code(c, email(body.email), "verify", body.code)
        # Bind the password chosen by the mailbox owner, not a prior unverified signup.
        c.execute("UPDATE users SET verified=1,password=? WHERE email=?", (password_hash(body.password), email(body.email)))
    return {"message": "Email verified. Sign in to continue."}


@app.post("/auth/reset-request")
def reset_request(body: Address, request: Request):
    auth_limit(request)
    address = email(body.email)
    throttle("email:" + digest(address), 4)
    with db() as c:
        exists = c.execute("SELECT 1 FROM users WHERE email=?", (address,)).fetchone()
    if exists:
        send_code(address, "reset")
    return {"message": "If the account exists, a reset code has been sent."}


@app.post("/auth/reset")
def reset(body: Reset, request: Request):
    auth_limit(request)
    address = email(body.email)
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        consume_code(c, address, "reset", body.code)
        c.execute("UPDATE users SET password=?,verified=1 WHERE email=?", (password_hash(body.password), address))
        c.execute("DELETE FROM sessions WHERE user_id IN(SELECT id FROM users WHERE email=?)", (address,))
        c.execute("DELETE FROM devices WHERE user_id IN(SELECT id FROM users WHERE email=?)", (address,))
    return {"message": "Password changed. Sign in again on each phone."}


@app.post("/auth/login")
def login(body: Credentials, request: Request):
    auth_limit(request)
    address = email(body.email)
    with db() as c:
        row = c.execute("SELECT * FROM users WHERE email=?", (address,)).fetchone()
        reference = row["password"] if row else password_hash("dummy-password")
        valid = hmac.compare_digest(reference, password_hash(body.password, reference.split(":")[0]))
        if not row or not valid or not row["verified"]:
            raise HTTPException(401, "Sign-in failed. Check your password and verify your email.")
        token = secrets.token_urlsafe(32)
        c.execute("INSERT INTO sessions VALUES(?,?,?)", (digest(token), row["id"], time.time() + 30 * 86400))
    return {"token": token, "user_id": row["id"], "email": address}


@app.post("/auth/logout")
def logout(request: Request, user=Depends(require_user)):
    with db() as c:
        c.execute("DELETE FROM sessions WHERE token=?", (digest(request.headers["Authorization"].removeprefix("Bearer ")),))
    return {"ok": True}


@app.delete("/account")
def delete_account(user=Depends(require_user)):
    with db() as c:
        c.execute("DELETE FROM invites WHERE email=?", (user["email"],))
        c.execute("DELETE FROM codes WHERE email=?", (user["email"],))
        c.execute("DELETE FROM users WHERE id=?", (user["id"],))
    return {"ok": True}


@app.get("/families")
def families(user=Depends(require_user)):
    with db() as c:
        return [dict(r) for r in c.execute("SELECT id,label,owner FROM families WHERE owner=? OR id IN(SELECT family FROM members WHERE user_id=?)", (user["id"], user["id"]))]


@app.post("/families")
def create_family(body: Family, user=Depends(require_user)):
    with db() as c:
        c.execute("INSERT OR IGNORE INTO families VALUES(?,?,?)", (secrets.token_hex(16), user["id"], body.label.strip() or "Family"))
        return dict(c.execute("SELECT id,label,owner FROM families WHERE owner=?", (user["id"],)).fetchone())


@app.delete("/families/{family}")
def stop_sharing(family: str, user=Depends(require_user)):
    with db() as c:
        owner(c, family, user)
        c.execute("DELETE FROM families WHERE id=?", (family,))
    return {"ok": True}


@app.post("/families/{family}/invites")
def invite(family: str, body: Address, user=Depends(require_user)):
    throttle("invite:" + user["id"], 20, 3600)
    token = secrets.token_urlsafe(32)
    with db() as c:
        owner(c, family, user)
        c.execute("DELETE FROM invites WHERE family=? AND email=?", (family, email(body.email)))
        c.execute("INSERT INTO invites VALUES(?,?,?,?)", (digest(token), family, email(body.email), time.time()+86400))
    return {"code": token}


@app.post("/invites/accept")
def accept(body: Invite, user=Depends(require_user)):
    throttle("accept:" + user["id"], 20)
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        row = c.execute("SELECT * FROM invites WHERE token=? AND email=? AND expires>?", (digest(body.code.strip()), user["email"], time.time())).fetchone()
        if not row:
            raise HTTPException(400, "Invitation unavailable, expired or addressed to another account")
        c.execute("INSERT OR IGNORE INTO members VALUES(?,?)", (row["family"], user["id"]))
        c.execute("DELETE FROM invites WHERE token=?", (row["token"],))
    return {"ok": True}


@app.get("/families/{family}/members")
def members(family: str, user=Depends(require_user)):
    with db() as c:
        owner(c, family, user)
        return [dict(r) for r in c.execute("SELECT users.id,users.email FROM members JOIN users ON users.id=user_id WHERE family=?", (family,))]


@app.delete("/families/{family}/members/{member_id}")
def revoke(family: str, member_id: str, user=Depends(require_user)):
    with db() as c:
        if member_id != user["id"]:
            owner(c, family, user)
        c.execute("DELETE FROM members WHERE family=? AND user_id=?", (family, member_id))
        c.execute("DELETE FROM invites WHERE family=? AND email IN(SELECT email FROM users WHERE id=?)", (family, member_id))
    return {"ok": True}


@app.put("/families/{family}/latest")
def publish(family: str, body: Snapshot, user=Depends(require_user)):
    now = time.time()
    if not now-30 <= body.captured <= now+5:
        raise HTTPException(400, "Only fresh snapshots can be shared; check the phone clock")
    throttle("publish:" + user["id"], 180, 60)
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        owner(c, family, user)
        previous = c.execute("SELECT payload FROM latest WHERE family=?", (family,)).fetchone()
        old = json.loads(previous[0]) if previous else {}
        if old.get("captured", 0) > body.captured:
            raise HTTPException(409, "An older snapshot cannot replace a newer one")
        if body.heart_rate is None and body.alarm == "none" and old.get("alarm") in ("high", "low"):
            body.alarm = old["alarm"]
        c.execute("INSERT OR REPLACE INTO latest VALUES(?,?,?)", (family, body.model_dump_json(), now))
        if body.alarm != old.get("alarm", "none"):
            # A missing reading cannot generate a recovery push.
            recovery = body.alarm == "none" and body.heart_rate is not None and old.get("alarm") in ("high", "low")
            restored = body.alarm == "none" and body.heart_rate is not None and old.get("alarm") == "sensor"
            if recovery or restored or body.alarm != "none":
                c.execute("DELETE FROM pushes WHERE family=?", (family,))
                c.execute("INSERT INTO pushes(id,family,kind,created) VALUES(?,?,?,?)", (secrets.token_hex(16), family, "recovery" if recovery else "sensor-restored" if restored else "sensor" if body.alarm == "sensor" else "attention", now))
    return {"ok": True}


@app.get("/families/{family}/latest")
def latest(family: str, user=Depends(require_user)):
    now = time.time()
    with db() as c:
        member(c, family, user)
        row = c.execute("SELECT * FROM latest WHERE family=?", (family,)).fetchone()
    if not row:
        return {"fresh": False, "age": None, "snapshot": None}
    data = json.loads(row["payload"])
    age = now - data["captured"]
    return {"fresh": 0 <= age <= 30, "age": max(0, age), "snapshot": data if age <= 86400 else None}


@app.put("/devices")
def device(body: Device, user=Depends(require_user)):
    with db() as c:
        c.execute("INSERT OR REPLACE INTO devices VALUES(?,?)", (body.token.lower(), user["id"]))
    return {"ok": True}


@app.delete("/devices/{token}")
def remove_device(token: str, user=Depends(require_user)):
    with db() as c:
        c.execute("DELETE FROM devices WHERE token=? AND user_id=?", (token.lower(), user["id"]))
    return {"ok": True}


async def push_worker():
    while True:
        try:
            await deliver_pushes()
            with db() as c:
                now = time.time()
                c.execute("DELETE FROM latest WHERE received<?", (now-86400,))
                c.execute("DELETE FROM invites WHERE expires<?", (now,))
                c.execute("DELETE FROM codes WHERE expires<?", (now,))
                c.execute("DELETE FROM sessions WHERE expires<?", (now,))
                c.execute("DELETE FROM pushes WHERE created<? OR attempts>=5", (now-120,))
        except Exception:
            # No tokens, passwords or health payloads in logs.
            print("Family notification worker unavailable; retrying", flush=True)
        await asyncio.sleep(5)


async def deliver_pushes():
    key = os.environ.get("NIVVI_APNS_KEY")
    if not key:
        return
    bearer = jwt.encode({"iss": os.environ["NIVVI_APNS_TEAM"], "iat": int(time.time())}, Path(key).read_text(), algorithm="ES256", headers={"kid": os.environ["NIVVI_APNS_KEY_ID"]})
    host = "api.sandbox.push.apple.com" if os.environ.get("NIVVI_APNS_SANDBOX") == "1" else "api.push.apple.com"
    with db() as c:
        pending = [dict(r) for r in c.execute("SELECT * FROM pushes WHERE created>? AND attempts<5", (time.time()-120,))]
    async with httpx.AsyncClient(http2=True, timeout=10) as client:
        for event in pending:
            with db() as c:
                # Fetch membership at send time; never use a cached invitation recipient list.
                tokens = [r[0] for r in c.execute("SELECT token FROM devices JOIN members ON devices.user_id=members.user_id WHERE family=?", (event["family"],))]
            failed = False
            for token in tokens:
                with db() as c:
                    allowed = c.execute("SELECT 1 FROM devices JOIN members ON devices.user_id=members.user_id JOIN pushes ON pushes.family=members.family WHERE token=? AND pushes.id=?", (token,event["id"])).fetchone()
                if not allowed:
                    continue
                recovery = event["kind"] == "recovery"
                sensor = event["kind"] in ("sensor", "sensor-restored")
                message = "A shared reading has returned to range. Open Nivvi to check its time." if recovery else "Changed readings received from the shared sensor. Open Nivvi to check." if event["kind"] == "sensor-restored" else "Check the shared sensor data. Open Nivvi for the latest status." if sensor else "A shared monitor needs attention. Open Nivvi for the latest status."
                payload = {"aps": {"alert": {"title": "Nivvi family update", "body": message}, "sound": "NivviRelief.wav" if recovery else "NivviSensor.wav" if sensor else "NivviSiren.wav"}, "family_id": event["family"]}
                result = await client.post(f"https://{host}/3/device/{token}", headers={"authorization": "bearer " + bearer, "apns-topic": os.environ["NIVVI_APNS_TOPIC"], "apns-push-type": "alert", "apns-expiration": str(int(event["created"]+120)), "apns-collapse-id": event["family"]}, json=payload)
                if result.status_code == 410 or (result.status_code == 400 and result.json().get("reason") == "BadDeviceToken"):
                    with db() as c:
                        c.execute("DELETE FROM devices WHERE token=?", (token,))
                elif result.status_code != 200:
                    failed = True
            with db() as c:
                if failed:
                    c.execute("UPDATE pushes SET attempts=attempts+1 WHERE id=?", (event["id"],))
                else:
                    c.execute("DELETE FROM pushes WHERE id=?", (event["id"],))
