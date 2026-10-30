#!/bin/bash
# Tests only what a change touches: maps the changed files to their packages and runs scripts/test.sh for those.
# Usage: scripts/check.sh [--dependents] [--fast] [--base <ref>] [--list]
#   (no flag)      packages with changed files (committed since the base, staged, unstaged and untracked)
#   --dependents   also every package that depends on a changed one (run once before a merge, not while iterating)
#   --fast         per package, run only the suites the change touches: the types declared in changed test files, plus
#                  test files that mention a type declared in a changed source file (implementers at task end; the
#                  the merge batch's --dependents run stays unfiltered). A package falls back to its full run when the
#                  change touches Package.swift, resources or anything outside Sources/ and Tests/, a changed file has
#                  a top-level extension, func or @Test, a changed source declares no type, no suite can be named, or
#                  SQ_TEST_FILTER is already set. --list shows the derived filters.
#   --base <ref>   compare against <ref> instead of the merge base with main (e.g. the commit before a batch of merges)
#   --list         print the packages and stop
# Also runs scripts/lint-ui.sh when UI sources changed and scripts/build.sh when App/ or project.yml changed.
# SQ_TEST_FILTER / SQ_TEST_RELEASE pass through to scripts/test.sh.
cd "$(dirname "$0")/.." || exit 1
dependents=0; list=0; fast=0; base=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dependents) dependents=1 ;;
    --fast) fast=1 ;;
    --list) list=1 ;;
    --base) base="$2"; shift ;;
    *) echo "unknown option: $1"; exit 2 ;;
  esac
  shift
done
[ -n "$SQ_TEST_FILTER" ] && fast=0
[ -n "$base" ] || base=$(git merge-base HEAD main 2>/dev/null) || base=HEAD
changed=$( { git diff --name-only "$base" 2>/dev/null; git ls-files --others --exclude-standard; } | sort -u )
[ -n "$changed" ] || { echo "== nothing changed since ${base:0:8}"; exit 0; }

plan=$(DEPENDENTS=$dependents FAST=$fast python3 - "$changed" <<'EOF'
import glob, os, re, sys
changed = sys.argv[1].split("\n")
pkgs = sorted(d for d in os.listdir("Packages") if os.path.isfile(f"Packages/{d}/Package.swift"))
deps = {p: set(re.findall(r'\.package\(\s*path:\s*"\.\./([^"]+)"', open(f"Packages/{p}/Package.swift").read())) for p in pkgs}
touched = {f.split("/")[1] for f in changed if f.startswith("Packages/") and f.count("/") >= 2} & set(pkgs)
run = set(touched)
if os.environ.get("DEPENDENTS") == "1":
    grew = True
    while grew:
        grew = False
        for p in pkgs:
            if p not in run and deps[p] & run:
                run.add(p); grew = True
# Dependencies first, so a break in a root package shows before its dependents are built.
def depth(p, seen=()):
    return 0 if p in seen else 1 + max((depth(d, seen + (p,)) for d in deps.get(p, ())), default=0)
print("PKGS " + " ".join(sorted(run, key=lambda p: (depth(p), p))))

# --fast: one regex per touched package (dependents pulled in by --dependents always run whole).
TYPE = re.compile(r'^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate|open|final|indirect)\s+)*(?:struct|class|enum|actor)\s+([A-Z]\w*)', re.M)
SRC_TYPE = re.compile(r'^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|final|indirect)\s+)*(?:struct|class|enum|actor|protocol)\s+([A-Z]\w*)', re.M)
LOOSE = re.compile(r'^(?:(?:public|package|internal|private|fileprivate|open|final)\s+)*extension\s|^(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|private|fileprivate)\s+)*func\s|^@Test\b', re.M)
def read(f):
    try: return open(f, encoding="utf-8", errors="replace").read()
    except OSError: return ""
if os.environ.get("FAST") == "1":
    for p in sorted(touched):
        files = [f for f in changed if f.startswith(f"Packages/{p}/")]
        if any(not f.endswith(".swift") or not (f"/{p}/Sources/" in f or f"/{p}/Tests/" in f) for f in files):
            continue                                                    # Package.swift, resources, fixtures: full run
        tests = [f for f in files if f"/{p}/Tests/" in f]
        sources = [f for f in files if f"/{p}/Sources/" in f]
        # An extension or a free @Test/func in a changed file touches suites this file does not name: full run.
        if any(LOOSE.search(read(f)) for f in files): continue
        suites = set()
        for f in tests: suites |= set(TYPE.findall(read(f)))
        if any(not SRC_TYPE.findall(read(f)) for f in sources): continue  # a source without a type: cannot be mapped
        names = set()
        for f in sources: names |= set(SRC_TYPE.findall(read(f)))
        names = {n for n in names if len(n) >= 4}                        # short names match everywhere
        if names:
            pat = re.compile(r'\b(?:' + "|".join(sorted(names)) + r')\b')
            for f in glob.glob(f"Packages/{p}/Tests/**/*.swift", recursive=True):
                if f not in tests and pat.search(read(f)): suites |= set(TYPE.findall(read(f)))
        if not suites or len(suites) > 80: continue                     # nothing to name, or most of the package anyway
        print(f"FILTER {p} (^|[./])(" + "|".join(sorted(suites)) + ")(/|$)")
# UI packages UI lint scans (keep in sync with UI_PACKAGES in scripts/lint-ui.sh; DECISIONS "SQEditorUI split").
UI_PACKAGES = ("SQUIKit", "SQEditorSession", "SQTimelineUI", "SQMonitorUI", "SQInspectorUI", "SQEditorUI")
ui = any(f.endswith(".swift") and (f.startswith(tuple(f"Packages/{u}/Sources/" for u in UI_PACKAGES)) or f.startswith("App/")) for f in changed)
app = any(f.startswith("App/") or f == "project.yml" for f in changed)
print(f"LINT {int(ui)}")
print(f"APP {int(app)}")
EOF
) || exit 1
pkgs=$(echo "$plan" | sed -n 's/^PKGS //p')
lint=$(echo "$plan" | sed -n 's/^LINT //p')
app=$(echo "$plan" | sed -n 's/^APP //p')
# filter_for <pkg>: the --fast regex for a package, empty for a full run.
filter_for() { echo "$plan" | sed -n "s/^FILTER $1 //p"; }
if [ $list -eq 1 ]; then
  echo "${pkgs:-(no package)}"
  [ $fast -eq 1 ] && echo "$plan" | grep '^FILTER ' | sed 's/^FILTER /  fast /'
  exit 0
