from __future__ import annotations

import json
import os
import re
import socket
import subprocess
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(r"C:\3EN-Agent")
WORK = ROOT / "security-privacy-stack"
STATE = ROOT / "router-pihole-final" / "state.json"
HOST = "127.0.0.1"
PORT = 8765
PI = "192.168.1.3"
ROUTER = "192.168.1.2"

HTML = r'''<!doctype html>
<html lang="pl"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>3EN Security & Privacy</title>
<style>
:root{--bg:#0b0f14;--panel:#111821;--panel2:#161f2b;--line:#263244;--text:#eef4fb;--muted:#91a2b5;--good:#48d597;--warn:#f5c15d;--bad:#ff6b7a;--accent:#6ea8fe;--accent2:#8b7cff}
*{box-sizing:border-box} body{margin:0;background:radial-gradient(circle at 20% 0,#162235 0,#0b0f14 32%);color:var(--text);font:14px/1.45 Inter,Segoe UI,Arial,sans-serif}
.shell{display:grid;grid-template-columns:220px 1fr;min-height:100vh}.side{border-right:1px solid var(--line);padding:22px 16px;background:rgba(10,15,21,.82);backdrop-filter:blur(12px);position:sticky;top:0;height:100vh}
.brand{font-size:20px;font-weight:800;letter-spacing:.4px;margin:2px 10px 28px}.brand span{color:var(--accent)}
.nav button{width:100%;text-align:left;border:0;background:transparent;color:var(--muted);padding:11px 12px;border-radius:10px;margin:3px 0;cursor:pointer}.nav button.active,.nav button:hover{background:var(--panel2);color:var(--text)}
.main{padding:28px 32px 50px;max-width:1500px;width:100%}.top{display:flex;justify-content:space-between;align-items:center;margin-bottom:22px}.title h1{font-size:26px;margin:0 0 4px}.title div{color:var(--muted)}
.pill{padding:7px 11px;border-radius:999px;background:var(--panel);border:1px solid var(--line);color:var(--muted)}.grid{display:grid;grid-template-columns:repeat(4,minmax(160px,1fr));gap:14px}.card{background:linear-gradient(180deg,var(--panel2),var(--panel));border:1px solid var(--line);border-radius:16px;padding:17px;box-shadow:0 14px 40px rgba(0,0,0,.18)}
.k{color:var(--muted);font-size:12px;text-transform:uppercase;letter-spacing:.08em}.v{font-size:26px;font-weight:760;margin:7px 0 2px}.sub{color:var(--muted);font-size:12px}.good{color:var(--good)}.warn{color:var(--warn)}.bad{color:var(--bad)}
.section{margin-top:18px}.section h2{font-size:17px;margin:0 0 12px}.toolbar{display:flex;gap:9px;flex-wrap:wrap;margin-bottom:12px}.btn,input,select{border:1px solid var(--line);background:#0e151e;color:var(--text);border-radius:10px;padding:9px 11px}.btn{cursor:pointer}.btn.primary{background:linear-gradient(135deg,var(--accent),var(--accent2));border:0;color:#07101c;font-weight:700}.btn.danger{color:#ffd9df;border-color:#57303a}.btn:hover{filter:brightness(1.08)}input{min-width:260px}
table{width:100%;border-collapse:collapse;background:var(--panel);border:1px solid var(--line);border-radius:14px;overflow:hidden}th,td{padding:11px 12px;border-bottom:1px solid var(--line);text-align:left}th{font-size:12px;color:var(--muted);background:#121a24}tr:last-child td{border-bottom:0}.tag{display:inline-block;padding:3px 7px;border-radius:999px;font-size:11px;background:#1b2735;color:#bfd0e2}.hidden{display:none}.notice{padding:12px 14px;border:1px solid var(--line);border-radius:12px;background:#101822;color:var(--muted);margin-bottom:12px}.row2{display:grid;grid-template-columns:1.15fr .85fr;gap:14px}.mono{font-family:Consolas,monospace;font-size:12px;white-space:pre-wrap;max-height:280px;overflow:auto}.footer{margin-top:28px;color:#64758a;font-size:12px;text-align:center}
@media(max-width:1000px){.shell{grid-template-columns:1fr}.side{height:auto;position:relative;border-right:0;border-bottom:1px solid var(--line)}.nav{display:flex;overflow:auto}.nav button{width:auto;white-space:nowrap}.grid{grid-template-columns:repeat(2,1fr)}.row2{grid-template-columns:1fr}.main{padding:20px}}
</style></head>
<body><div class="shell"><aside class="side"><div class="brand">3EN <span>Security</span></div><div class="nav">
<button class="active" data-tab="overview">Overview</button><button data-tab="privacy">Privacy / DNS</button><button data-tab="domains">Allow / Deny</button><button data-tab="security">Security Events</button><button data-tab="system">System</button></div></aside>
<main class="main"><div class="top"><div class="title"><h1 id="pageTitle">Network Security & Privacy</h1><div>3EN002 + Pi-hole + 3EN Agent</div></div><div class="pill" id="refreshState">refreshing…</div></div>
<section id="overview" class="tab"><div class="grid">
<div class="card"><div class="k">Router</div><div class="v" id="router">—</div><div class="sub">3EN002 / 192.168.1.2</div></div>
<div class="card"><div class="k">Pi-hole</div><div class="v" id="pihole">—</div><div class="sub">DNS / 192.168.1.3</div></div>
<div class="card"><div class="k">Filtering</div><div class="v" id="blocking">—</div><div class="sub" id="gravity">gravity: —</div></div>
<div class="card"><div class="k">Security log</div><div class="v" id="events">—</div><div class="sub">collector events</div></div></div>
<div class="section row2"><div class="card"><h2>Health</h2><div id="health" class="notice">Loading…</div><div class="toolbar"><button class="btn primary" onclick="action('refresh')">Refresh now</button><button class="btn" onclick="action('gravity')">Update filter lists</button><button class="btn danger" onclick="toggleBlocking()" id="toggleBtn">Toggle filtering</button></div></div>
<div class="card"><h2>Agent policy</h2><div class="notice">Safe changes are automatic. Every filter-policy change is backed up before gravity is rebuilt.</div><div id="policy" class="mono"></div></div></div></section>
<section id="privacy" class="tab hidden"><div class="section"><h2>Filter lists</h2><div class="notice">Recommended baseline prioritizes strong ad/tracker blocking without stacking many redundant mega-lists.</div><div class="toolbar"><button class="btn primary" onclick="action('apply_policy')">Apply recommended policy</button><button class="btn" onclick="action('gravity')">Rebuild gravity</button></div><table><thead><tr><th>ID</th><th>Source</th><th>Status</th><th>Comment</th><th></th></tr></thead><tbody id="adlists"></tbody></table></div></section>
<section id="domains" class="tab hidden"><div class="section"><h2>Domain exceptions</h2><div class="toolbar"><input id="domainInput" placeholder="example.com"><button class="btn primary" onclick="domainAction('allow')">Allow</button><button class="btn danger" onclick="domainAction('deny')">Deny</button><button class="btn" onclick="domainAction('remove')">Remove</button></div><table><thead><tr><th>Type</th><th>Domain</th><th>Enabled</th><th>Comment</th></tr></thead><tbody id="domainsTable"></tbody></table></div></section>
<section id="security" class="tab hidden"><div class="grid"><div class="card"><div class="k">Blocked log</div><div class="v" id="blockedCount">—</div></div><div class="card"><div class="k">banIP log</div><div class="v" id="banipCount">—</div></div><div class="card"><div class="k">WAN rejects</div><div class="v" id="wanCount">—</div></div><div class="card"><div class="k">Total</div><div class="v" id="totalSec">—</div></div></div><div class="section card"><h2>Recent security events</h2><div id="recentEvents" class="mono">Loading…</div></div></section>
<section id="system" class="tab hidden"><div class="section card"><h2>Detected integration</h2><div id="systemInfo" class="mono">Loading…</div></div></section>
<div class="footer">3EN Security & Privacy • local management UI • bound to 127.0.0.1 only</div></main></div>
<script>
const $=id=>document.getElementById(id); let state={};
async function api(path,opt){const r=await fetch(path,opt);const j=await r.json();if(!r.ok)throw new Error(j.error||'request failed');return j}
function cls(ok){return ok?'good':'bad'}
async function refresh(){try{const s=await api('/api/status');state=s;$('router').textContent=s.router.ok?'ONLINE':'OFFLINE';$('router').className='v '+cls(s.router.ok);$('pihole').textContent=s.pihole.dns?'HEALTHY':'DOWN';$('pihole').className='v '+cls(s.pihole.dns);$('blocking').textContent=s.pihole.blocking?'ON':'OFF';$('blocking').className='v '+(s.pihole.blocking?'good':'warn');$('gravity').textContent='gravity: '+(s.pihole.gravity||'—');$('events').textContent=s.security.total??'—';$('health').textContent=s.summary;$('policy').textContent=JSON.stringify(s.policy,null,2);$('blockedCount').textContent=s.security.blocked;$('banipCount').textContent=s.security.banip;$('wanCount').textContent=s.security.wan;$('totalSec').textContent=s.security.total;$('recentEvents').textContent=(s.security.recent||[]).join('\n')||'No events';$('systemInfo').textContent=JSON.stringify(s.integration,null,2);$('toggleBtn').textContent=s.pihole.blocking?'Disable filtering (5 min)':'Enable filtering';$('refreshState').textContent='updated '+new Date().toLocaleTimeString();await loadLists();await loadDomains()}catch(e){$('refreshState').textContent='DEGRADED';$('health').textContent=e.message}}
async function loadLists(){try{const j=await api('/api/adlists');$('adlists').innerHTML=j.items.map(x=>`<tr><td>${x.id}</td><td>${esc(x.address)}</td><td><span class="tag">${x.enabled?'enabled':'disabled'}</span></td><td>${esc(x.comment||'')}</td><td><button class="btn" onclick="toggleList(${x.id},${x.enabled?0:1})">${x.enabled?'Disable':'Enable'}</button></td></tr>`).join('')}catch(e){}}
async function loadDomains(){try{const j=await api('/api/domains');$('domainsTable').innerHTML=j.items.map(x=>`<tr><td>${x.type_name}</td><td>${esc(x.domain)}</td><td>${x.enabled}</td><td>${esc(x.comment||'')}</td></tr>`).join('')}catch(e){}}
function esc(s){return String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[m]))}
async function post(path,obj={}){return api(path,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(obj)})}
async function action(a){$('refreshState').textContent='working…';try{await post('/api/action',{action:a});await refresh()}catch(e){alert(e.message);await refresh()}}
async function toggleBlocking(){await action(state.pihole&&state.pihole.blocking?'disable5':'enable')}
async function toggleList(id,enabled){try{await post('/api/adlist',{id,enabled});await refresh()}catch(e){alert(e.message)}}
async function domainAction(actionName){const domain=$('domainInput').value.trim();if(!domain)return;try{await post('/api/domain',{action:actionName,domain});$('domainInput').value='';await refresh()}catch(e){alert(e.message)}}
document.querySelectorAll('.nav button').forEach(b=>b.onclick=()=>{document.querySelectorAll('.nav button').forEach(x=>x.classList.remove('active'));b.classList.add('active');document.querySelectorAll('.tab').forEach(x=>x.classList.add('hidden'));$(b.dataset.tab).classList.remove('hidden')});
refresh();setInterval(refresh,15000);
</script></body></html>'''


