from __future__ import annotations
import json, ipaddress, os, re, subprocess, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT=Path(r'C:\3EN-Agent')
WORK=ROOT/'security-monitor-integration'
WORK.mkdir(parents=True,exist_ok=True)
DISC=WORK/'discovery.json'
AUDIT=WORK/'actions.jsonl'
ROUTER='192.168.1.2'
ROUTER_USER='root'
ROUTER_KEY=Path(r'C:\Users\wi3lk\.ssh\3en002_agent_ed25519')
HOST='127.0.0.1'; PORT=8766

HTML='''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>3EN Threat Control</title><style>body{font:14px Segoe UI,Arial;background:#0b0f14;color:#eef4fb;margin:0;padding:20px}h1{margin-top:0}.bar{display:flex;gap:8px;flex-wrap:wrap;margin:12px 0}.btn{background:#162235;border:1px solid #2c3d52;color:#eef4fb;border-radius:8px;padding:8px 12px;cursor:pointer}.danger{background:#5b1f29}.ok{color:#48d597}.warn{color:#f5c15d}table{width:100%;border-collapse:collapse;background:#111821}th,td{padding:9px;border-bottom:1px solid #263244;text-align:left}th{color:#91a2b5}.muted{color:#91a2b5}.pill{padding:3px 7px;border:1px solid #3a4a5e;border-radius:999px}</style></head><body><h1>3EN Threat Control</h1><div id="status" class="muted">loading...</div><div class="bar"><button class="btn danger" onclick="act('block')">Block selected</button><button class="btn" onclick="act('unblock')">Unblock selected</button><button class="btn" onclick="load()">Refresh</button></div><table><thead><tr><th></th><th>IP</th><th>Attempts</th><th>Blocked</th><th>Source</th><th>Evidence</th></tr></thead><tbody id="rows"></tbody></table><script>
async function api(p,o){let r=await fetch(p,o);let j=await r.json();if(!r.ok)throw new Error(j.error||'request failed');return j}
async function load(){try{let s=await api('/api/status');document.getElementById('status').innerHTML=`source: <span class="pill">${s.source||'none'}</span> • router SSH: ${s.routerSsh?'OK':'NO'} • threats: ${s.items.length}`;document.getElementById('rows').innerHTML=s.items.map(x=>`<tr><td><input type="checkbox" value="${x.ip}"></td><td>${x.ip}</td><td>${x.attempts}</td><td class="${x.blocked?'ok':'muted'}">${x.blocked?'YES':'NO'}</td><td>${x.source||''}</td><td>${(x.evidence||'').slice(0,120)}</td></tr>`).join('')}catch(e){document.getElementById('status').textContent=e.message}}
async function act(a){let ips=[...document.querySelectorAll('tbody input:checked')].map(x=>x.value);if(!ips.length)return;try{await api('/api/action',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({action:a,ips})});await load()}catch(e){alert(e.message)}}
load();setInterval(load,15000)</script></body></html>'''

def run(cmd, timeout=20):
    p=subprocess.run(cmd,capture_output=True,text=True,timeout=timeout,encoding='utf-8',errors='replace')
    if p.returncode!=0: raise RuntimeError((p.stderr or p.stdout or 'command failed').strip())
    return p.stdout.strip()

def ssh(command, timeout=20):
    if not ROUTER_KEY.exists(): raise RuntimeError('router SSH key missing')
    return run(['ssh.exe','-i',str(ROUTER_KEY),'-o','BatchMode=yes','-o','ConnectTimeout=5','-o','StrictHostKeyChecking=accept-new',f'{ROUTER_USER}@{ROUTER}',command],timeout)

def router_ok():
    try: return 'OK' in ssh("printf OK",8)
    except Exception: return False

def discover_source():
    candidates=[]
    roots=[ROOT,Path(r'E:\skrypty'),Path.home()/'Desktop',Path.home()/'Documents']
    pats=['3en-threats.json','*threat*.json','*security*.json']
    for base in roots:
        if not base.exists(): continue
        for pat in pats:
            try:
                for p in base.rglob(pat):
                    if p.is_file() and p.stat().st_size<50_000_000: candidates.append(p)
            except Exception: pass
    seen=[]
    for p in candidates:
        if str(p).lower() not in [x.lower() for x in seen]: seen.append(str(p))
    seen.sort(key=lambda x:(Path(x).name.lower()!='3en-threats.json',-Path(x).stat().st_mtime if Path(x).exists() else 0))
    return seen[0] if seen else ''

def load_json(path):
    try: return json.loads(Path(path).read_text(encoding='utf-8-sig'))
    except Exception: return None

IP_RE=re.compile(r'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')
def valid_ip(s):
    try: ipaddress.ip_address(s); return True
    except Exception: return False

