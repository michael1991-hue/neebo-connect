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
import threading
import time
from contextlib import contextmanager, asynccontextmanager
from email.message import EmailMessage
from html import escape
from pathlib import Path

import httpx
import jwt
from fastapi import FastAPI, HTTPException, Request, Depends, WebSocket
from fastapi.exceptions import RequestValidationError
from fastapi.responses import HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

DB = os.environ.get("NIVVI_DATABASE", "/data/nivvi.sqlite")
TEST = os.environ.get("NIVVI_TESTING") == "1"
OUTBOX = []  # Tests only; production never stores verification messages here.
ACTIVITY_PUSHES = []  # Tests only.
ACTIVITY_GATE = {}


class LiveHub:
    def __init__(self):
        self.loop = None
        self.clients = []

    def bind(self, loop):
        self.loop = loop

    def add(self, family, user_id, queue):
        self.clients.append((family, user_id, queue))

    def remove(self, queue):
        self.clients = [item for item in self.clients if item[2] is not queue]

    def emit(self, family, payload):
        def push():
            for fam, _uid, queue in list(self.clients):
                if fam != family:
                    continue
                if queue.full():
                    try:
                        queue.get_nowait()
                    except Exception:
                        pass
                try:
                    queue.put_nowait(payload)
                except Exception:
                    pass
        if self.loop is not None:
            self.loop.call_soon_threadsafe(push)
        else:
            push()

    def drop_user(self, user_id, family=None):
        def push():
            for fam, uid, queue in list(self.clients):
                if uid == user_id and (family is None or fam == family):
                    try:
                        queue.put_nowait({"type": "revoked"})
                    except Exception:
                        pass
        if self.loop is not None:
            self.loop.call_soon_threadsafe(push)
        else:
            push()

    def drop_family(self, family):
        def push():
            for fam, _uid, queue in list(self.clients):
                if fam == family:
                    try:
                        queue.put_nowait({"type": "revoked"})
                    except Exception:
                        pass
        if self.loop is not None:
            self.loop.call_soon_threadsafe(push)
        else:
            push()


