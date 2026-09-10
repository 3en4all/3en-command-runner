from pathlib import Path
import json, shutil, time, py_compile

ROOT=Path(r'C:\3EN-Agent')
WORK=ROOT/'security-privacy-stack'
UI=WORK/'3en-security-privacy-web.py'
BACKUPS=WORK/'gui-v1-backups'
BACKUPS.mkdir(parents=True,exist_ok=True)
if not UI.exists(): raise SystemExit('GUI_SOURCE_MISSING')
text=UI.read_text(encoding='utf-8-sig')
stamp=time.strftime('%Y%m%d-%H%M%S')
bak=BACKUPS/f'3en-security-privacy-web-{stamp}.py'
shutil.copy2(UI,bak)

if 'BRIDGE_URL = "http://127.0.0.1:8766"' not in text:
    anchor='ROUTER = "192.168.1.2"\n'
    insert='''ROUTER = "192.168.1.2"\nBRIDGE_URL = "http://127.0.0.1:8766"\nIP_LISTS = WORK / "ip-lists.json"\nIP_AUDIT = WORK / "ip-actions.jsonl"\n\n'''
    if anchor not in text: raise SystemExit('ANCHOR_ROUTER_MISSING')
    text=text.replace(anchor,insert,1)

helpers=r'''
def load_ip_lists():
    if not IP_LISTS.exists():
        return {"allow": [], "block": []}
    try:
        x=json.loads(IP_LISTS.read_text(encoding="utf-8-sig"))
        return {"allow": sorted(set(x.get("allow",[]))), "block": sorted(set(x.get("block",[])))}
    except Exception:
        return {"allow": [], "block": []}


def save_ip_lists(x):
    IP_LISTS.write_text(json.dumps(x,ensure_ascii=False,indent=2),encoding="utf-8")


def bridge_json(path, method="GET", body=None):
    import urllib.request
    data=None; headers={}
    if body is not None:
        data=json.dumps(body).encode("utf-8"); headers["Content-Type"]="application/json"
    req=urllib.request.Request(BRIDGE_URL+path,data=data,headers=headers,method=method)
    with urllib.request.urlopen(req,timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))


def audit_ip(action, ip, result="PASS"):
    rec={"ts":time.strftime("%Y-%m-%dT%H:%M:%S%z"),"action":action,"ip":ip,"result":result}
    with IP_AUDIT.open("a",encoding="utf-8") as f: f.write(json.dumps(rec,ensure_ascii=False)+"\n")


def threat_status():
    b=bridge_json("/api/status")
    lists=load_ip_lists(); allow=set(lists["allow"]); block=set(lists["block"])
    items=[]
    for x in b.get("items",[]):
        y=dict(x); ip=str(y.get("ip","")); y["allowlisted"]=ip in allow; y["blocklisted"]=ip in block; items.append(y)
    return {"ok":True,"source":b.get("source"),"routerSsh":b.get("routerSsh"),"blockedCount":b.get("blockedCount",0),"items":items,"lists":lists,"audit":str(IP_AUDIT)}


def threat_action(action, ips):
    lists=load_ip_lists(); allow=set(lists["allow"]); block=set(lists["block"])
    ips=[str(x).strip() for x in ips if str(x).strip()]
    if action in ("block","unblock"):
        safe=[ip for ip in ips if not (action=="block" and ip in allow)]
        if safe: bridge_json("/api/action","POST",{"action":action,"ips":safe})
        for ip in safe: audit_ip(action,ip)
    elif action=="allow_add":
        for ip in ips:
            allow.add(ip); block.discard(ip)
            try: bridge_json("/api/action","POST",{"action":"unblock","ips":[ip]})
            except Exception: pass
            audit_ip("allow_add",ip)
    elif action=="allow_remove":
        for ip in ips: allow.discard(ip); audit_ip("allow_remove",ip)
    elif action=="block_add":
        safe=[ip for ip in ips if ip not in allow]
        if safe: bridge_json("/api/action","POST",{"action":"block","ips":safe})
        for ip in safe: block.add(ip); audit_ip("block_add",ip)
    elif action=="block_remove":
        for ip in ips: block.discard(ip); audit_ip("block_remove",ip)
    else: raise ValueError("unknown threat action")
    save_ip_lists({"allow":sorted(allow),"block":sorted(block)})
    return threat_status()
'''
if 'def load_ip_lists():' not in text:
    anchor='\ndef status_payload():'
    if anchor not in text: raise SystemExit('ANCHOR_STATUS_MISSING')
    text=text.replace(anchor,'\n'+helpers+'\ndef status_payload():',1)

