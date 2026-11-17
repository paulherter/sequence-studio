# Mutation fuzz: python3 -I fuzz.py <count> ; runs rust, swift-portable and swift-apple, reports crashes/hangs/diffs.
import gzip, io, os, random, subprocess, sys, tempfile, zipfile
here = os.path.dirname(os.path.abspath(__file__))
bins = {"rust": os.path.join(here, "..", "target/release/dump"), "portable": os.path.join(here, "swift-dump/out/dump-swift-portable"), "apple": os.path.join(here, "swift-dump/out/dump-swift-apple")}
xml = ('<?xml version="1.0" encoding="UTF-8" ?><PremiereData Version="3">' + "".join(f'<Media ObjectUID="u{i}"><T a="&amp;{i}">x &#65; <![CDATA[y]]></T><B BinaryHash="h">QUJD</B></Media>' for i in range(30)) + "</PremiereData>").encode()
z = io.BytesIO()
with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as f:
    f.writestr("a.xml", xml); f.writestr("b.txt", b"hello" * 100)
seeds = [gzip.compress(xml), z.getvalue(), xml]
rnd = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 99)
crash = {"rust": 0, "portable": 0, "apple": 0}; hang = dict(crash); dp = da = 0; examples = []
d = tempfile.mkdtemp()
for k in range(int(sys.argv[1])):
    b = bytearray(rnd.choice(seeds))
    for _ in range(rnd.choice([1, 2, 3, 8])):
        m = rnd.randrange(4)
        i = rnd.randrange(len(b))
        if m == 0: b[i] = rnd.randrange(256)
        elif m == 1: b[i] ^= 1 << rnd.randrange(8)
        elif m == 2: del b[i:i + rnd.randrange(1, 20)]
        else: b[i:i] = bytes(rnd.randrange(256) for _ in range(rnd.randrange(1, 8)))
    p = os.path.join(d, "f"); open(p, "wb").write(b)
    res = {}
    for n, exe in bins.items():
        try:
            r = subprocess.run([exe, p], capture_output=True, timeout=20)
            res[n] = (r.returncode, r.stdout)
            if r.returncode != 0: crash[n] += 1; examples.append((k, n, r.returncode))
        except subprocess.TimeoutExpired:
            hang[n] += 1; res[n] = (-1, b"")
    if res["rust"] != res["portable"]: dp += 1; examples.append((k, "rust!=portable"))
    if res["rust"] != res["apple"]: da += 1
print("cases", sys.argv[1], "crashes", crash, "hangs", hang, "rust!=portable", dp, "rust!=apple", da, examples[:5])