def flatten(obj, out, source=''):
    if isinstance(obj,dict):
        ip=''
        for k in ('ip','src','source_ip','remote_ip','address','host'):
            v=obj.get(k)
            if isinstance(v,str):
                m=IP_RE.search(v)
                if m and valid_ip(m.group()): ip=m.group(); break
        if not ip:
            blob=' '.join(str(v) for v in obj.values() if isinstance(v,(str,int,float)))
            m=IP_RE.search(blob)
            if m and valid_ip(m.group()): ip=m.group()
        if ip:
            attempts=1
            for k in ('attempts','count','hits','tries','scans','events','probe_count'):
                try:
                    if k in obj: attempts=max(1,int(obj[k])); break
                except Exception: pass
            ev='; '.join(f'{k}={v}' for k,v in list(obj.items())[:8] if isinstance(v,(str,int,float,bool)))
            out.setdefault(ip,{'ip':ip,'attempts':0,'source':source,'evidence':''})
            out[ip]['attempts']+=attempts
            if ev: out[ip]['evidence']=ev
        for v in obj.values(): flatten(v,out,source)
    elif isinstance(obj,list):
        for v in obj: flatten(v,out,source)

def blocked_set():
    try:
        raw=ssh("uci -q get firewall.3en_manual_block.entry 2>/dev/null || true",10)
        return {x for x in re.findall(r'(?:\d{1,3}\.){3}\d{1,3}',raw) if valid_ip(x)}
    except Exception: return set()

def ensure_firewall():
    exists=ssh("uci -q get firewall.3en_manual_block.name 2>/dev/null || true",10)
    if exists.strip()=='3en_manual_block': return
    stamp=time.strftime('%Y%m%d-%H%M%S')
    ssh(f"cp /etc/config/firewall /etc/config/firewall.3en-security-monitor-{stamp}.bak && uci set firewall.3en_manual_block=ipset && uci set firewall.3en_manual_block.name='3en_manual_block' && uci set firewall.3en_manual_block.family='ipv4' && uci -q delete firewall.3en_manual_block.match && uci add_list firewall.3en_manual_block.match='src_ip' && uci set firewall.3en_manual_drop=rule && uci set firewall.3en_manual_drop.name='3EN Manual Block' && uci set firewall.3en_manual_drop.src='wan' && uci set firewall.3en_manual_drop.ipset='3en_manual_block' && uci set firewall.3en_manual_drop.target='DROP' && uci commit firewall && /etc/init.d/firewall restart",30)

def audit(action,ip,result):
    rec={'ts':time.strftime('%Y-%m-%dT%H:%M:%S%z'),'action':action,'ip':ip,'result':result}
    with AUDIT.open('a',encoding='utf-8') as f: f.write(json.dumps(rec,ensure_ascii=False)+'\n')

def change(action,ip):
    if not valid_ip(ip): raise ValueError('invalid IP')
    ensure_firewall()
    cur=blocked_set()
    if action=='block' and ip not in cur:
        ssh(f"uci add_list firewall.3en_manual_block.entry='{ip}' && uci commit firewall && /etc/init.d/firewall reload",20)
    elif action=='unblock' and ip in cur:
        ssh(f"uci del_list firewall.3en_manual_block.entry='{ip}' && uci commit firewall && /etc/init.d/firewall reload",20)
    now=blocked_set(); ok=(ip in now) if action=='block' else (ip not in now)
    audit(action,ip,'PASS' if ok else 'FAIL')
    if not ok: raise RuntimeError('router verification failed')

def status():
    src=discover_source(); items={}
    if src:
        flatten(load_json(src),items,Path(src).name)
    blocked=blocked_set()
    arr=[]
    for x in items.values():
        x['blocked']=x['ip'] in blocked; arr.append(x)
    for ip in sorted(blocked):
        if ip not in items: arr.append({'ip':ip,'attempts':0,'blocked':True,'source':'manual blocklist','evidence':'persisted on 3EN002'})
    arr.sort(key=lambda x:(not x['blocked'],-int(x.get('attempts',0)),x['ip']))
    return {'ok':True,'source':src,'routerSsh':router_ok(),'items':arr,'blockedCount':len(blocked),'audit':str(AUDIT)}

class H(BaseHTTPRequestHandler):
    def sendj(self,obj,code=200):
        b=json.dumps(obj,ensure_ascii=False).encode(); self.send_response(code); self.send_header('Content-Type','application/json; charset=utf-8'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith('/api/status'):
            try:self.sendj(status())
            except Exception as e:self.sendj({'error':str(e)},500)
        else:
            b=HTML.encode(); self.send_response(200); self.send_header('Content-Type','text/html; charset=utf-8'); self.send_header('Content-Length',str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        try:
            n=int(self.headers.get('Content-Length','0')); body=json.loads(self.rfile.read(n) or b'{}')
            if self.path!='/api/action': raise ValueError('unknown endpoint')
            a=body.get('action'); ips=body.get('ips') or []
            if a not in ('block','unblock'): raise ValueError('unknown action')
            for ip in ips: change(a,str(ip))
            self.sendj({'ok':True,'status':status()})
        except Exception as e:self.sendj({'error':str(e)},500)
    def log_message(self,*a): pass

if __name__=='__main__': ThreadingHTTPServer((HOST,PORT),H).serve_forever()