HUB = LiveHub()


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
        CREATE TABLE IF NOT EXISTS members(family TEXT REFERENCES families ON DELETE CASCADE,user_id TEXT REFERENCES users ON DELETE CASCADE,role TEXT NOT NULL DEFAULT 'watcher',PRIMARY KEY(family,user_id));
        CREATE TABLE IF NOT EXISTS invites(token TEXT PRIMARY KEY,family TEXT REFERENCES families ON DELETE CASCADE,email TEXT NOT NULL,expires REAL NOT NULL,role TEXT NOT NULL DEFAULT 'watcher');
        CREATE TABLE IF NOT EXISTS latest(family TEXT PRIMARY KEY REFERENCES families ON DELETE CASCADE,payload TEXT NOT NULL,received REAL NOT NULL);
        CREATE TABLE IF NOT EXISTS devices(token TEXT PRIMARY KEY,user_id TEXT REFERENCES users ON DELETE CASCADE);
        CREATE TABLE IF NOT EXISTS pushes(id TEXT PRIMARY KEY,family TEXT REFERENCES families ON DELETE CASCADE,kind TEXT,created REAL,attempts INTEGER DEFAULT 0);
        CREATE TABLE IF NOT EXISTS activity_tokens(token TEXT PRIMARY KEY, secret TEXT NOT NULL, updated REAL NOT NULL, kind TEXT NOT NULL DEFAULT 'watcher');
        CREATE TABLE IF NOT EXISTS activity_latest(secret TEXT PRIMARY KEY, seq INTEGER NOT NULL, measured REAL NOT NULL);
        """)
        for stmt in (
            "ALTER TABLE members ADD COLUMN role TEXT NOT NULL DEFAULT 'watcher'",
            "ALTER TABLE invites ADD COLUMN role TEXT NOT NULL DEFAULT 'watcher'",
            "ALTER TABLE members ADD COLUMN relation TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE invites ADD COLUMN relation TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE families ADD COLUMN host_user TEXT",
            "ALTER TABLE families ADD COLUMN host_stream TEXT",
            "ALTER TABLE families ADD COLUMN host_relation TEXT",
            "ALTER TABLE families ADD COLUMN share_token TEXT",
            "ALTER TABLE families ADD COLUMN join_code TEXT",
            "ALTER TABLE families ADD COLUMN child_name TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE families ADD COLUMN child_gender TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE families ADD COLUMN child_birth REAL",
            "ALTER TABLE families ADD COLUMN place TEXT",
            "ALTER TABLE families ADD COLUMN high_enabled INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE families ADD COLUMN low_enabled INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE families ADD COLUMN high_threshold INTEGER",
            "ALTER TABLE families ADD COLUMN low_threshold INTEGER",
            "ALTER TABLE families ADD COLUMN duration_seconds INTEGER NOT NULL DEFAULT 15",
            "ALTER TABLE activity_tokens ADD COLUMN kind TEXT NOT NULL DEFAULT 'watcher'",
        ):
            try:
                c.execute(stmt)
            except sqlite3.OperationalError:
                pass
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


def public_root():
    return (os.environ.get("NIVVI_PUBLIC_URL") or "https://family.nivvi.app").rstrip("/")


JOIN_ALPHABET = "23456789ABCDEFGHJKMNPQRSTUVWXYZ"


def new_join_code(c):
    for _ in range(24):
        code = "".join(secrets.choice(JOIN_ALPHABET) for _ in range(6))
        if not c.execute("SELECT 1 FROM families WHERE join_code=?", (code,)).fetchone():
            return code
    raise HTTPException(500, "Could not create a family code")


def ensure_join_code(c, family):
    row = c.execute("SELECT join_code FROM families WHERE id=?", (family,)).fetchone()
    if row and row["join_code"]:
        return row["join_code"]
    code = new_join_code(c)
    c.execute("UPDATE families SET join_code=? WHERE id=?", (code, family))
    return code


def ensure_share_token(c, family):
    row = c.execute("SELECT share_token FROM families WHERE id=?", (family,)).fetchone()
    if row and row["share_token"]:
        return row["share_token"]
    token = secrets.token_urlsafe(16)
    c.execute("UPDATE families SET share_token=? WHERE id=?", (token, family))
    return token


def family_for_share(token):
    token = (token or "").strip()
    if not token or len(token) > 80:
        return None
    with db() as c:
        row = c.execute(
            "SELECT id,label,host_relation,child_name FROM families WHERE share_token=? OR join_code=?",
            (token, token.upper().replace(" ", "").replace("-", "")),
        ).fetchone()
        if not row:
            return None
        latest = c.execute("SELECT payload,received FROM latest WHERE family=?", (row["id"],)).fetchone()
    snap = json.loads(latest["payload"]) if latest else None
    received = latest["received"] if latest else None
    return {"id": row["id"], "label": row["child_name"] or row["label"], "host_relation": row["host_relation"], "snapshot": snap, "received": received}


def publisher(c, family, user):
    member(c, family, user)

def send_code(address, purpose):
    token = secrets.token_urlsafe(24)
    with db() as c:
        c.execute("INSERT OR REPLACE INTO codes VALUES(?,?,?,?)", (address, purpose, digest(token), time.time() + 900))
    if TEST:
        OUTBOX.append((address, purpose, token))
        return
    threading.Thread(target=_deliver_code, args=(address, purpose, token), daemon=True).start()


def _deliver_code(address, purpose, token):
    subject = "Nivvi account verification" if purpose == "verify" else "Nivvi password reset"
    text = f"Paste this code in Nivvi to {purpose} your account:\n\n{token}\n\nIt expires in 15 minutes. If you did not request it, ignore this message."
    sender = os.environ.get("NIVVI_SMTP_FROM", "")
    try:
        if os.environ.get("NIVVI_RESEND_KEY"):
            response = httpx.post(
                "https://api.resend.com/emails",
                headers={"Authorization": "Bearer " + os.environ["NIVVI_RESEND_KEY"]},
                json={"from": sender, "to": [address], "subject": subject, "text": text},
                timeout=12,
            )
            response.raise_for_status()
            return
        msg = EmailMessage()
        msg["From"] = sender
        msg["To"] = address
        msg["Subject"] = subject
        msg.set_content(text)
        with smtplib.SMTP(os.environ["NIVVI_SMTP_HOST"], int(os.environ.get("NIVVI_SMTP_PORT", "587")), timeout=12) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            smtp.login(os.environ["NIVVI_SMTP_USER"], os.environ["NIVVI_SMTP_PASSWORD"])
            smtp.send_message(msg)
    except Exception as exc:
        print(f"SMTP failed for {purpose}: {type(exc).__name__}: {exc}", flush=True)


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
    role: str = Field(default="watcher", pattern="^(watcher|carer)$")
    relation: str = Field(default="", max_length=24)


class HostClaim(BaseModel):
    relation: str = Field(default="", max_length=24)


class ChildProfile(BaseModel):
    child_name: str = Field(default="", max_length=40)
    child_gender: str = Field(default="", max_length=40)
    child_birth: float | None = None
    place: str | None = Field(default=None, max_length=20)
    high_enabled: bool = False
    low_enabled: bool = False
    high_threshold: int | None = Field(default=None, ge=1, le=299)
    low_threshold: int | None = Field(default=None, ge=1, le=299)
    duration_seconds: int = Field(default=15, ge=5, le=120)


class Family(BaseModel):
    label: str = Field(min_length=1, max_length=40)


class Invite(BaseModel):
    code: str = Field(min_length=6, max_length=128)
    relation: str = Field(default="", max_length=20)


class FamilyAlertPoint(BaseModel):
    id: str = Field(max_length=80)
    t: float
    title: str = Field(max_length=80)
    detail: str = Field(default="", max_length=240)
    hr: int | None = None


class HistoryPoint(BaseModel):
    t: float
    hr: float | None = Field(default=None, ge=1, le=65535)
    o2: float | None = Field(default=None, ge=0, le=100)
    sk: float | None = None


class Snapshot(BaseModel):
    # The capture time must come from the source device callback, never upload time.
    captured: float
    heart_rate: float | None = Field(default=None, ge=1, le=65535)
    oxygen: float | None = Field(default=None, ge=0, le=100)
    heart_rate_at: float | None = None
    oxygen_at: float | None = None
    source: str = Field(max_length=80)
    alarm: str = Field(default="none", pattern="^(none|high|low|sensor)$")
    connection: str = Field(max_length=80)
    history: list[HistoryPoint] = Field(default_factory=list, max_length=800)
    stream_id: str | None = Field(default=None, max_length=80)
    seq: int | None = Field(default=None, ge=1)
    kind: str = Field(default="live", max_length=20)
    acknowledged: bool = False
    activity_secret: str | None = Field(default=None, max_length=80)
    place: str | None = Field(default=None, pattern="^(home|carer|exploring)$")
    host_relation: str | None = Field(default=None, max_length=24)
    acknowledged_by: str | None = Field(default=None, max_length=20)
    battery: str | None = Field(default=None, max_length=20)
    charging: bool | None = None
    skin: float | None = None
    alerts: list[FamilyAlertPoint] = Field(default_factory=list, max_length=40)


class Device(BaseModel):
    token: str = Field(pattern="^[a-fA-F0-9]{64,256}$")


class ActivityToken(BaseModel):
    secret: str = Field(min_length=16, max_length=80)
    token: str = Field(pattern="^[a-fA-F0-9]{64,512}$")
    kind: str = "watcher"


class ActivityPublish(BaseModel):
    secret: str = Field(min_length=16, max_length=80)
    seq: int = Field(ge=1)
    measured_at: float
    heart_rate: str = Field(max_length=40)
    oxygen: str = Field(max_length=40)
    connection: str = Field(max_length=80)
    session: str = Field(default="", max_length=80)
    title: str = Field(default="Nivvi", max_length=80)


@asynccontextmanager
async def lifespan(app):
    if not TEST:
        if os.environ.get("NIVVI_RESEND_KEY"):
            if not os.environ.get("NIVVI_SMTP_FROM"):
                raise RuntimeError("Missing required configuration: NIVVI_SMTP_FROM")
        else:
            for key in ["NIVVI_SMTP_HOST", "NIVVI_SMTP_FROM", "NIVVI_SMTP_USER", "NIVVI_SMTP_PASSWORD"]:
                if not os.environ.get(key):
                    raise RuntimeError(f"Missing required configuration: {key}")
    initialize()
    HUB.bind(asyncio.get_running_loop())
    worker = asyncio.create_task(push_worker())
    yield
    worker.cancel()
    try:
        await worker
    except asyncio.CancelledError:
        pass


app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


@app.exception_handler(RequestValidationError)
async def invalid_form(_, exc: RequestValidationError):
    notes = []
    for err in exc.errors():
        field = (err.get("loc") or [None])[-1]
        if field == "password":
            notes.append("Password must be at least 12 characters.")
        elif field == "email":
            notes.append("Check the email address.")
        elif field == "code":
            notes.append("Paste the full code from the email, not a 6-digit PIN.")
        else:
            notes.append("Check the form and try again.")
    text = " ".join(dict.fromkeys(notes)) or "Check the form and try again."
    return JSONResponse({"detail": text}, status_code=422)


@app.middleware("http")
async def privacy_headers(request, call_next):
    response = await call_next(request)
    response.headers["Cache-Control"] = "no-store"
    response.headers["X-Content-Type-Options"] = "nosniff"
    return response


@app.get("/health")
def health():
    return {"status": "ok", "push_configured": bool(os.environ.get("NIVVI_APNS_KEY")), "join_codes": True, "anyone_can_host": True}


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
        rows = [dict(r) for r in c.execute(
            """SELECT id,label,owner,
                      CASE WHEN owner=? THEN 'owner' ELSE COALESCE((SELECT role FROM members WHERE family=families.id AND user_id=?),'watcher') END AS role,
                      host_relation,
                      share_token,
                      join_code,
                      child_name, child_gender, child_birth, place,
                      high_enabled, low_enabled, high_threshold, low_threshold, duration_seconds
               FROM families WHERE owner=? OR id IN(SELECT family FROM members WHERE user_id=?)""",
            (user["id"], user["id"], user["id"], user["id"]))]
        for row in rows:
            if row["owner"] == user["id"] and not row.get("join_code"):
                row["join_code"] = ensure_join_code(c, row["id"])
            row["high_enabled"] = bool(row.get("high_enabled"))
            row["low_enabled"] = bool(row.get("low_enabled"))
    return rows


@app.post("/families")
def create_family(body: Family, user=Depends(require_user)):
    with db() as c:
        c.execute("INSERT OR IGNORE INTO families(id, owner, label) VALUES(?,?,?)", (secrets.token_hex(16), user["id"], body.label.strip() or "Family"))
        family = dict(c.execute("SELECT id,label,owner FROM families WHERE owner=?", (user["id"],)).fetchone())
        family["share_token"] = ensure_share_token(c, family["id"])
        family["join_code"] = ensure_join_code(c, family["id"])
        return family


@app.delete("/families/{family}")
def stop_sharing(family: str, user=Depends(require_user)):
    with db() as c:
        owner(c, family, user)
        c.execute("DELETE FROM families WHERE id=?", (family,))
    HUB.drop_family(family)
    return {"ok": True}


@app.post("/families/{family}/share-link")
def share_link(family: str, user=Depends(require_user)):
    with db() as c:
        owner(c, family, user)
        token = ensure_share_token(c, family)
        code = ensure_join_code(c, family)
    return {"ok": True, "token": token, "code": code, "url": public_root() + "/join/" + token}


@app.put("/families/{family}/profile")
def save_profile(family: str, body: ChildProfile, user=Depends(require_user)):
    place = (body.place or "").strip().lower()
    if place and place not in {"home", "carer", "exploring"}:
        raise HTTPException(400, "Place must be home or with carer")
    with db() as c:
        owner(c, family, user)
        c.execute(
            """UPDATE families SET child_name=?, child_gender=?, child_birth=?, place=?,
                      high_enabled=?, low_enabled=?, high_threshold=?, low_threshold=?, duration_seconds=?
               WHERE id=?""",
            (
                body.child_name.strip()[:40],
                body.child_gender.strip()[:40],
                body.child_birth,
                place or None,
                1 if body.high_enabled else 0,
                1 if body.low_enabled else 0,
                body.high_threshold,
                body.low_threshold,
                body.duration_seconds,
                family,
            ),
        )
    return {"ok": True}


JOIN_PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex">
<title>Nivvi · __LABEL__</title>
<style>
body{margin:0;font-family:-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;background:#071016;color:#e8f2ef;min-height:100vh;display:flex;align-items:center;justify-content:center}
main{width:min(420px,92vw);padding:28px 22px;background:#102027;border-radius:24px;box-shadow:0 12px 40px #0008}
h1{font-size:1.4rem;margin:0 0 6px}
.sub{opacity:.7;margin:0 0 22px}
.bpm{font-size:4.2rem;font-weight:700;letter-spacing:-2px;margin:8px 0}
.o2{font-size:1.3rem;margin:0 0 12px;color:#7ee0c8}
.meta{opacity:.7;font-size:.95rem;line-height:1.45}
.warn{color:#ff8a7a;font-weight:600}
.ok{color:#7ee0c8;font-weight:600}
.foot{margin-top:22px;font-size:.8rem;opacity:.55;line-height:1.4}
</style>
</head>
<body>
<main>
<h1 id="name">__LABEL__</h1>
<p class="sub">Live family view · Nivvi</p>
<div class="bpm" id="hr">—</div>
<p class="o2" id="o2">Oxygen —</p>
<p class="meta" id="batt">Band battery —</p>
<p class="meta" id="status">Connecting…</p>
<p class="foot">Not a medical monitor. Anyone with this link can see the latest reading. Sharing can be stopped in Nivvi.</p>
</main>
<script>
const live = location.pathname.replace(/\\/+$/,'') + '/live';
async function tick(){
  try{
    const r = await fetch(live, {cache:'no-store'});
    const d = await r.json();
    document.getElementById('name').textContent = d.label || 'Nivvi';
    document.getElementById('hr').textContent = d.heart_rate ? Math.round(d.heart_rate) + ' bpm' : '—';
    document.getElementById('o2').textContent = d.oxygen != null ? 'Oxygen ' + Math.min(99, Math.round(d.oxygen)) + '%' : 'Oxygen —';
    const batt = document.getElementById('batt');
    if (d.battery) { batt.textContent = d.charging ? 'Band battery charging · ' + d.battery : 'Band battery ' + d.battery; }
    else { batt.textContent = 'Band battery —'; }
    const st = document.getElementById('status');
    if(d.waiting){ st.className='meta warn'; st.textContent = d.status; }
    else { st.className='meta ok'; st.textContent = d.status; }
  }catch(e){
    const st = document.getElementById('status');
    st.className='meta warn'; st.textContent = 'Could not reach Nivvi. Check the link.';
  }
}
tick(); setInterval(tick, 3000);
</script>
</body>
</html>
"""


