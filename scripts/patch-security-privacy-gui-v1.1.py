from pathlib import Path
import shutil,time,py_compile
ROOT=Path(r'C:\3EN-Agent')
UI=ROOT/'security-privacy-stack'/'3en-security-privacy-web.py'
BR=ROOT/'security-monitor-integration'/'3en-security-monitor-bridge-v1.py'
BK=ROOT/'backups'/'gui-v11'
BK.mkdir(parents=True,exist_ok=True)
stamp=time.strftime('%Y%m%d-%H%M%S')
for p in (UI,BR):
    if not p.exists(): raise SystemExit(f'MISSING:{p}')
    shutil.copy2(p,BK/f'{p.stem}-{stamp}{p.suffix}')

u=UI.read_text(encoding='utf-8-sig')
oldnav='<button class="active" data-tab="overview">Overview</button><button data-tab="privacy">Privacy / DNS</button><button data-tab="domains">Allow / Deny</button><button data-tab="security">Security Events</button><button data-tab="threats">Threat Control</button><button data-tab="system">System</button>'
newnav='<button class="active" data-tab="overview">Overview</button><button data-tab="threats">Threats</button><button data-tab="blocklist">Blocklist</button><button data-tab="allowlist">Allowlist</button><button data-tab="privacy">Privacy / DNS</button><button data-tab="domains">Domain Rules</button><button data-tab="security">Security Events</button><button data-tab="system">System</button>'
if oldnav not in u: raise SystemExit('GUI_NAV_ANCHOR_MISSING')
u=u.replace(oldnav,newnav,1)
oldsec='<section id="threats" class="tab hidden"><div class="section"><h2>Threat Control</h2><div class="notice">Live threat evidence and persistent manual Block / Unblock on 3EN002. Actions are audited by 3EN Security Monitor bridge.</div><iframe title="3EN Threat Control" src="http://127.0.0.1:8766" style="width:100%;height:68vh;min-height:560px;border:1px solid var(--line);border-radius:14px;background:#0b0f14"></iframe></div></section>'
newsec='''<section id="threats" class="tab hidden"><div class="section"><div class="toolbar"><input id="threatSearch" placeholder="Search IP / source / evidence" oninput="renderThreats()"><select id="threatFilter" onchange="renderThreats()"><option value="all">All</option><option value="blocked">Blocked</option><option value="active">Active only</option><option value="allowed">Allowlisted</option></select><button class="btn danger" onclick="bulkThreat('block')">Block selected</button><button class="btn" onclick="bulkThreat('unblock')">Unblock selected</button><button class="btn" onclick="loadThreats()">Refresh</button></div><table><thead><tr><th></th><th onclick="sortThreats('ip')">IP ↕</th><th onclick="sortThreats('attempts')">Attempts ↕</th><th onclick="sortThreats('blocked')">Status ↕</th><th onclick="sortThreats('source')">Source ↕</th><th>Evidence</th><th>Actions</th></tr></thead><tbody id="threatRows"></tbody></table></div></section><section id="blocklist" class="tab hidden"><div class="section"><h2>Blocklist</h2><div class="toolbar"><input id="blockIp" placeholder="IP address"><button class="btn danger" onclick="listAction('block_add','blockIp')">Add & block</button></div><table><thead><tr><th>IP</th><th></th></tr></thead><tbody id="blockRows"></tbody></table></div></section><section id="allowlist" class="tab hidden"><div class="section"><h2>Allowlist</h2><div class="notice">Allowlisted IPs are protected from manual block actions in this GUI.</div><div class="toolbar"><input id="allowIp" placeholder="IP address"><button class="btn primary" onclick="listAction('allow_add','allowIp')">Add & allow</button></div><table><thead><tr><th>IP</th><th></th></tr></thead><tbody id="allowRows"></tbody></table></div></section>'''
if oldsec not in u: raise SystemExit('GUI_THREAT_SECTION_ANCHOR_MISSING')
u=u.replace(oldsec,newsec,1)
UI.write_text(u,encoding='utf-8')
py_compile.compile(str(UI),doraise=True)

b=BR.read_text(encoding='utf-8-sig')
if "SOURCE_CACHE={'path':'','ts':0.0}" not in b:
    anchor="HOST='127.0.0.1'; PORT=8766\n"
    if anchor not in b: raise SystemExit('BRIDGE_GLOBAL_ANCHOR_MISSING')
    b=b.replace(anchor,anchor+"SOURCE_CACHE={'path':'','ts':0.0}\n",1)
if "if SOURCE_CACHE['path']" not in b:
    anchor='def discover_source():\n    candidates=[]\n'
    repl="def discover_source():\n    now=time.time()\n    if SOURCE_CACHE['path'] and now-SOURCE_CACHE['ts']<300 and Path(SOURCE_CACHE['path']).exists(): return SOURCE_CACHE['path']\n    candidates=[]\n"
    if anchor not in b: raise SystemExit('BRIDGE_DISCOVER_ANCHOR_MISSING')
    b=b.replace(anchor,repl,1)
    anchor="    return seen[0] if seen else ''\n\ndef load_json(path):"
    repl="    path=seen[0] if seen else ''\n    SOURCE_CACHE['path']=path; SOURCE_CACHE['ts']=now\n    return path\n\ndef load_json(path):"
    if anchor not in b: raise SystemExit('BRIDGE_RETURN_ANCHOR_MISSING')
    b=b.replace(anchor,repl,1)
BR.write_text(b,encoding='utf-8')
py_compile.compile(str(BR),doraise=True)
print(f'GUI_V11_PATCH=PASS;BACKUP={BK}')