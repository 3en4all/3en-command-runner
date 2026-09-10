from pathlib import Path
import shutil,time,py_compile
ROOT=Path(r'C:\3EN-Agent')
BR=ROOT/'security-monitor-integration'/'3en-security-monitor-bridge-v1.py'
BK=ROOT/'backups'/'bridge-fastsource'
BK.mkdir(parents=True,exist_ok=True)
if not BR.exists(): raise SystemExit('BRIDGE_MISSING')
stamp=time.strftime('%Y%m%d-%H%M%S')
shutil.copy2(BR,BK/f'3en-security-monitor-bridge-{stamp}.py')
s=BR.read_text(encoding='utf-8-sig')
needle='def discover_source():\n'
insert="def discover_source():\n    preferred=Path(r'E:\\\\skrypty\\\\3en-threats.json')\n    if preferred.exists():\n        SOURCE_CACHE['path']=str(preferred); SOURCE_CACHE['ts']=time.time(); return str(preferred)\n"
if "preferred=Path(r'E:\\\\skrypty\\\\3en-threats.json')" not in s:
    if needle not in s: raise SystemExit('DISCOVER_FUNCTION_MISSING')
    s=s.replace(needle,insert,1)
BR.write_text(s,encoding='utf-8')
py_compile.compile(str(BR),doraise=True)
print(f'BRIDGE_FASTSOURCE_PATCH=PASS;BACKUP={BK}')