oldnav='<button class="active" data-tab="overview">Overview</button><button data-tab="privacy">Privacy / DNS</button><button data-tab="domains">Allow / Deny</button><button data-tab="security">Security Events</button><button data-tab="system">System</button>'
newnav='<button class="active" data-tab="overview">Overview</button><button data-tab="threats">Threats</button><button data-tab="blocklist">Blocklist</button><button data-tab="allowlist">Allowlist</button><button data-tab="privacy">Privacy / DNS</button><button data-tab="domains">Domain Rules</button><button data-tab="security">Security Events</button><button data-tab="system">System</button>'
if oldnav in text: text=text.replace(oldnav,newnav,1)

if '<section id="threats" class="tab hidden">' not in text:
    anchor='<section id="system" class="tab hidden">'
    section=r'''<section id="threats" class="tab hidden"><div class="section"><div class="toolbar"><input id="threatSearch" placeholder="Search IP / source / evidence" oninput="renderThreats()"><select id="threatFilter" onchange="renderThreats()"><option value="all">All</option><option value="blocked">Blocked</option><option value="active">Active only</option><option value="allowed">Allowlisted</option></select><button class="btn danger" onclick="bulkThreat('block')">Block selected</button><button class="btn" onclick="bulkThreat('unblock')">Unblock selected</button><button class="btn" onclick="loadThreats()">Refresh</button></div><table><thead><tr><th></th><th onclick="sortThreats('ip')">IP ↕</th><th onclick="sortThreats('attempts')">Attempts ↕</th><th onclick="sortThreats('blocked')">Status ↕</th><th onclick="sortThreats('source')">Source ↕</th><th>Evidence</th><th>Actions</th></tr></thead><tbody id="threatRows"></tbody></table></div></section><section id="blocklist" class="tab hidden"><div class="section"><h2>Blocklist</h2><div class="toolbar"><input id="blockIp" placeholder="IP address"><button class="btn danger" onclick="listAction('block_add','blockIp')">Add & block</button></div><table><thead><tr><th>IP</th><th></th></tr></thead><tbody id="blockRows"></tbody></table></div></section><section id="allowlist" class="tab hidden"><div class="section"><h2>Allowlist</h2><div class="notice">Allowlisted IPs are protected from manual block actions in this GUI.</div><div class="toolbar"><input id="allowIp" placeholder="IP address"><button class="btn primary" onclick="listAction('allow_add','allowIp')">Add & allow</button></div><table><thead><tr><th>IP</th><th></th></tr></thead><tbody id="allowRows"></tbody></table></div></section>'''
    if anchor not in text: raise SystemExit('ANCHOR_SYSTEM_MISSING')
    text=text.replace(anchor,section+anchor,1)

