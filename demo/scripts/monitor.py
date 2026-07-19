#!/usr/bin/env python3
"""demo monitor — synthetic health probe + auto-heal + Discord alerting.

Runs every few minutes (cron over SSH, or a gui LaunchAgent from the console —
see setup-monitor.sh). Checks the REAL failure surfaces, not just a liveness ping:

  1. tunnel_http  — GET https://demo.millfolio.app/api/model must be 200 AND carry a
                    turnstile_sitekey (proves the tunnel + app + Turnstile config).
  2. server_local — GET http://127.0.0.1:10010/health (the demo app-server).
  3. ws_local     — a REAL WebSocket round-trip to ws://127.0.0.1:10010/chat: open,
                    send an `ask`, read a frame back. Proves the WS handler works
                    (a plain HTTP ping stays green when only WS is broken).
  4. engine       — a tiny decode against :8001 measuring tok/s. THE point: the
                    decode wedge leaves /v1/models green (~0.5ms) while decode drops
                    to ~0.3 tok/s. We key on DECODE, alerting below ENGINE_FLOOR_TOKS.

Auto-heal (only after N consecutive fails, with a per-service cooldown):
  • server/ws down     → sudo -n launchctl kickstart system/app.millfolio.demo
                         (a scoped NOPASSWD rule; works from cron/SSH/agent).
  • engine wedged/down → launchctl kickstart -k gui/<uid>/app.millfolio.demo-engine
                         (ONLY works when this process runs in the gui domain — i.e.
                         installed as a gui LaunchAgent from the console; from cron it
                         fails "domain does not support" → we alert instead).
  • tunnel down (local ok) → alert only (cloudflared isn't safely restartable here).

Alerts go to DISCORD_WEBHOOK_URL (config below) on state transitions (healthy↔down)
and as a reminder every ALERT_REMINDER_S while still down. No webhook set → log only.

Config: ~/.config/millfolio/demo-monitor.env  (KEY=VALUE lines; see .example).
State:  ~/.config/millfolio/demo-monitor.state.json
Pure stdlib — no pip deps on bgent.
"""

import base64
import json
import os
import socket
import ssl
import struct
import subprocess
import sys
import time
import urllib.request

HOME = os.path.expanduser("~")
CFG_DIR = os.path.join(HOME, ".config", "millfolio")
ENV_FILE = os.path.join(CFG_DIR, "demo-monitor.env")
STATE_FILE = os.path.join(CFG_DIR, "demo-monitor.state.json")
LOG_FILE = os.path.join(CFG_DIR, "demo-monitor.log")


def load_env():
    cfg = {
        "DISCORD_WEBHOOK_URL": "",
        "PUBLIC_URL": "https://demo.millfolio.app",
        "LOCAL_APP": "http://127.0.0.1:10010",
        "ENGINE_URL": "http://127.0.0.1:8001",
        "ENGINE_MODEL": "Qwen/Qwen2.5-3B-Instruct",
        "ENGINE_FLOOR_TOKS": "2.0",
        "ENGINE_PROBE_TOKENS": "16",
        "ENGINE_TIMEOUT_S": "45",
        "WS_TIMEOUT_S": "12",
        "HTTP_TIMEOUT_S": "10",
        "FAILS_BEFORE_HEAL": "2",
        "HEAL_COOLDOWN_S": "900",
        "ALERT_REMINDER_S": "1800",
        "DEMO_DAEMON": "system/app.millfolio.demo",
        "ENGINE_AGENT": "app.millfolio.demo-engine",
        "HEAL_DEMO": "1",
        "HEAL_ENGINE": "1",
    }
    try:
        with open(ENV_FILE) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    except FileNotFoundError:
        pass
    return cfg


