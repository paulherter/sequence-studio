import urllib.request,re,html,time,os,sys,json
# Mirrors Adobe's Premiere Pro user guide (newest Wayback snapshots) as plain text into docs/reference/adobe/ (gitignored).
# Usage: python3 scripts/fetch_adobe_guide.py   (run from the repo root; re-run to resume)
os.makedirs('docs/reference/adobe',exist_ok=True); os.chdir('docs/reference/adobe')
UA={'User-Agent':'Mozilla/5.0 (Macintosh) SequenceStudio-research'}
def get(u,t=60):
    import gzip
    d=urllib.request.urlopen(urllib.request.Request(u,headers=UA),timeout=t).read()
    return gzip.decompress(d) if d[:2]==b'\x1f\x8b' else d
cdx='https://web.archive.org/cdx/search/cdx?url=helpx.adobe.com/premiere-pro/using/*&output=json&fl=original,timestamp&filter=statuscode:200&filter=mimetype:text/html&from=2024&collapse=timestamp:6'
rows=None
if os.path.exists('cdx.json'): rows=json.load(open('cdx.json'))
while rows is None:
    try: rows=json.loads(get(cdx,180))[1:]; json.dump(rows,open('cdx.json','w'))
    except Exception as e: print('cdx retry',e,flush=True); time.sleep(90)
latest={}
for o,ts in rows:
    k=re.sub(r'^https?://','',o.split('?')[0]).rstrip('/')
    if not k.endswith('.html'): continue
    if k not in latest or ts>latest[k]: latest[k]=ts
print(len(latest),'pages',flush=True)
ok=0
for k,ts in sorted(latest.items()):
    name=k.split('/')[-1][:-5]+'.txt'
    if os.path.exists(name): ok+=1; continue
    try:
        raw=get(f'https://web.archive.org/web/{ts}id_/https://{k}').decode('utf-8','ignore')
    except Exception as e:
        print('fail',k,e,flush=True); time.sleep(60); continue
    m=re.search(r'<main.*?</main>',raw,re.S); body=m.group(0) if m else raw
    body=re.sub(r'<(script|style|nav|footer|svg)[^>]*>.*?</\1>','',body,flags=re.S)
    body=re.sub(r'</(p|div|li|tr|h[1-6]|td|th)>|<br[^>]*>','\n',body)
    body=re.sub(r'<h([1-6])[^>]*>',lambda m:'\n'+'#'*int(m.group(1))+' ',body)
    txt=html.unescape(re.sub(r'<[^>]+>','',body))
    txt=re.sub(r'[ \t]+',' ',txt); txt=re.sub(r'\n\s*\n+','\n\n',txt).strip()
    if len(txt)<400: print('thin',k,flush=True); continue
    open(name,'w').write(f'SOURCE: https://{k} (Wayback {ts})\n\n'+txt)
    ok+=1; time.sleep(2.5)
print('done',ok,flush=True)
