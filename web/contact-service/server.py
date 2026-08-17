#!/usr/bin/env python3
"""Backend mínimo de omnimount.es (formulario de contacto + descarga verificada).

POST /api/contact   {name, email, message, web(honeypot)}
    Guarda en /var/lib/omnimount-contact/messages.jsonl (fuente de verdad) y
    reenvía por SMTP en segundo plano.

GET  /api/download?txn=txn_...
    Verifica contra la API de Paddle que la transacción existe y está pagada
    y, si lo está, entrega el instalador vía X-Accel-Redirect (nginx sirve el
    fichero desde una ruta interna no pública). Sin PADDLE_API_KEY configurada
    opera en "modo gracia": entrega si el formato del id es válido (evita
    bloquear a compradores mientras se configura la clave).

Configuración por entorno (unidad systemd del servidor, nunca en el repo):
    CONTACT_DEST, SMTP_HOST, SMTP_PORT, SMTP_USER, SMTP_PASS, MAIL_FROM,
    PADDLE_API_KEY (opcional al principio)
Sin dependencias externas: solo la librería estándar.
"""
import json
import os
import re
import smtplib
import threading
import time
import urllib.request
from email.message import EmailMessage
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

DEST = os.environ["CONTACT_DEST"]
SMTP_HOST = os.environ.get("SMTP_HOST", "")
SMTP_PORT = int(os.environ.get("SMTP_PORT", "587"))
SMTP_USER = os.environ.get("SMTP_USER", "")
SMTP_PASS = os.environ.get("SMTP_PASS", "")
MAIL_FROM = os.environ.get("MAIL_FROM", SMTP_USER)
PADDLE_API_KEY = os.environ.get("PADDLE_API_KEY", "")

STORE = Path("/var/lib/omnimount-contact/messages.jsonl")
PKG_INTERNAL = "/protected/Omnimount.pkg"  # location interna de nginx
MAX_LEN = {"name": 200, "email": 320, "message": 5000}
TXN_RE = re.compile(r"^txn_[a-z0-9]{20,40}$")
RATE: dict = {}


def rate_limited(ip, limit=10):
    now = time.time()
    hits = [t for t in RATE.get(ip, []) if now - t < 3600]
    RATE[ip] = hits + [now]
    return len(hits) >= limit


def forward_async(entry):
    def run():
        if not SMTP_HOST:
            print("forward omitido: SMTP_HOST sin configurar", flush=True)
            return
        msg = EmailMessage()
        msg["Subject"] = f"[omnimount.es] Contacto de {entry['name']}"
        msg["From"] = MAIL_FROM
        msg["To"] = DEST
        msg["Reply-To"] = entry["email"]
        msg.set_content(
            f"Nombre: {entry['name']}\nEmail: {entry['email']}\n\n{entry['message']}"
        )
        try:
            with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=20) as s:
                s.starttls()
                if SMTP_USER:
                    s.login(SMTP_USER, SMTP_PASS)
                s.send_message(msg)
            print("contacto reenviado ok", flush=True)
        except Exception as e:
            print(f"fallo reenviando contacto: {e}", flush=True)

    threading.Thread(target=run, daemon=True).start()


def paddle_transaction_paid(txn: str):
    """True/False según la API de Paddle; None si no se pudo verificar."""
    req = urllib.request.Request(
        f"https://api.paddle.com/transactions/{txn}",
        headers={"Authorization": f"Bearer {PADDLE_API_KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())
        return data.get("data", {}).get("status") in ("paid", "completed", "billed")
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return False
        return None
    except Exception:
        return None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _reply(self, code, body, extra=None):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        url = urlparse(self.path)
        if url.path != "/api/download":
            return self._reply(404, {"ok": False})
        ip = self.headers.get("X-Real-IP", self.client_address[0])
        if rate_limited("dl:" + ip, limit=20):
            return self._reply(429, {"ok": False, "error": "rate"})
        txn = (parse_qs(url.query).get("txn") or [""])[0]
        if not TXN_RE.match(txn):
            return self._reply(403, {"ok": False, "error": "txn"})

        if PADDLE_API_KEY:
            paid = paddle_transaction_paid(txn)
            if paid is False:
                return self._reply(403, {"ok": False, "error": "unpaid"})
            if paid is None:
                print(f"aviso: Paddle inaccesible, entrego {txn} sin verificar", flush=True)
        else:
            print(f"modo gracia: entrego {txn} sin PADDLE_API_KEY", flush=True)

        # nginx sirve el fichero desde la location interna.
        self.send_response(200)
        self.send_header("X-Accel-Redirect", PKG_INTERNAL)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Disposition", 'attachment; filename="Omnimount.pkg"')
        self.end_headers()

    def do_POST(self):
        if self.path != "/api/contact":
            return self._reply(404, {"ok": False})
        ip = self.headers.get("X-Real-IP", self.client_address[0])
        if rate_limited("ct:" + ip, limit=5):
            return self._reply(429, {"ok": False, "error": "rate"})
        try:
            length = min(int(self.headers.get("Content-Length", 0)), 32768)
            data = json.loads(self.rfile.read(length))
        except Exception:
            return self._reply(400, {"ok": False, "error": "json"})

        if data.get("web"):  # honeypot
            return self._reply(200, {"ok": True})

        entry = {}
        for field, limit in MAX_LEN.items():
            value = str(data.get(field, "")).strip()[:limit]
            if not value:
                return self._reply(400, {"ok": False, "error": field})
            entry[field] = value
        if not re.match(r"^[^@\s]+@[^@\s]+\.[^@\s]+$", entry["email"]):
            return self._reply(400, {"ok": False, "error": "email"})

        entry["ts"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        entry["ip"] = ip
        STORE.parent.mkdir(parents=True, exist_ok=True)
        with STORE.open("a") as f:
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")
        forward_async(entry)
        return self._reply(200, {"ok": True})


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", 8090), Handler).serve_forever()