def log(msg):
    line = time.strftime("%Y-%m-%dT%H:%M:%S") + " " + msg
    print(line, flush=True)
    try:
        os.makedirs(CFG_DIR, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
        # keep the log bounded (~2000 lines)
        _trim_log()
    except OSError:
        pass


def _trim_log():
    try:
        with open(LOG_FILE) as f:
            lines = f.readlines()
        if len(lines) > 2000:
            with open(LOG_FILE, "w") as f:
                f.writelines(lines[-2000:])
    except OSError:
        pass


# ── checks ────────────────────────────────────────────────────────────────────
def http_get(url, timeout, want_substr=None):
    try:
        ctx = ssl.create_default_context()
        req = urllib.request.Request(url, headers={"User-Agent": "demo-monitor/1"})
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
            body = r.read(65536).decode("utf-8", "replace")
            ok = r.status == 200 and (want_substr is None or want_substr in body)
            return ok, r.status, body
    except Exception as e:
        return False, None, "%s: %s" % (type(e).__name__, str(e)[:120])


def ws_roundtrip(app_base, timeout):
    """Minimal RFC6455 client over plain TCP (ws://, no TLS): handshake → send one
    masked text `ask` frame → read one frame back. Any well-formed frame = healthy
    (the demo's 'human check' error frame is a perfectly good liveness signal)."""
    host = app_base.split("://", 1)[-1]
    if "/" in host:
        host = host.split("/", 1)[0]
    hostname, _, port = host.partition(":")
    port = int(port or "80")
    s = None
    try:
        s = socket.create_connection((hostname, port), timeout=timeout)
        s.settimeout(timeout)
        key = base64.b64encode(os.urandom(16)).decode()
        req = (
            "GET /chat HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\n"
            "Connection: Upgrade\r\nSec-WebSocket-Key: %s\r\n"
            "Sec-WebSocket-Version: 13\r\nOrigin: http://%s\r\n\r\n"
        ) % (host, key, host)
        s.sendall(req.encode())
        # read headers
        buf = b""
        while b"\r\n\r\n" not in buf:
            chunk = s.recv(4096)
            if not chunk:
                return False, "handshake: connection closed"
            buf += chunk
            if len(buf) > 65536:
                return False, "handshake: headers too large"
        head = buf.split(b"\r\n\r\n", 1)[0].decode("latin1")
        if "101" not in head.split("\r\n", 1)[0]:
            return False, "handshake: no 101 (%s)" % head.split("\r\n", 1)[0][:60]
        # send a masked text frame with the ask payload
        payload = json.dumps({"type": "ask", "id": "monitor", "text": "how many transactions do I have"}).encode()
        mask = os.urandom(4)
        masked = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
        header = bytes([0x81])  # FIN + text
        n = len(payload)
        if n < 126:
            header += bytes([0x80 | n])
        elif n < 65536:
            header += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            header += bytes([0x80 | 127]) + struct.pack(">Q", n)
        s.sendall(header + mask + masked)
        # read one frame back (server frames are unmasked)
        b2 = _recv_exact(s, 2)
        if b2 is None:
            return False, "no reply frame (socket closed after upgrade)"
        ln = b2[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", _recv_exact(s, 2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", _recv_exact(s, 8))[0]
        data = _recv_exact(s, ln) if ln else b""
        if data is None:
            return False, "reply frame truncated"
        return True, data.decode("utf-8", "replace")[:120]
    except Exception as e:
        return False, "%s: %s" % (type(e).__name__, str(e)[:100])
    finally:
        if s:
            try:
                s.close()
            except OSError:
                pass


def _recv_exact(s, n):
    out = b""
    while len(out) < n:
        chunk = s.recv(n - len(out))
        if not chunk:
            return None
        out += chunk
    return out


def engine_decode(cfg):
    """Tiny decode; returns (ok, toks_per_s, detail). ok=False on error/timeout/wedge."""
    url = cfg["ENGINE_URL"].rstrip("/") + "/v1/chat/completions"
    body = json.dumps({
        "model": cfg["ENGINE_MODEL"],
        "messages": [{"role": "user", "content": "Count from 1 to 16."}],
        "max_tokens": int(cfg["ENGINE_PROBE_TOKENS"]),
        "temperature": 0,
    }).encode()
    floor = float(cfg["ENGINE_FLOOR_TOKS"])
    t0 = time.time()
    try:
        req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=float(cfg["ENGINE_TIMEOUT_S"])) as r:
            d = json.loads(r.read())
        elapsed = max(time.time() - t0, 0.05)
        ct = d.get("usage", {}).get("completion_tokens", 0)
        toks = ct / elapsed
        ok = ct > 0 and toks >= floor
        return ok, round(toks, 2), "%d tok in %.1fs" % (ct, elapsed)
    except Exception as e:
        elapsed = time.time() - t0
        return False, 0.0, "%s in %.1fs: %s" % (type(e).__name__, elapsed, str(e)[:80])