def load_state():
    if not STATE.exists():
        return {}
    try:
        return json.loads(STATE.read_text(encoding="utf-8-sig"))
    except Exception:
        return {}


def ssh(command: str, timeout: int = 12) -> str:
    st = load_state()
    user = st.get("piUser") or "pi"
    key = st.get("piKey") or ""
    if not st.get("piSsh") or not key:
        raise RuntimeError("Pi-hole SSH was not auto-discovered")
    args = ["ssh.exe", "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", f"{user}@{PI}", command]
    p = subprocess.run(args, capture_output=True, text=True, timeout=timeout, encoding="utf-8", errors="replace")
    if p.returncode != 0:
        raise RuntimeError((p.stderr or p.stdout or "SSH failed").strip())
    return p.stdout.strip()


def tcp(host: str, port: int, timeout=1.2) -> bool:
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except OSError:
        return False


def dns_ok() -> bool:
    try:
        p = subprocess.run(["nslookup", "example.com", PI], capture_output=True, text=True, timeout=5)
        return p.returncode == 0 and "Address" in p.stdout
    except Exception:
        return False


def sql(db: str, query: str) -> str:
    q = query.replace("'", "'\\''")
    return ssh(f"pihole-FTL sqlite3 {db} '{q}'", 15)


def counts():
    files = {
        "blocked": "/var/log/3en-remote/3en-blocked.log",
        "banip": "/var/log/3en-remote/banip.log",
        "wan": "/var/log/3en-remote/wan-reject.log",
    }
    out = {}
    for k, f in files.items():
        try:
            v = ssh(f"test -f {f} && wc -l < {f} || echo 0")
            out[k] = int(v.strip().splitlines()[-1])
        except Exception:
            out[k] = 0
    out["total"] = sum(out.values())
    try:
        recent = ssh("tail -n 6 /var/log/3en-remote/3en-blocked.log 2>/dev/null; tail -n 6 /var/log/3en-remote/banip.log 2>/dev/null; tail -n 6 /var/log/3en-remote/wan-reject.log 2>/dev/null")
        out["recent"] = [x for x in recent.splitlines() if x][-18:]
    except Exception:
        out["recent"] = []
    return out


