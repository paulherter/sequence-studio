#!/bin/bash
# Lists SwiftPM targets that `import SQ…` a module they do not declare as a direct dependency in Package.swift.
# Why: SwiftPM only re-runs a target's compile when a DIRECT dependency's .swiftmodule changes. A module reached only
# transitively (e.g. SQCore through SQTranscribe) can change layout (a new stored property on Clip) while the direct
# module's file stays byte-identical, so the target keeps stale objects with the old layout and crashes at run time
# (SIGSEGV in "outlined destroy of …"). Exit 1 when any target misses a direct dependency.
# Usage: scripts/check-direct-deps.sh [Package…]
cd "$(dirname "$0")/../Packages" || exit 1
pkgs=("$@"); [ ${#pkgs[@]} -eq 0 ] && pkgs=(SQ*)
python3 - "${pkgs[@]}" <<'EOF'
import os, re, sys
bad = 0
for pkg in sys.argv[1:]:
    manifest = os.path.join(pkg, "Package.swift")
    if not os.path.isfile(manifest):
        continue
    text = open(manifest).read()
    # A manifest may declare a reduced Windows package first (`#if os(Windows) ... #else`): check the Mac one.
    text = re.sub(r'#if os\(Windows\).*?#else', '', text, flags=re.S)
    # Split at each .target( / .testTarget( / .executableTarget( and read its dependencies: [...] by bracket matching.
    starts = [m for m in re.finditer(r'\.(target|testTarget|executableTarget)\(\s*name:\s*"([^"]+)"', text)]
    for k, m in enumerate(starts):
        chunk = text[m.end():starts[k + 1].start() if k + 1 < len(starts) else len(text)]
        name, rest = m.group(2), chunk
        deps = set()
        d = rest.find("dependencies:")
        if d >= 0:
            i = rest.index("[", d); depth = 0
            for j in range(i, len(rest)):
                depth += {"[": 1, "]": -1}.get(rest[j], 0)
                if depth == 0:
                    break
            deps = set(re.findall(r'"([^"]+)"', rest[i:j + 1]))
            rest = rest[:d] + rest[j + 1:]
        pm = re.search(r'path:\s*"([^"]+)"', rest)
        kind = "Tests" if m.group(1) == "testTarget" else "Sources"
        src = os.path.join(pkg, pm.group(1)) if pm else os.path.join(pkg, kind, name)
        imports = set()
        for root, _, files in os.walk(src):
            for f in files:
                if f.endswith(".swift"):
                    for line in open(os.path.join(root, f), errors="ignore"):
                        im = re.match(r'\s*(?:@testable\s+|@_spi\([^)]*\)\s+)?import\s+(SQ\w+)', line)
                        if im:
                            imports.add(im.group(1))
        missing = sorted(i for i in imports if i != name and i not in deps)
        if missing:
            bad += 1
            print(f"{pkg}: target {name} imports {', '.join(missing)} without a direct dependency")
sys.exit(1 if bad else 0)
EOF