# ── heal ────────────────────────────────────────────────────────────────────
def heal_demo_daemon(cfg):
    daemon = cfg["DEMO_DAEMON"]
    r = subprocess.run(["sudo", "-n", "launchctl", "kickstart", "-k", daemon],
                       capture_output=True, text=True, timeout=30)
    if r.returncode == 0:
        return True, "kickstarted %s" % daemon
    return False, "kickstart %s failed: %s" % (daemon, (r.stderr or r.stdout).strip()[:100])


def heal_engine(cfg):
    uid = os.getuid()
    target = "gui/%d/%s" % (uid, cfg["ENGINE_AGENT"])
    r = subprocess.run(["launchctl", "kickstart", "-k", target],
                       capture_output=True, text=True, timeout=30)
    if r.returncode == 0:
        return True, "kickstarted %s" % target
    err = (r.stderr or r.stdout).strip()
    if "Domain does not support" in err or "125" in err:
        return False, ("engine auto-heal unavailable in this context (not gui domain). "
                       "Run from bgent console: launchctl kickstart -k %s — or reboot." % target)
    return False, "kickstart %s failed: %s" % (target, err[:100])


# ── state ─────────────────────────────────────────────────────────────────────
def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"status": "unknown", "streak": {}, "last_heal": {}, "last_alert": 0, "down_since": 0}


def save_state(st):
    try:
        os.makedirs(CFG_DIR, exist_ok=True)
        tmp = STATE_FILE + ".tmp"
        with open(tmp, "w") as f:
            json.dump(st, f)
        os.replace(tmp, STATE_FILE)
    except OSError:
        pass


def discord(cfg, content):
    url = cfg["DISCORD_WEBHOOK_URL"].strip()
    if not url:
        log("  (no DISCORD_WEBHOOK_URL — alert logged only)")
        return
    try:
        data = json.dumps({"content": content[:1900]}).encode()
        req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=10).read()
    except Exception as e:
        log("  Discord post failed: %s" % (str(e)[:100]))