def pihole_stats():
    result = {"dns": dns_ok(), "blocking": False, "gravity": None, "adlists": None}
    try:
        status = ssh("pihole status 2>/dev/null || true")
        low = status.lower()
        result["blocking"] = ("blocking is enabled" in low) or ("enabled" in low and "disabled" not in low)
        g = sql("/etc/pihole/gravity.db", "SELECT COUNT(DISTINCT domain) FROM gravity;")
        result["gravity"] = int(g.strip() or 0)
        a = sql("/etc/pihole/gravity.db", "SELECT COUNT(*) FROM adlist WHERE enabled=1;")
        result["adlists"] = int(a.strip() or 0)
    except Exception:
        pass
    return result


def adlists():
    raw = sql("/etc/pihole/gravity.db", "SELECT id,address,enabled,COALESCE(comment,'') FROM adlist ORDER BY id;")
    items = []
    for line in raw.splitlines():
        p = line.split("|", 3)
        if len(p) >= 3:
            items.append({"id": int(p[0]), "address": p[1], "enabled": p[2] == "1", "comment": p[3] if len(p) > 3 else ""})
    return items


def domains():
    raw = sql("/etc/pihole/gravity.db", "SELECT type,domain,enabled,COALESCE(comment,'') FROM domainlist ORDER BY id DESC LIMIT 200;")
    names = {0: "ALLOW", 1: "DENY", 2: "ALLOW REGEX", 3: "DENY REGEX"}
    items = []
    for line in raw.splitlines():
        p = line.split("|", 3)
        if len(p) >= 3:
            t = int(p[0]); items.append({"type": t, "type_name": names.get(t, str(t)), "domain": p[1], "enabled": p[2], "comment": p[3] if len(p) > 3 else ""})
    return items