@app.get("/join/{token}", response_class=HTMLResponse)
def join_page(token: str, request: Request):
    throttle("join-page:" + request.client.host, 60, 60)
    info = family_for_share(token)
    if not info:
        raise HTTPException(404, "This live link is invalid or sharing has stopped.")
    return JOIN_PAGE.replace("__LABEL__", escape(info["label"] or "Nivvi"))


@app.get("/join/{token}/live")
def join_live(token: str, request: Request):
    throttle("join-live:" + request.client.host, 120, 60)
    info = family_for_share(token)
    if not info:
        raise HTTPException(404, "This live link is invalid or sharing has stopped.")
    snap = info["snapshot"] or {}
    hr = snap.get("heart_rate")
    o2 = snap.get("oxygen")
    stamp = snap.get("heart_rate_at") or snap.get("captured") or info["received"]
    age = time.time() - stamp if stamp else None
    waiting = hr is None or age is None or age > 45
    who = {"me": "Me", "partner": "Partner", "mum": "Mum", "dad": "Dad", "nan": "Nan", "auntie": "Auntie", "uncle": "Uncle", "carer": "Carer"}.get(info.get("host_relation") or "", "") or (info.get("host_relation") or "family")
    if waiting:
        status = "Waiting for the phone next to the band to start monitoring"
    else:
        status = f"Monitoring with {who} · Updated {max(0, int(age))}s ago"
    ox = o2
    if isinstance(ox, (int, float)) and ox > 99:
        ox = 99
    return {
        "label": info["label"],
        "heart_rate": hr,
        "oxygen": ox,
        "battery": snap.get("battery"),
        "charging": bool(snap.get("charging")),
        "age": age,
        "waiting": waiting,
        "status": status,
        "connection": snap.get("connection"),
        "alarm": snap.get("alarm") or "none",
        "host_relation": info.get("host_relation"),
    }