# ── main ──────────────────────────────────────────────────────────────────────
def main():
    cfg = load_env()
    now = time.time()
    st = load_state()
    streak = st.get("streak", {})
    last_heal = st.get("last_heal", {})

    tunnel_ok, tstatus, tbody = http_get(cfg["PUBLIC_URL"].rstrip("/") + "/api/model",
                                         float(cfg["HTTP_TIMEOUT_S"]), "turnstile_sitekey")
    server_ok, sstatus, _ = http_get(cfg["LOCAL_APP"].rstrip("/") + "/health", float(cfg["HTTP_TIMEOUT_S"]))
    ws_ok, wsdetail = ws_roundtrip(cfg["LOCAL_APP"], float(cfg["WS_TIMEOUT_S"]))
    eng_ok, eng_toks, eng_detail = engine_decode(cfg)

    checks = {"tunnel": tunnel_ok, "server": server_ok, "ws": ws_ok, "engine": eng_ok}
    fails = [k for k, v in checks.items() if not v]
    healthy = not fails

    log("check: tunnel=%s server=%s ws=%s engine=%s(%.2f tok/s) %s" % (
        tunnel_ok, server_ok, ws_ok, eng_ok, eng_toks,
        "" if healthy else "FAILS=" + ",".join(fails)))
    if not ws_ok:
        log("  ws detail: " + str(wsdetail))
    if not eng_ok:
        log("  engine detail: " + str(eng_detail))
    if not tunnel_ok:
        log("  tunnel detail: status=%s %s" % (tstatus, str(tbody)[:100]))

    # update streaks; reset the engine heal-episode counter once the engine recovers
    for k, v in checks.items():
        streak[k] = 0 if v else streak.get(k, 0) + 1
    if checks["engine"]:
        st["engine_heal_episode"] = 0

    # ── heal (after N consecutive fails, cooldown-gated; role-gated per host) ──
    # HEAL_DEMO / HEAL_ENGINE let a two-user demo split responsibility: the engine
    # runs as one user (gui-domain kickstart), the demo daemon heals via a scoped sudo
    # rule under another — so each monitor only attempts the heal it actually can do.
    n = int(cfg["FAILS_BEFORE_HEAL"])
    cooldown = float(cfg["HEAL_COOLDOWN_S"])
    do_demo = cfg.get("HEAL_DEMO", "1") == "1"
    do_engine = cfg.get("HEAL_ENGINE", "1") == "1"
    heal_notes = []
    engine_reboot_needed = False

    def can_heal(svc):
        return now - last_heal.get(svc, 0) >= cooldown

    # server/ws → demo daemon (a restart normally clears an app-server crash/hang)
    if do_demo and (streak.get("server", 0) >= n or streak.get("ws", 0) >= n):
        if can_heal("demo"):
            hok, hmsg = heal_demo_daemon(cfg)
            last_heal["demo"] = now
            heal_notes.append(("demo daemon", hok, hmsg))
            log("  HEAL demo: %s — %s" % ("ok" if hok else "FAIL", hmsg))
        else:
            heal_notes.append(("demo daemon", None, "in cooldown"))

    # engine wedge → kickstart ONCE per episode. The decode wedge survives a process
    # restart (observed), so if it's still wedged after that one kickstart, stop bouncing
    # the engine and escalate: a REBOOT is required. (episode resets when it recovers.)
    if do_engine and streak.get("engine", 0) >= n:
        ep = st.get("engine_heal_episode", 0)
        if ep == 0 and can_heal("engine"):
            hok, hmsg = heal_engine(cfg)
            last_heal["engine"] = now
            st["engine_heal_episode"] = 1
            heal_notes.append(("engine", hok, hmsg))
            log("  HEAL engine: %s — %s" % ("ok" if hok else "FAIL", hmsg))
        elif ep >= 1:
            engine_reboot_needed = True
            heal_notes.append(("engine", False,
                "kickstarted once this episode and decode is STILL wedged — a process "
                "restart does not clear this wedge, a REBOOT is required"))
            log("  ENGINE still wedged after a kickstart → REBOOT REQUIRED (no re-kick)")

    # ── alert (transition or reminder) ──
    prev = st.get("status", "unknown")
    cur = "healthy" if healthy else "down"
    transitioned = (cur != prev)
    reminder_due = (not healthy) and (now - st.get("last_alert", 0) >= float(cfg["ALERT_REMINDER_S"]))
    version = ""
    if tunnel_ok:
        try:
            version = json.loads(tbody).get("version", "")
        except ValueError:
            pass

    if transitioned or reminder_due:
        if healthy:
            downfor = int(now - st.get("down_since", now))
            msg = "✅ demo.millfolio.app RECOVERED (was down ~%ds). All checks green." % downfor
        else:
            lines = ["🔴 demo.millfolio.app DEGRADED — failing: %s" % ", ".join(fails)]
            if engine_reboot_needed:
                lines.append("⚠️ REBOOT REQUIRED — engine decode wedge survived a restart.")
            if "engine" in fails:
                lines.append("• engine decode %.2f tok/s (floor %s) — %s" % (eng_toks, cfg["ENGINE_FLOOR_TOKS"], eng_detail))
            if "ws" in fails:
                lines.append("• ws round-trip: %s" % wsdetail)
            if "server" in fails:
                lines.append("• app-server /health status=%s" % sstatus)
            if "tunnel" in fails:
                lines.append("• tunnel /api/model status=%s" % tstatus)
            for name, ok, m in heal_notes:
                tag = "healed" if ok else ("cooldown" if ok is None else "heal FAILED")
                lines.append("• %s: %s — %s" % (name, tag, m))
            if version:
                lines.append("(running %s)" % version)
            msg = "\n".join(lines)
        log("ALERT (%s): %s" % ("transition" if transitioned else "reminder", msg.replace("\n", " | ")))
        discord(cfg, msg)
        st["last_alert"] = now

    if healthy:
        st["down_since"] = 0
    elif prev == "healthy" or not st.get("down_since"):
        st["down_since"] = now

    st["status"] = cur
    st["streak"] = streak
    st["last_heal"] = last_heal
    save_state(st)
    sys.exit(0 if healthy else 1)


if __name__ == "__main__":
    main()