def validate_domain(d: str):
    if len(d) > 253 or not re.fullmatch(r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}", d):
        raise ValueError("Invalid domain")


def remote_backup(tag="gui"):
    ts = int(time.time())
    dest = f"/var/backups/3en-security-privacy/gravity-{tag}-{ts}.db"
    ssh(f"sudo mkdir -p /var/backups/3en-security-privacy && sudo cp /etc/pihole/gravity.db {dest}")
    return dest


def apply_policy():
    backup = remote_backup("policy")
    recommended = [
        ("https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/pro.txt", "3EN recommended: HaGeZi Pro ads+tracking"),
        ("https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/tif.txt", "3EN recommended: HaGeZi TIF security"),
    ]
    now = int(time.time())
    for url, comment in recommended:
        eu = url.replace("'", "''"); ec = comment.replace("'", "''")
        q = f"INSERT OR IGNORE INTO adlist (address,enabled,date_added,date_modified,comment) VALUES ('{eu}',1,{now},{now},'{ec}'); UPDATE adlist SET enabled=1,comment='{ec}',date_modified={now} WHERE address='{eu}';"
        sql("/etc/pihole/gravity.db", q)
    try:
        ssh("pihole updateGravity", 180)
    except Exception:
        ssh(f"sudo cp {backup} /etc/pihole/gravity.db && pihole reloadlists", 30)
        raise
    return backup