fi

rc=0
if [ "$lint" = 1 ]; then
  if out=$(scripts/lint-ui.sh 2>&1); then echo "== lint-ui ok"; else echo "$out" | tail -20; echo "== lint-ui FAILED"; rc=1; fi
fi
# SQCore goes to the Linux PC (in parallel with the Mac packages) when it is reachable; SQ_NO_LINUX=1 forces the Mac.
linux_pid=""; linux_out=""
case " $pkgs " in
  *" SQCore "*)
    if [ "${SQ_NO_LINUX:-0}" != 1 ] && [ -x scripts/test-linux.sh ] && ssh -o BatchMode=yes -o ConnectTimeout=2 "${SQ_LINUX_HOST:-cachy}" true 2>/dev/null; then
      linux_out=$(mktemp "${TMPDIR:-/tmp}/sqcheck-linux.XXXXXX")
      echo "== SQCore on Linux (parallel)"
      ( scripts/test-linux.sh "${SQ_TEST_FILTER:-$(filter_for SQCore)}" >"$linux_out" 2>&1; echo "EXIT $?" >>"$linux_out" ) &
      linux_pid=$!
      pkgs=$(echo " $pkgs " | sed 's/ SQCore / /; s/^ *//; s/ *$//')
    fi ;;
esac
if [ -n "$pkgs" ]; then
  if [ $fast -eq 1 ]; then
    # One test.sh call per package so each gets its own filter (full run where none was derived).
    for p in $pkgs; do
      f=$(filter_for "$p")
      [ -n "$f" ] && echo "== $p fast: $(echo "$f" | tr '|' ' ' | sed 's/(^ \[.\/\])(//; s/)(\/ \$)$//')"
      # A derived filter can name only suites of a test target this platform does not build (SQMediaFFmpegTests is
      # Windows-only): "matched 0 tests" then means "nothing of the change runs here", so run the package whole instead.
      out=$(SQ_TEST_FILTER="$f" scripts/test.sh "$p" 2>&1); prc=$?
      echo "$out"
      if [ $prc -ne 0 ] && [ -n "$f" ] && echo "$out" | grep -q "matched 0 tests"; then
        echo "== $p: the fast filter names no test built on this platform, full run"
        scripts/test.sh "$p" || rc=$?
      elif [ $prc -ne 0 ]; then
        rc=$prc
      fi
    done
  else
    # shellcheck disable=SC2086
    scripts/test.sh $pkgs || rc=$?
  fi
fi
if [ -n "$linux_pid" ]; then
  wait "$linux_pid"
  lrc=$(sed -n 's/^EXIT //p' "$linux_out" | tail -1)
  grep -v '^EXIT ' "$linux_out"
  rm -f "$linux_out"
  if [ "$lrc" = 2 ]; then
    echo "== Linux PC not reachable, SQCore on the Mac"
    SQ_TEST_FILTER="${SQ_TEST_FILTER:-$(filter_for SQCore)}" scripts/test.sh SQCore || rc=$?
  elif [ "$lrc" != 0 ]; then
    echo "== SQCore (Linux) FAILED"; rc=1
  else
    echo "== SQCore (Linux) ok"
  fi
fi
if [ "$app" = 1 ]; then
  if out=$(scripts/build.sh 2>&1); then echo "== app build ok"; else echo "$out"; rc=1; fi
fi
[ -z "$pkgs" ] && [ -z "$linux_pid" ] && [ "$lint" != 1 ] && [ "$app" != 1 ] && echo "== no package, UI or app source changed (docs/scripts only)"
exit $rc
