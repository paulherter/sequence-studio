# Generates synthetic parity fixtures into the directory given as argv[1] (deterministic). Run with python3 -I.
import gzip, io, os, random, struct, sys, unicodedata, zipfile, zlib

out = sys.argv[1]
os.makedirs(out, exist_ok=True)

def w(name, data, limit=None):
    with open(os.path.join(out, name), "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode("utf-8"))
    if limit is not None:
        with open(os.path.join(out, name + ".limit"), "w") as f:
            f.write(str(limit))

HEAD = '<?xml version="1.0" encoding="UTF-8" ?>\n'
def project(n=20):
    objs = []
    for i in range(n):
        objs.append(f'<Media ObjectUID="00000000-0000-0000-0000-{i:012d}" Version="30"><FilePath>/Volumes/x/clip{i}.mov</FilePath><Title>Clip &amp; {i}</Title></Media>')
        objs.append(f'<VideoClip ObjectID="{100+i}"><Source ObjectRef="{i}"/><StartKeyframe Encoding="base64" BinaryHash="h{i%3}">{"QUJD"*(i%4)}</StartKeyframe></VideoClip>')
    return HEAD + '<PremiereData Version="3">\n' + "\n".join(objs) + "\n</PremiereData>\n"

base = project()
w("valid.xml", base)
w("valid.gz", gzip.compress(base.encode(), 6))
w("valid-level1.gz", gzip.compress(base.encode(), 1))
w("valid-stored.gz", gzip.compress(base.encode(), 0))
big = project(4000)
w("valid-big.gz", gzip.compress(big.encode(), 6))

def gz_with(flags_data, body):
    # hand-built gzip header with optional FEXTRA / FNAME / FCOMMENT / FHCRC
    flg = 0
    hdr = b""
    if "extra" in flags_data: flg |= 4; hdr += struct.pack("<H", 5) + b"abcde"
    if "name" in flags_data: flg |= 8; hdr += b"name.xml\0"
    if "comment" in flags_data: flg |= 16; hdr += b"a comment\0"
    if "hcrc" in flg_names(flags_data): flg |= 2; hdr += b"\0\0"
    c = zlib.compressobj(6, zlib.DEFLATED, -15)
    raw = c.compress(body) + c.flush()
    return b"\x1f\x8b\x08" + bytes([flg]) + b"\0\0\0\0\0\xff" + hdr + raw + struct.pack("<II", zlib.crc32(body), len(body))
def flg_names(x): return x
for combo in (["extra"], ["name"], ["comment"], ["hcrc"], ["extra", "name", "comment", "hcrc"]):
    w("gzflags-" + "-".join(combo) + ".gz", gz_with(combo, base.encode()))

good = gzip.compress(base.encode(), 6)
w("trunc-half.gz", good[: len(good) // 2])
w("trunc-9.gz", good[:9])
w("trunc-17.gz", good[:17])
w("trunc-tail.gz", good[:-4])
w("notgz-method.gz", good[:2] + b"\x07" + good[3:])
w("empty", b"")
w("one-byte", b"x")
w("trailing-garbage.gz", good + b"garbage")
w("two-members.gz", good + good)
rnd = random.Random(7)
for k in range(60):
    b = bytearray(good)
    for _ in range(rnd.choice([1, 1, 2, 5])):
        b[rnd.randrange(len(b))] = rnd.randrange(256)
    w(f"fuzz-gz-{k:02d}.gz", bytes(b))
for k in range(30):
    b = bytearray(good[:-8])
    pos = rnd.randrange(10, len(b))
    b[pos] ^= 1 << rnd.randrange(8)
    w(f"fuzz-gzbit-{k:02d}.gz", bytes(b) + good[-8:])

# bombs: output limited by --limit
w("bomb.gz", gzip.compress(b"\0" * (60 << 20), 9), limit=1_000_000)
w("bomb-ok.gz", gzip.compress(b"<a/>" + b" " * (3 << 20), 9), limit=10_000_000)
w("bomb-exact.gz", gzip.compress(base.encode(), 9), limit=len(base.encode()))
w("bomb-exact-1.gz", gzip.compress(base.encode(), 9), limit=len(base.encode()) - 1)

# XML shapes (plain, to see fast-reader decisions)
x = lambda body: '<PremiereData>' + body + '</PremiereData>'
cases = {
  "utf8-bom": b"\xef\xbb\xbf" + base.encode(),
  "utf16le-bom": b"\xff\xfe" + base.encode("utf-16-le"),
  "utf16be-bom": b"\xfe\xff" + base.encode("utf-16-be"),
  "enc-latin1": HEAD.replace("UTF-8", "ISO-8859-1").encode() + b"<PremiereData><T>caf\xe9</T></PremiereData>",
  "enc-utf8-lower": HEAD.replace("UTF-8", "utf8").encode() + b"<PremiereData/>",
  "enc-single-quote": b"<?xml version='1.0' encoding='UTF-8'?><PremiereData/>",
  "enc-none": b"<?xml version='1.0'?><PremiereData/>",
  "pi-stylesheet": b"<?xml-stylesheet encoding='utf-16'?><PremiereData/>",
  "doctype": b"<!DOCTYPE PremiereData><PremiereData/>",
  "invalid-utf8-text": b"<PremiereData><T>\xff\xfe</T></PremiereData>",
  "invalid-utf8-attr": b"<PremiereData a=\"\xc3\x28\"/>",
  "invalid-utf8-name": b"<PremiereData><\xc3\x28/></PremiereData>",
  "cdata": x("<A><![CDATA[a < b & c &amp; d]]> tail </A>").encode(),
  "cdata-outside": b"<![CDATA[x]]><PremiereData/>",
  "entities-named": x("<A>&amp;&lt;&gt;&quot;&apos;</A>").encode(),
  "entities-num": x("<A>&#65;&#x42;&#x1F600;&#9;&#10;&#13;</A>").encode(),
  "entity-upperX": x("<A>&#X41;</A>").encode(),
  "entity-plus": x("<A>&#+65;&#x+42;</A>").encode(),
  "entity-minus0": x("<A>&#-0;</A>").encode(),
  "entity-nul": x("<A>&#0;</A>").encode(),
  "entity-control": x("<A>&#1;</A>").encode(),
  "entity-surrogate": x("<A>&#xD800;</A>").encode(),
  "entity-fffe": x("<A>&#xFFFE;</A>").encode(),
  "entity-too-big": x("<A>&#x110000;</A>").encode(),
  "entity-overflow": x("<A>&#99999999999999;</A>").encode(),
  "entity-unknown": x("<A>&nbsp;</A>").encode(),
  "entity-unterminated": x("<A>&amp</A>").encode(),
  "entity-long": x("<A>&aaaaaaaaaaaaaaaa;</A>").encode(),
  "entity-empty-num": x("<A>&#;&#x;</A>").encode(),
  "entity-in-attr": x('<A v="&lt;&#x41;&#10;&#9;"/>').encode(),
  "crlf-text": x("<A>l1\r\nl2\rl3\n</A>").encode(),
  "crlf-attr": x('<A v="a\r\nb\rc\nd\te"/>').encode(),
  "attr-single-quote": x("<A v='x\"y' w=\"it's\"/>").encode(),
  "attr-no-space": x('<A a="1"b="2"/>').encode(),
  "attr-dup": x('<A a="1" a="2"/>').encode(),
  "attr-lt": x('<A a="<"/>').encode(),
  "attr-unquoted": x('<A a=1/>').encode(),
  "attr-no-value": x('<A a/>').encode(),
  "attr-spaces-eq": x('<A a = "1" />').encode(),
  "attr-nfc-nfd-dup": x('<A é="1" é="2"/>').encode(),
  "tag-nfc-nfd-close": x('<é></é>').encode(),
  "id-nfc-nfd": x('<A ObjectID="é"/><B ObjectID="é"/>').encode(),
  "mismatch-close": b"<PremiereData><A></B></PremiereData>",
  "unclosed": b"<PremiereData><A>",
  "second-root": b"<PremiereData/><PremiereData/>",
  "text-outside": b"junk<PremiereData/>",
  "text-after": b"<PremiereData/>junk",
  "ws-around": b"\n\t <PremiereData/> \r\n",
  "comment-everywhere": b"<!-- a --><PremiereData><!-- b --><A>x<!-- c -->y</A></PremiereData><!-- d -->",
  "comment-unterminated": b"<PremiereData><!-- x</PremiereData>",
  "pi-inside": b"<PremiereData><?php x ?><A/></PremiereData>",
  "name-eof": b"<PremiereData",
  "lone-lt": b"<",
  "empty-name": b"< />",
  "not-premiere": b"<Other/>",
  "ws-only": b"   \n ",
  "ws-nbsp": x("<A>  x  </A>").encode(),
  "ws-unicode": x("<A>  　x  </A>").encode(),
  "ws-mongolian": x("<A>᠎x᠎</A>").encode(),
  "ws-zerowidth": x("<A>​x​﻿</A>").encode(),
  "ws-nel": x("<A>\u0085x\u0085</A>").encode(),
  "ws-vt-ff": x("<A>\x0bx\x0c</A>").encode(),
  "ws-entity": x("<A>&#32;&#160;x&#160;&#32;</A>").encode(),
  "ws-inner": x("<A>  a   b \n c  </A>").encode(),
  "mixed-content": x("<A>one<B/>two<C/>three</A>").encode(),
  "binary-hash": x('<A BinaryHash="k"></A><B BinaryHash="k">v1</B><C BinaryHash="k">v2</C><D BinaryHash="z">v3</D>').encode(),
  "object-ids": x('<A ObjectID="1"/><B ObjectUID="1"/><C ObjectID="2" ObjectUID="3"/><D ObjectID="1"/>').encode(),
  "unicode-names": x("<日本 ключ=\"значение\">テキスト</日本>").encode(),
  "xml-decl-only": b"<?xml version='1.0'?>",
  "xml-decl-unterminated": b"<?xml version='1.0'",
  "encoding-case": b"<?xml version='1.0' ENCODING='UTF-8'?><PremiereData/>",
  "encoding-weird": b"<?xml version='1.0' encoding = \"  utf-8\"?><PremiereData/>",
  "nul-bytes": b"<PremiereData><A>a\x00b</A></PremiereData>",
  "slash-in-name": b"<PremiereData><a/b></a/b></PremiereData>",
  "close-with-space": b"<PremiereData><A></A  ></PremiereData>",
  "self-close-space": b"<PremiereData><A  /></PremiereData>",
  "self-close-bad": b"<PremiereData><A / ></PremiereData>",
}
for k, v in cases.items():
    w("xml-" + k + ".xml", v)
    if k in ("cdata", "entities-num", "ws-unicode", "binary-hash", "object-ids"):
        w("xml-" + k + ".gz", gzip.compress(v if k != "utf16le-bom" else v))

# deep nesting
def nest(n): return b"<PremiereData>" + b"<N>" * n + b"x" + b"</N>" * n + b"</PremiereData>"
w("deep-1000.xml", nest(1000))
w("deep-20000.xml", nest(20000))
w("deep-200000.gz", gzip.compress(nest(200000)))
w("wide-100000.xml", b"<PremiereData>" + b"<c a='1'/>" * 100000 + b"</PremiereData>")

# ZIP
def mkzip(entries, method=zipfile.ZIP_DEFLATED, comment=b""):
    bio = io.BytesIO()
    with zipfile.ZipFile(bio, "w", method) as z:
        for n, d in entries:
            z.writestr(n, d)
        z.comment = comment
    return bio.getvalue()
ents = [("Definition.json", b'{"a":1}' * 50), ("project.prgraphic", base.encode()), ("thumb.png", os.urandom(300)), ("dir/Inner.XML", b"<a/>")]
vz = mkzip(ents)
w("zip-valid.mogrt", vz)
w("zip-stored.mogrt", mkzip(ents, zipfile.ZIP_STORED))
w("zip-comment.mogrt", mkzip(ents, comment=b"c" * 5000))
w("zip-bzip2.mogrt", mkzip(ents, zipfile.ZIP_BZIP2))
w("zip-lzma.mogrt", mkzip(ents, zipfile.ZIP_LZMA))
w("zip-empty.mogrt", mkzip([]))
w("zip-case.mogrt", mkzip([("PROJECT.PRGRAPHIC", b"A"), ("project.prgraphic", b"B")]))
w("zip-unicode-name.mogrt", mkzip([("Pröject.prgraphic", b"u"), ("Ä.txt", b"u")]))
w("zip-big.mogrt", mkzip([("a.bin", (b"0123456789abcdef" * 4096) * 40), ("b", b"x")]))
w("zip-trunc-half.mogrt", vz[: len(vz) // 2])
w("zip-trunc-eocd.mogrt", vz[:-10])
w("zip-trunc-21.mogrt", vz[:21])
w("zip-just-sig.mogrt", b"PK\x03\x04")
# non-UTF-8 name: patch name bytes of a stored zip
nz = bytearray(mkzip([("abcd.txt", b"data")], zipfile.ZIP_STORED))
nz = bytes(nz).replace(b"abcd", b"\xe9\xff\xe8d")
w("zip-name-latin1.mogrt", nz)
# encrypted flag set
def patch_flags(z, flag):
    b = bytearray(z)
    i = b.find(b"PK\x01\x02")
    b[i + 8] |= flag
    return bytes(b)
w("zip-encrypted.mogrt", patch_flags(vz, 1))
# claimed sizes (zip bombs): central directory claims huge uncompressed size
def patch_central(z, field_off, value, all_=True):
    b = bytearray(z)
    i = 0
    while True:
        i = b.find(b"PK\x01\x02", i)
        if i < 0: break
        b[i + field_off: i + field_off + 4] = struct.pack("<I", value)
        i += 4
        if not all_: break
    return bytes(b)
w("zip-bomb-usize.mogrt", patch_central(vz, 24, 0xFFFFFFFF))
w("zip-bomb-usize-over.mogrt", patch_central(vz, 24, (256 << 20) + 1))
w("zip-bomb-csize.mogrt", patch_central(vz, 20, 0xFFFFFFF0))
w("zip-usize-lie-small.mogrt", patch_central(vz, 24, 3))
w("zip-usize-lie-big.mogrt", patch_central(vz, 24, 100000))
w("zip-bad-localoff.mogrt", patch_central(vz, 42, 0xFFFFFF00))
w("zip-localoff-mid.mogrt", patch_central(vz, 42, 5))
w("zip-cdoffset-huge.mogrt", (lambda b: bytes(b))(bytearray(vz[:-6]) + struct.pack("<I", 0xFFFFFFF0) + b"\0\0"))
# real deflate bomb entry: 300 MB of zeros claimed truthfully -> over the 256 MB entry limit
bio = io.BytesIO()
with zipfile.ZipFile(bio, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    z.writestr("zeros.bin", b"\0" * (300 << 20))
w("zip-bomb-real.mogrt", bio.getvalue())
for k in range(60):
    b = bytearray(vz)
    for _ in range(rnd.choice([1, 2, 4])):
        b[rnd.randrange(len(b))] = rnd.randrange(256)
    w(f"fuzz-zip-{k:02d}.mogrt", bytes(b))
# XML mutation fuzz
small = project(3).encode()
for k in range(120):
    b = bytearray(small)
    m = rnd.randrange(4)
    if m == 0: b[rnd.randrange(len(b))] = rnd.randrange(256)
    elif m == 1: del b[rnd.randrange(len(b)):rnd.randrange(len(b), len(b)+1)]
    elif m == 2: b.insert(rnd.randrange(len(b)), rnd.choice(b'<>&;"\'/= \r\n\t!?-['))
    else: del b[rnd.randrange(len(b))]
    w(f"fuzz-xml-{k:03d}.xml", bytes(b))
w("zip-longname.mogrt", mkzip([("n" * 1025, b"x")]))