@app.get("/.well-known/apple-app-site-association")
def apple_app_site_association():
    team = os.environ.get("NIVVI_APNS_TEAM", "")
    app_id = f"{team}.com.michael1991.nivvi" if team else "com.michael1991.nivvi"
    return JSONResponse(
        {"applinks": {"apps": [], "details": [{"appID": app_id, "paths": ["/join/*"]}]}},
        media_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


@app.post("/families/{family}/host")
def claim_host(family: str, body: HostClaim, user=Depends(require_user)):
    relation = (body.relation or "").strip()
    if len(relation) > 24:
        raise HTTPException(400, "Use a shorter name.")
    known = {"me", "partner", "mum", "dad", "nan", "auntie", "uncle", "carer"}
    if relation.lower() in known:
        relation = relation.lower()
    stream = secrets.token_hex(16)
    with db() as c:
        publisher(c, family, user)
        ensure_join_code(c, family)
        c.execute("UPDATE families SET host_user=?, host_stream=?, host_relation=? WHERE id=?", (user["id"], stream, relation, family))
        if relation:
            c.execute("UPDATE members SET role='carer', relation=? WHERE family=? AND user_id=?", (relation, family, user["id"]))
        else:
            c.execute("UPDATE members SET role='carer' WHERE family=? AND user_id=?", (family, user["id"]))
    HUB.emit(family, {"type": "host", "stream_id": stream, "host_relation": relation, "host_user": user["id"]})
    return {"ok": True, "stream_id": stream, "host_relation": relation}


@app.delete("/families/{family}/host")
def release_host(family: str, user=Depends(require_user)):
    with db() as c:
        publisher(c, family, user)
        row = c.execute("SELECT host_user FROM families WHERE id=?", (family,)).fetchone()
        if row and row["host_user"] and row["host_user"] != user["id"]:
            raise HTTPException(409, "Another phone is monitoring.")
        c.execute("UPDATE families SET host_user=NULL, host_stream=NULL WHERE id=?", (family,))
    HUB.emit(family, {"type": "host", "stream_id": "", "host_relation": "", "host_user": ""})
    return {"ok": True}


@app.post("/families/{family}/invites")
def invite(family: str, body: Address, user=Depends(require_user)):
    throttle("invite:" + user["id"], 20, 3600)
    relation = (body.relation or "").strip()
    if len(relation) > 24:
        raise HTTPException(400, "Use a shorter name.")
    known = {"me", "partner", "mum", "dad", "nan", "auntie", "uncle", "carer"}
    if relation.lower() in known:
        relation = relation.lower()
    role = "carer" if relation in ("carer", "me") or body.role == "carer" else "watcher"
    token = secrets.token_urlsafe(32)
    with db() as c:
        owner(c, family, user)
        c.execute("DELETE FROM invites WHERE family=? AND email=?", (family, email(body.email)))
        c.execute(
            "INSERT INTO invites(token,family,email,expires,role,relation) VALUES(?,?,?,?,?,?)",
            (digest(token), family, email(body.email), time.time() + 86400, role, relation),
        )
    return {"code": token}


@app.post("/invites/accept")
def accept(body: Invite, user=Depends(require_user)):
    throttle("accept:" + user["id"], 20)
    raw = body.code.strip()
    short = raw.upper().replace(" ", "").replace("-", "")
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        family = None
        role = "watcher"
        relation = (body.relation or "").strip().lower()
        allowed = {"", "me", "partner", "mum", "dad", "nan", "auntie", "uncle", "carer"}
        if relation not in allowed:
            raise HTTPException(400, "Choose who you are — Me, Partner, Mum, Dad, Nan, Auntie, Uncle or Carer.")
        if len(short) == 6 and all(ch in JOIN_ALPHABET for ch in short):
            family = c.execute("SELECT id,owner FROM families WHERE join_code=?", (short,)).fetchone()
            if not family:
                raise HTTPException(400, "That family code is not recognised.")
            if family["owner"] == user["id"]:
                raise HTTPException(400, "You’re already the owner of this family.")
            if not relation:
                raise HTTPException(400, "Say who you are — Me, Partner, Mum, Dad, Nan, Auntie, Uncle or Carer.")
            role = "carer" if relation in ("carer", "me") else "watcher"
        else:
            row = c.execute("SELECT * FROM invites WHERE token=? AND email=? AND expires>?", (digest(raw), user["email"], time.time())).fetchone()
            if not row:
                raise HTTPException(400, "Invitation unavailable, expired or addressed to another account")
            family = {"id": row["family"]}
            role = row["role"] if "role" in row.keys() else "watcher"
            relation = row["relation"] if "relation" in row.keys() else ""
            c.execute("DELETE FROM invites WHERE token=?", (row["token"],))
        c.execute(
            "INSERT OR IGNORE INTO members(family,user_id,role,relation) VALUES(?,?,?,?)",
            (family["id"], user["id"], role, relation),
        )
        if relation:
            c.execute(
                "UPDATE members SET role=?, relation=? WHERE family=? AND user_id=?",
                (role, relation, family["id"], user["id"]),
            )
    return {"ok": True}


@app.get("/families/{family}/members")
def members(family: str, user=Depends(require_user)):
    with db() as c:
        owner(c, family, user)
        return [dict(r) for r in c.execute("SELECT users.id,users.email,members.role,members.relation FROM members JOIN users ON users.id=user_id WHERE family=?", (family,))]


@app.delete("/families/{family}/members/{member_id}")
def revoke(family: str, member_id: str, user=Depends(require_user)):
    with db() as c:
        if member_id != user["id"]:
            owner(c, family, user)
        c.execute("DELETE FROM members WHERE family=? AND user_id=?", (family, member_id))
        c.execute("DELETE FROM invites WHERE family=? AND email IN(SELECT email FROM users WHERE id=?)", (family, member_id))
    HUB.drop_user(member_id, family)
    return {"ok": True}


def merge_snapshot(old, body: Snapshot, received):
    payload = body.model_dump()
    if payload.get("heart_rate") is None:
        payload["heart_rate"] = old.get("heart_rate")
        payload["heart_rate_at"] = old.get("heart_rate_at") or old.get("captured")
    else:
        payload["heart_rate_at"] = payload.get("heart_rate_at") or payload["captured"]
    if payload.get("oxygen") is None:
        payload["oxygen"] = old.get("oxygen")
        payload["oxygen_at"] = old.get("oxygen_at") or old.get("captured")
    else:
        payload["oxygen_at"] = payload.get("oxygen_at") or payload["captured"]
        try:
            ox = float(payload["oxygen"])
            if ox > 99:
                payload["oxygen"] = 99
        except (TypeError, ValueError):
            pass
    if payload.get("battery") in (None, "", "—"):
        payload["battery"] = old.get("battery")
        payload["charging"] = payload.get("charging") if payload.get("charging") is not None else old.get("charging")
    if payload.get("skin") is None:
        payload["skin"] = old.get("skin")
    if not payload.get("alerts") and old.get("alerts"):
        payload["alerts"] = old["alerts"]
    for point in payload.get("history") or []:
        o2 = point.get("o2") if isinstance(point, dict) else None
        if isinstance(o2, (int, float)) and o2 > 99:
            point["o2"] = 99
    if not payload.get("history") and old.get("history"):
        payload["history"] = old["history"]
    payload["server_received"] = received
    payload["seq"] = body.seq or int(old.get("seq") or 0) + 1
    payload["stream_id"] = body.stream_id or old.get("stream_id")
    if body.alarm == old.get("alarm"):
        payload["acknowledged"] = bool(body.acknowledged or old.get("acknowledged"))
    else:
        payload["acknowledged"] = bool(body.acknowledged)
    return payload


@app.put("/families/{family}/latest")
def publish(family: str, body: Snapshot, user=Depends(require_user)):
    now = time.time()
    if not now - 90 <= body.captured <= now + 15:
        raise HTTPException(400, "Only fresh snapshots can be shared; check the phone clock")
    throttle("publish:" + user["id"], 240, 60)
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        publisher(c, family, user)
        host = c.execute("SELECT host_user, host_stream FROM families WHERE id=?", (family,)).fetchone()
        if host and host["host_stream"] and host["host_user"] != user["id"] and body.stream_id != host["host_stream"]:
            raise HTTPException(409, "Another phone is monitoring. Take over from Family sharing.")
        if host and (not host["host_user"] or host["host_user"] == user["id"]):
            stream = body.stream_id or host["host_stream"]
            c.execute("UPDATE families SET host_user=?, host_stream=COALESCE(?, host_stream) WHERE id=?", (user["id"], stream, family))
        previous = c.execute("SELECT payload FROM latest WHERE family=?", (family,)).fetchone()
        old = json.loads(previous[0]) if previous else {}
        old_seq = int(old.get("seq") or 0)
        if body.stream_id and old.get("stream_id") == body.stream_id and body.seq is not None and body.seq <= old_seq:
            raise HTTPException(409, "An older snapshot cannot replace a newer one")
        if body.seq is None and old.get("captured", 0) > body.captured:
            raise HTTPException(409, "An older snapshot cannot replace a newer one")
        if body.heart_rate is None and body.alarm == "none" and old.get("alarm") in ("high", "low"):
            body.alarm = old["alarm"]
        payload = merge_snapshot(old, body, now)
        payload["alarm"] = body.alarm
        c.execute("INSERT OR REPLACE INTO latest VALUES(?,?,?)", (family, json.dumps(payload), now))
        if body.alarm != old.get("alarm", "none"):
            recovery = body.alarm == "none" and body.heart_rate is not None and old.get("alarm") in ("high", "low")
            restored = body.alarm == "none" and body.heart_rate is not None and old.get("alarm") == "sensor"
            if recovery or restored or body.alarm != "none":
                c.execute("DELETE FROM pushes WHERE family=?", (family,))
                c.execute("INSERT INTO pushes(id,family,kind,created) VALUES(?,?,?,?)", (secrets.token_hex(16), family, "recovery" if recovery else "sensor-restored" if restored else "sensor" if body.alarm == "sensor" else "attention", now))
    live = {key: value for key, value in payload.items() if key != "history"}
    live["type"] = "live"
    live["kind"] = "live"
    HUB.emit(family, live)
    if payload.get("activity_secret"):
        queue_activity(payload["activity_secret"], activity_state(payload, payload.get("activity_secret")), paced=True)
    return {"ok": True, "seq": payload["seq"], "server_received": now}


@app.post("/families/{family}/ack")
def acknowledge_alarm(family: str, user=Depends(require_user)):
    with db() as c:
        member(c, family, user)
        row = c.execute("SELECT payload FROM latest WHERE family=?", (family,)).fetchone()
        if not row:
            raise HTTPException(404, "No live reading to acknowledge")
        payload = json.loads(row[0])
        payload["acknowledged"] = True
        who = c.execute("SELECT host_relation FROM families WHERE id=?", (family,)).fetchone()
        member_row = c.execute("SELECT relation FROM members WHERE family=? AND user_id=?", (family, user["id"])).fetchone()
        payload["acknowledged_by"] = (member_row["relation"] if member_row and member_row["relation"] else None) or (who["host_relation"] if who else None) or ""
        c.execute("INSERT OR REPLACE INTO latest VALUES(?,?,?)", (family, json.dumps(payload), time.time()))
    live = {key: value for key, value in payload.items() if key != "history"}
    live["type"] = "ack"
    live["acknowledged"] = True
    HUB.emit(family, live)
    return {"ok": True}


@app.get("/families/{family}/latest")
def latest(family: str, user=Depends(require_user)):
    now = time.time()
    with db() as c:
        member(c, family, user)
        row = c.execute("SELECT * FROM latest WHERE family=?", (family,)).fetchone()
    if not row:
        return {"fresh": False, "age": None, "heart_rate_fresh": False, "oxygen_fresh": False, "snapshot": None}
    data = json.loads(row["payload"])
    hr_at = data.get("heart_rate_at") or data.get("captured")
    o2_at = data.get("oxygen_at") or data.get("captured")
    hr_age = now - hr_at if hr_at is not None else None
    o2_age = now - o2_at if o2_at is not None else None
    hr_fresh = data.get("heart_rate") is not None and hr_age is not None and -5 <= hr_age <= 45
    o2_fresh = data.get("oxygen") is not None and o2_age is not None and -5 <= o2_age <= 45
    age = hr_age if hr_age is not None else now - data["captured"]
    return {
        "fresh": hr_fresh,
        "age": max(0, age) if age is not None else None,
        "heart_rate_fresh": hr_fresh,
        "oxygen_fresh": o2_fresh,
        "snapshot": data if age is not None and age <= 86400 else None,
    }


@app.websocket("/families/{family}/live")
async def live_socket(ws: WebSocket, family: str):
    await ws.accept()
    token = (ws.headers.get("authorization") or "").removeprefix("Bearer ").strip() or ws.query_params.get("token", "")
    with db() as c:
        row = c.execute(
            "SELECT users.* FROM sessions JOIN users ON users.id=sessions.user_id WHERE token=? AND expires>? AND verified=1",
            (digest(token), time.time()),
        ).fetchone()
    if row is None:
        await ws.send_json({"type": "revoked"})
        await ws.close(code=4401)
        return
    user = dict(row)
    with db() as c:
        allowed = c.execute(
            "SELECT 1 FROM families WHERE id=? AND (owner=? OR EXISTS(SELECT 1 FROM members WHERE family=families.id AND user_id=?))",
            (family, user["id"], user["id"]),
        ).fetchone()
    if not allowed:
        await ws.send_json({"type": "revoked"})
        await ws.close(code=4403)
        return
    queue = asyncio.Queue(maxsize=8)
    HUB.add(family, user["id"], queue)
    with db() as c:
        stored = c.execute("SELECT payload FROM latest WHERE family=?", (family,)).fetchone()
    snapshot = json.loads(stored[0]) if stored else None
    await ws.send_json({"type": "snapshot", "kind": "snapshot", **(snapshot or {}), "snapshot": snapshot})
    try:
        while True:
            try:
                payload = await asyncio.wait_for(queue.get(), timeout=25)
            except asyncio.TimeoutError:
                await ws.send_json({"type": "ping"})
                continue
            await ws.send_json(payload)
            if payload.get("type") == "revoked":
                await ws.close(code=4403)
                break
    except Exception:
        pass
    finally:
        HUB.remove(queue)


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


@app.post("/live-activity/token")
def register_activity_token(body: ActivityToken, request: Request):
    throttle("activity-token:" + request.client.host, 30)
    kind = "host" if body.kind == "host" else "watcher"
    with db() as c:
        c.execute("INSERT OR REPLACE INTO activity_tokens VALUES(?,?,?,?)", (body.token.lower(), body.secret, time.time(), kind))
        c.execute("DELETE FROM activity_tokens WHERE updated<?", (time.time() - 7 * 86400,))
    return {"ok": True}


@app.delete("/live-activity/token")
def remove_activity_token(body: ActivityToken):
    with db() as c:
        c.execute("DELETE FROM activity_tokens WHERE token=? AND secret=?", (body.token.lower(), body.secret))
    return {"ok": True}


@app.post("/live-activity/publish")
def publish_activity(body: ActivityPublish, request: Request):
    throttle("activity:" + body.secret, 60, 60)
    now = time.time()
    if not now - 30 <= body.measured_at <= now + 5:
        raise HTTPException(400, "Only fresh readings can update the lock screen")
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        previous = c.execute("SELECT seq FROM activity_latest WHERE secret=?", (body.secret,)).fetchone()
        if previous and body.seq <= previous[0]:
            raise HTTPException(409, "An older reading cannot replace a newer one")
        c.execute("INSERT OR REPLACE INTO activity_latest VALUES(?,?,?)", (body.secret, body.seq, body.measured_at))
    state = {
        "heartRate": body.heart_rate,
        "oxygen": body.oxygen,
        "connection": body.connection,
        "signal": "Wi-Fi",
        "nurseryHint": "",
        "captured": body.measured_at,
        "measuredAt": body.measured_at,
        "seq": body.seq,
        "session": body.session,
        "stale": False,
        "alarm": "",
        "title": body.title,
    }
    queue_activity(body.secret, state)
    return {"ok": True, "seq": body.seq}


def activity_state(payload, secret):
    measured = payload.get("heart_rate_at") or payload.get("captured") or time.time()
    hr = payload.get("heart_rate")
    ox = payload.get("oxygen")
    alarm = payload.get("alarm") or ""
    age = time.time() - float(measured)
    return {
        "heartRate": f"{int(round(hr))} bpm" if isinstance(hr, (int, float)) else "No reading",
        "oxygen": f"{int(round(ox))}%" if isinstance(ox, (int, float)) else "No reading",
        "connection": payload.get("connection") or "Shared over Wi‑Fi",
        "signal": "Internet",
        "nurseryHint": "",
        "captured": measured,
        "measuredAt": measured,
        "seq": int(payload.get("seq") or 0),
        "session": payload.get("source") or "Nivvi",
        "stale": age > 45,
        "alarm": alarm if alarm in ("high", "low") else "",
        "title": "Nivvi",
    }


def queue_activity(secret, state, paced=False):
    with db() as c:
        rows = [(r[0], r[1] or "watcher") for r in c.execute("SELECT token, kind FROM activity_tokens WHERE secret=?", (secret,))]
    if not rows:
        return
    now = time.time()
    alarm = state.get("alarm") or ""
    hosts = [token for token, kind in rows if kind == "host"]
    watchers = [token for token, kind in rows if kind != "host"]

    def due(label, interval):
        gate = ACTIVITY_GATE.get(f"{secret}:{label}")
        urgent = alarm in ("high", "low") and (not gate or gate.get("alarm") != alarm)
        if paced and gate and not urgent and now - gate["at"] < interval:
            return False
        ACTIVITY_GATE[f"{secret}:{label}"] = {"at": now, "alarm": alarm}
        return True

    jobs = []
    if not paced:
        jobs.append(([token for token, _ in rows], "10", 45))
    else:
        if hosts and due("host", 8):
            jobs.append((hosts, "10", 25))
        if watchers and watcher_due(secret, state, now):
            jobs.append((watchers, "10", 25))
    if TEST:
        for tokens, priority, _stale in jobs:
            for token in tokens:
                ACTIVITY_PUSHES.append({"token": token, "state": state, "priority": priority})
        return
    if HUB.loop is not None:
        for tokens, priority, stale_for in jobs:
            HUB.loop.call_soon_threadsafe(lambda tokens=tokens, priority=priority, stale_for=stale_for: asyncio.create_task(deliver_activity(tokens, state, priority, stale_for)))


def reading_number(text):
    try:
        return int(float(str(text).split()[0]))
    except (TypeError, ValueError):
        return None


def watcher_due(secret, state, now):
    alarm = state.get("alarm") or ""
    hr = reading_number(state.get("heartRate"))
    ox = reading_number(state.get("oxygen"))
    previous = ACTIVITY_GATE.get(f"{secret}:watcher") or {}
    moved = False
    if hr is not None and previous.get("hr") is not None and abs(hr - previous["hr"]) >= 8:
        moved = True
    if ox is not None and previous.get("ox") is not None and abs(ox - previous["ox"]) >= 2:
        moved = True
    if alarm in ("high", "low") and previous.get("alarm") != alarm:
        moved = True
    if previous and not moved and now - previous.get("at", 0) < 8:
        return False
    ACTIVITY_GATE[f"{secret}:watcher"] = {"at": now, "alarm": alarm, "hr": hr, "ox": ox}
    return True


async def deliver_activity(tokens, state, priority="10", fresh_for=150):
    key = os.environ.get("NIVVI_APNS_KEY")
    if not key or not tokens:
        return
    bearer = jwt.encode({"iss": os.environ["NIVVI_APNS_TEAM"], "iat": int(time.time())}, Path(key).read_text(), algorithm="ES256", headers={"kid": os.environ["NIVVI_APNS_KEY_ID"]})
    host = "api.sandbox.push.apple.com" if os.environ.get("NIVVI_APNS_SANDBOX") == "1" else "api.push.apple.com"
    topic = os.environ.get("NIVVI_APNS_TOPIC", "com.michael1991.nivvi") + ".push-type.liveactivity"
    content = {key: value for key, value in state.items() if key != "title"}
    aps = {
        "timestamp": int(time.time()),
        "event": "update",
        "content-state": content,
        "stale-date": int(time.time() + fresh_for),
    }
    if state.get("stale"):
        aps["stale-date"] = int(time.time())
    payload = {"aps": aps}
    async with httpx.AsyncClient(http2=True, timeout=10) as client:
        for token in tokens:
            result = await client.post(
                f"https://{host}/3/device/{token}",
                headers={
                    "authorization": "bearer " + bearer,
                    "apns-topic": topic,
                    "apns-push-type": "liveactivity",
                    "apns-priority": priority,
                    "apns-expiration": str(int(time.time() + 300)),
                },
                json=payload,
            )
            if result.status_code == 410 or (result.status_code == 400 and result.json().get("reason") == "BadDeviceToken"):
                with db() as c:
                    c.execute("DELETE FROM activity_tokens WHERE token=?", (token,))
            elif result.status_code != 200:
                print(f"live activity push {result.status_code} {result.text}", flush=True)


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
                tokens = [r[0] for r in c.execute(
                    """SELECT token FROM devices WHERE user_id IN (
                           SELECT owner FROM families WHERE id=?
                           UNION
                           SELECT user_id FROM members WHERE family=?
                       ) AND user_id IS NOT (
                           SELECT host_user FROM families WHERE id=? AND host_user IS NOT NULL
                       )""",
                    (event["family"], event["family"], event["family"]),
                )]
            failed = False
            for token in tokens:
                with db() as c:
                    allowed = c.execute(
                        """SELECT 1 FROM devices
                           WHERE token=? AND user_id IN (
                               SELECT owner FROM families WHERE id=?
                               UNION
                               SELECT user_id FROM members WHERE family=?
                           )""",
                        (token, event["family"], event["family"]),
                    ).fetchone()
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