js=r'''
let threatItems=[], threatSort={key:'attempts',dir:-1}, threatLists={allow:[],block:[]};
async function loadThreats(){try{const j=await api('/api/threats');threatItems=j.items||[];threatLists=j.lists||{allow:[],block:[]};renderThreats();renderLists()}catch(e){console.error(e)}}
function selectedThreats(){return [...document.querySelectorAll('#threatRows input[type=checkbox]:checked')].map(x=>x.value)}
function sortThreats(k){if(threatSort.key===k)threatSort.dir*=-1;else{threatSort={key:k,dir:1}};renderThreats()}
function renderThreats(){if(!$('threatRows'))return;let q=($('threatSearch')?.value||'').toLowerCase(),f=$('threatFilter')?.value||'all';let a=threatItems.filter(x=>{let blob=(x.ip+' '+(x.source||'')+' '+(x.evidence||'')).toLowerCase();if(q&&!blob.includes(q))return false;if(f==='blocked'&&!x.blocked)return false;if(f==='active'&&Number(x.attempts||0)<1)return false;if(f==='allowed'&&!x.allowlisted)return false;return true});a.sort((x,y)=>{let A=x[threatSort.key],B=y[threatSort.key];if(typeof A==='number'||typeof B==='number')return (Number(A||0)-Number(B||0))*threatSort.dir;return String(A||'').localeCompare(String(B||''))*threatSort.dir});$('threatRows').innerHTML=a.map(x=>`<tr><td><input type="checkbox" value="${esc(x.ip)}"></td><td>${esc(x.ip)}</td><td>${Number(x.attempts||0)}</td><td><span class="tag ${x.blocked?'bad':x.allowlisted?'good':''}">${x.blocked?'BLOCKED':x.allowlisted?'ALLOWED':'WATCH'}</span></td><td>${esc(x.source||'')}</td><td>${esc((x.evidence||'').slice(0,130))}</td><td><button class="btn danger" onclick="singleThreat('block','${esc(x.ip)}')">Block</button> <button class="btn" onclick="singleThreat('unblock','${esc(x.ip)}')">Unblock</button></td></tr>`).join('')}
async function bulkThreat(a){let ips=selectedThreats();if(!ips.length)return;await post('/api/threat-action',{action:a,ips});await loadThreats()}
async function singleThreat(a,ip){await post('/api/threat-action',{action:a,ips:[ip]});await loadThreats()}
async function listAction(a,inputId){let ip=$(inputId).value.trim();if(!ip)return;await post('/api/threat-action',{action:a,ips:[ip]});$(inputId).value='';await loadThreats()}
async function listRemove(a,ip){await post('/api/threat-action',{action:a,ips:[ip]});await loadThreats()}
function renderLists(){if($('blockRows'))$('blockRows').innerHTML=(threatLists.block||[]).map(ip=>`<tr><td>${esc(ip)}</td><td><button class="btn" onclick="listRemove('block_remove','${esc(ip)}')">Remove</button></td></tr>`).join('');if($('allowRows'))$('allowRows').innerHTML=(threatLists.allow||[]).map(ip=>`<tr><td>${esc(ip)}</td><td><button class="btn" onclick="listRemove('allow_remove','${esc(ip)}')">Remove</button></td></tr>`).join('')}
'''
if 'let threatItems=[]' not in text:
    anchor='document.querySelectorAll(\'.nav button\')'
    if anchor not in text: raise SystemExit('ANCHOR_JS_MISSING')
    text=text.replace(anchor,js+'\n'+anchor,1)
    text=text.replace('refresh();setInterval(refresh,15000);','refresh();loadThreats();setInterval(()=>{refresh();loadThreats()},15000);',1)

if 'if p == "/api/threats"' not in text:
    anchor='            if p == "/api/domains": return self.send_json({"items": domains()})\n'
    repl=anchor+'            if p == "/api/threats": return self.send_json(threat_status())\n'
    if anchor not in text: raise SystemExit('ANCHOR_GET_MISSING')
    text=text.replace(anchor,repl,1)

if 'if p == "/api/threat-action"' not in text:
    anchor='            if p == "/api/domain":\n'
    repl='            if p == "/api/threat-action":\n                return self.send_json(threat_action(str(body.get("action","")), body.get("ips") or []))\n'+anchor
    if anchor not in text: raise SystemExit('ANCHOR_POST_MISSING')
    text=text.replace(anchor,repl,1)

UI.write_text(text,encoding='utf-8')
try: py_compile.compile(str(UI),doraise=True)
except Exception:
    shutil.copy2(bak,UI); raise
print(f'GUI_V1_PATCH=PASS;BACKUP={bak};UI={UI}')
