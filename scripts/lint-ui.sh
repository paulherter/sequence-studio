#!/bin/bash
# UI consistency lint: flags hard-coded UI values outside Theme.swift/ThemeTokens.swift.
# Usage: scripts/lint-ui.sh [--strict] [--update-baseline]
#   default: fail only on hits beyond scripts/lint-ui-baseline.txt (per file+rule counts)
#   --strict: ignore baseline, fail on any hit
#   --self-test: plants violations in a temp dir and checks the draw-* rules catch them (and pass clean code)
# Draw code (shared UI, both OS): sizes come from SQTokens (SQUIKit/DesignTokens.swift) or DrawTheme, never a raw number.
# Allowlist: scripts/lint-ui-allow.txt, lines "path[:line]:rule  reason" (reason required).
cd "$(dirname "$0")/.." || exit 2
STRICT=0; UPDATE=0; SELFTEST=0
for a in "$@"; do case "$a" in --strict) STRICT=1;; --update-baseline) UPDATE=1;; --self-test) SELFTEST=1;; esac; done
if [ $SELFTEST -eq 1 ]; then
  T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
  printf 'func a() {\n  cv.fill(roundedRect: r, radius: 4, c)\n  cv.draw("x", at: p, fontSize: 11, c)\n  let k = DrawColor(hex: 0x2C2C2C)\n}\n' > "$T/Bad.swift"
  printf 'func a() {\n  cv.fill(roundedRect: r, radius: DrawTheme.Radius.small, c)\n  cv.draw("x", at: p, fontSize: DrawTheme.TypeSize.body, c)\n}\n' > "$T/Good.swift"
  SQ_LINT_ONLY_DRAW="$T/Bad.swift" scripts/lint-ui.sh --strict > "$T/bad.out" 2>&1; bad=$?
  SQ_LINT_ONLY_DRAW="$T/Good.swift" scripts/lint-ui.sh --strict > "$T/good.out" 2>&1; good=$?
  n=$(grep -c "draw-" "$T/bad.out")
  if [ $bad -ne 0 ] && [ $good -eq 0 ] && [ "$n" -ge 3 ]; then echo "self-test ok (planted violations caught: $n)"; exit 0; fi
  echo "self-test FAILED (bad=$bad good=$good hits=$n)"; cat "$T/bad.out"; exit 1