def set_adlist(idx: int, enabled: int):
    if enabled not in (0, 1):
        raise ValueError("enabled must be 0/1")
    remote_backup("toggle")
    now = int(time.time())
    sql("/etc/pihole/gravity.db", f"UPDATE adlist SET enabled={enabled},date_modified={now} WHERE id={int(idx)};")
    ssh("pihole updateGravity", 180)


def domain_action(action: str, domain: str):
    validate_domain(domain)
    remote_backup("domain")
    if action == "allow":
        ssh(f"pihole allow {domain}")
    elif action == "deny":
        ssh(f"pihole deny {domain}")
    elif action == "remove":
        ssh(f"pihole allow remove {domain} >/dev/null 2>&1 || true; pihole deny remove {domain} >/dev/null 2>&1 || true")
    else:
        raise ValueError("unknown action")


def status_payload():
    st = load_state(); ph = pihole_stats(); sec = counts(); r_ok = tcp(ROUTER, 22)
    policy = {"profile": "Balanced-Strong", "lists": ["HaGeZi Pro", "HaGeZi TIF"], "rollback": True, "autoGravity": True}
    healthy = r_ok and ph.get("dns")
    summary = "HEALTHY — router, Pi-hole DNS and management path are responding." if healthy else "DEGRADED — one or more health checks failed; agent diagnostics are required."
    return {"router": {"ok": r_ok}, "pihole": ph, "security": sec, "policy": policy, "summary": summary,
            "integration": {"router": ROUTER, "pihole": PI, "piSsh": bool(st.get("piSsh")), "piUser": st.get("piUser"), "stateFile": str(STATE), "ui": f"http://{HOST}:{PORT}"}}


class Handler(BaseHTTPRequestHandler):
    server_version = "3ENSecurityPrivacy/1.0"
    def log_message(self, fmt, *args):
        pass
    def send_json(self, obj, code=200):
        data = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code); self.send_header("Content-Type", "application/json; charset=utf-8"); self.send_header("Cache-Control", "no-store"); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def read_json(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}
    def do_GET(self):
        try:
            p = urllib.parse.urlparse(self.path).path
            if p == "/":
                d = HTML.encode("utf-8"); self.send_response(200); self.send_header("Content-Type", "text/html; charset=utf-8"); self.send_header("Content-Length", str(len(d))); self.end_headers(); self.wfile.write(d); return
            if p == "/api/status": return self.send_json(status_payload())
            if p == "/api/adlists": return self.send_json({"items": adlists()})
            if p == "/api/domains": return self.send_json({"items": domains()})
            return self.send_json({"error": "not found"}, 404)
        except Exception as e:
            return self.send_json({"error": str(e)}, 500)
    def do_POST(self):
        try:
            p = urllib.parse.urlparse(self.path).path; body = self.read_json()
            if p == "/api/action":
                a = body.get("action")
                if a == "gravity": ssh("pihole updateGravity", 180)
                elif a == "apply_policy": apply_policy()
                elif a == "enable": ssh("pihole enable")
                elif a == "disable5": ssh("pihole disable 5m")
                elif a == "refresh": pass
                else: raise ValueError("unknown action")
                return self.send_json({"ok": True})
            if p == "/api/domain":
                domain_action(str(body.get("action", "")), str(body.get("domain", "")).strip().lower()); return self.send_json({"ok": True})
            if p == "/api/adlist":
                set_adlist(int(body["id"]), int(body["enabled"])); return self.send_json({"ok": True})
            return self.send_json({"error": "not found"}, 404)
        except Exception as e:
            return self.send_json({"error": str(e)}, 500)


def main():
    WORK.mkdir(parents=True, exist_ok=True)
    srv = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"3EN_SECURITY_PRIVACY_UI=http://{HOST}:{PORT}", flush=True)
    srv.serve_forever()

if __name__ == "__main__":
    main()