fi
# UI packages (keep in sync with UI_PACKAGES in scripts/check.sh; DECISIONS "SQEditorUI split"). Missing ones are skipped.
UI_PACKAGES="SQUIKit SQEditorSession SQTimelineUI SQInspectorUI"
DIRS="App/Sources"
for p in $UI_PACKAGES; do [ -d "Packages/$p/Sources" ] && DIRS="Packages/$p/Sources $DIRS"; done
# Draw packages (shared UI): the draw-* rules below. SQ_LINT_ONLY_DRAW=<dir or file> scans only that (self-test).
DRAW_DIRS="App/Sources/SharedUI"
for p in SQDrawKit SQDrawShell SQDrawTimeline SQDrawMonitor SQDrawLibrary SQAppShell; do [ -d "Packages/$p/Sources" ] && DRAW_DIRS="Packages/$p/Sources $DRAW_DIRS"; done
if [ -n "$SQ_LINT_ONLY_DRAW" ]; then DRAW_DIRS="$SQ_LINT_ONLY_DRAW"; DIRS="/nonexistent"; fi
BASE=scripts/lint-ui-baseline.txt; ALLOW=scripts/lint-ui-allow.txt
RULES="color-literal|(NSColor|Color|UIColor)\((red|white|hue|srgbRed|calibrated|deviceRed|deviceWhite|hex)|\.(calibrated|device|sRGB)(Red|White)|calibrated(Red|White)|\bwhite: *[0-9]|0x[0-9A-Fa-f]{6}\b
font-literal|systemFont\(ofSize: *[0-9]|monospaced(Digit)?SystemFont\(ofSize: *[0-9]|\.system\(size: *[0-9]
radius-literal|cornerRadius(:| *=) *[0-9]|\.cornerRadius\( *[0-9]|(xRadius|yRadius): *[0-9]
layout-literal|\.padding\([^)]*[0-9]|rowHeight(:| *=) *[0-9]|NSEdgeInsets\(top: *[0-9]|EdgeInsets\(top: *[0-9]
native-menu-tooltip|[iI]tem[^ ]*\.toolTip *=
sf-symbol|systemSymbolName|systemName:|NSImage\(named:|SymbolConfiguration|Image\(systemName
modal-width-literal|\b(alert|dialog|sheet|d|a)\.width *= *[0-9]|SQDialog\.cardContent\([^)]*width: *[0-9]|SQModal\.cardFrame\([^)]*width: *[0-9]
native-control|\b(NSProgressIndicator|NSPopUpButton|NSButton|NSAlert|NSMenu)\b"
TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP".*' EXIT
while IFS='|' read -r name pat; do
  [ -z "$name" ] && continue
  # the pattern itself may contain '|' (read splits only the first field because pat is last)
  grep -rnE --include='*.swift' --exclude=Theme.swift --exclude=ThemeTokens.swift -e "$pat" $DIRS 2>/dev/null \
  | awk -F: -v r="$name" '{ line=$0; sub(/^[^:]*:[^:]*:/,"",line); if (line ~ /^[ \t]*\/\//) next; print $1 ":" $2 ":" r }'
done <<< "$RULES" > "$TMP.a"
DRAW_RULES="draw-radius|(radius|cornerRadius): *[0-9]
draw-font|fontSize: *[0-9]
draw-hex|0x[0-9A-Fa-f]{6}\\b"
while IFS='|' read -r name pat; do
  [ -z "$name" ] && continue
  grep -rnE --include='*.swift' --exclude=DrawTheme.swift --exclude=TimelineSkin.swift --exclude=DesignTokens.swift -e "$pat" $DRAW_DIRS 2>/dev/null \
  | awk -F: -v r="$name" '{ line=$0; sub(/^[^:]*:[^:]*:/,"",line); if (line ~ /^[ \t]*\/\//) next; print $1 ":" $2 ":" r }'
done <<< "$DRAW_RULES" > "$TMP.b"
cat "$TMP.a" "$TMP.b" | sort -u > "$TMP"
if [ -f "$ALLOW" ]; then
  grep -vE '^[[:space:]]*(#|$)' "$ALLOW" | awk '{print $1}' > "$TMP.allow"
  if [ -s "$TMP.allow" ]; then
    awk -F: 'NR==FNR{a[$0]=1;next} { if (($1":"$3) in a || ($1":"$2":"$3) in a) next; print }' "$TMP.allow" "$TMP" > "$TMP.f"
    mv "$TMP.f" "$TMP"
  fi
fi
awk -F: '{print $1" "$3}' "$TMP" | sort | uniq -c | awk '{print $2" "$3" "$1}' > "$TMP.counts"
if [ $UPDATE -eq 1 ]; then
  { echo "# per-file counts: path rule count (regenerate: scripts/lint-ui.sh --update-baseline)"; cat "$TMP.counts"; } > "$BASE"
  echo "baseline written: $(wc -l < "$TMP.counts" | tr -d ' ') entries"
  exit 0
fi
FAIL=0
if [ $STRICT -eq 1 ]; then
  awk -F: '{printf "%s:%s: %s\n",$1,$2,$3}' "$TMP"
  [ -s "$TMP" ] && FAIL=1
else
  awk 'NR==FNR{ if ($0 !~ /^#/) b[$1" "$2]=$3; next } { if ($3 > b[$1" "$2]+0) print $1" "$2" "b[$1" "$2]+0 }' "$BASE" "$TMP.counts" > "$TMP.new"
  if [ -s "$TMP.new" ]; then
    FAIL=1
    while read -r f r n; do
      echo "NEW $r in $f (baseline $n):"
      grep -E "^$f:[0-9]+:$r\$" "$TMP" | awk -F: '{print "  "$1":"$2": "$3}'
    done < "$TMP.new"
  fi
fi
echo "--- summary: total hits per rule$([ $STRICT -eq 1 ] && echo ' (strict)') ---"
awk -F: '{c[$3]++} END{for(r in c) print "  "r": "c[r]}' "$TMP" | sort
if [ $FAIL -eq 1 ]; then
  echo "FAIL: UI lint hits$([ $STRICT -eq 0 ] && echo ' beyond baseline')"
  exit 1
fi
echo "OK"
