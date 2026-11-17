#!/bin/bash
# Builds a Release app, signs it (inside-out, hardened runtime, no debug entitlements), optionally notarizes + staples it,
# and writes build/Sequence Studio.dmg (+ .zip) for a tester on another Mac.
# Usage: scripts/package.sh                  Developer ID if installed, else ad-hoc; notarizes when the keychain profile exists
#        scripts/package.sh --dist           also copies the DMG to dist/SequenceStudio-YYYY-MM-DD.dmg
#        scripts/package.sh --no-notarize    skip notarization (or SQ_NOTARIZE=0)
#        SQ_SIGN_ID="-" scripts/package.sh   force ad-hoc
#        SQ_NOTARY_PROFILE=name              notarytool keychain profile (default sq-notary)
# Verify the result with: scripts/verify-package.sh "build/Sequence Studio.dmg"
cd "$(dirname "$0")/.." || exit 1
DIST=0; NOTARIZE="${SQ_NOTARIZE:-1}"
for a in "$@"; do
  case "$a" in
    --dist) DIST=1 ;;
    --no-notarize) NOTARIZE=0 ;;
    *) echo "unknown option: $a"; exit 1 ;;
  esac
done
PROFILE="${SQ_NOTARY_PROFILE:-sq-notary}"
scripts/build.sh Release || exit 1
APP="build/DerivedData-Release/Build/Products/Release/Sequence Studio.app"
[ -d "$APP" ] || { echo "FAILED: $APP missing"; exit 1; }
OUT=build/package
rm -rf "$OUT"
mkdir -p "$OUT"
ditto "$APP" "$OUT/Sequence Studio.app"
APP="$OUT/Sequence Studio.app"

# Subject mask models (not in the repository, see docs/THIRD_PARTY.md): copied into the app with the Apache-2.0 text
# and the statement of changes. SQ_SUBJECT_MASK_MODELS overrides the folder. Without them the app falls back to Vision.
MODELS="${SQ_SUBJECT_MASK_MODELS:-Tools/SubjectMaskSpike/work/models/compiled}"
MODEL_PARTS="edgetam_encoder_fp16 edgetam_decoder_fp16 edgetam_decoder_box_fp16 edgetam_mem_encoder_fp16 edgetam_mem_attention_fp16"
MISSING=""
for m in $MODEL_PARTS; do [ -d "$MODELS/$m.mlmodelc" ] || MISSING="$MISSING $m"; done
if [ -z "$MISSING" ]; then
  DEST="$APP/Contents/Resources/SubjectMask"
  mkdir -p "$DEST"
  for m in $MODEL_PARTS; do ditto "$MODELS/$m.mlmodelc" "$DEST/$m.mlmodelc" || { echo "FAILED: copy $m"; exit 1; }; done
  cp Packages/SQAnalysis/EDGETAM-LICENSE "$DEST/LICENSE-Apache-2.0.txt" || exit 1
  cp Packages/SQAnalysis/EDGETAM-NOTICE.txt "$DEST/NOTICE.txt" || exit 1
  echo "Subject mask models: bundled ($(du -sh "$DEST" | cut -f1))"
elif [ "${SQ_ALLOW_NO_MODELS:-0}" = "1" ]; then
  echo "WARNING: subject mask models missing ($MISSING ): this build tracks with Vision only"
else
  echo "FAILED: subject mask models missing in $MODELS:$MISSING (SQ_ALLOW_NO_MODELS=1 packages without them)"; exit 1
fi

ID="${SQ_SIGN_ID:-}"
if [ -z "$ID" ]; then
  ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
  [ -n "$ID" ] || ID="-"
fi
echo "Signing identity: $ID"

# Sign inside-out (nested code first, the app last) with explicit entitlements: Xcode injects get-task-allow, re-signing
# with our own file drops it. --deep is only used for verifying, never for signing.
if [ "$ID" = "-" ]; then
  # Ad-hoc + hardened runtime: library validation would refuse the ad-hoc Gyroflow library (no Team ID), see the file.
  ENT=App/AdHoc.entitlements; TS="--timestamp=none"
else
  ENT=App/Release.entitlements; TS="--timestamp"
fi
sign() { codesign --force --options runtime $TS --entitlements "$ENT" -s "$ID" "$1" || { echo "FAILED: codesign $1"; exit 1; }; }
# Nested code: dylibs, frameworks, XPC services, helper apps (deepest paths first).
NESTED=$(find "$APP/Contents" \( -name "*.dylib" -o -name "*.framework" -o -name "*.xpc" -o -name "*.app" -o -name "*.appex" \) 2>/dev/null \
  | awk '{print length($0) "\t" $0}' | sort -rn | cut -f2-)
while IFS= read -r n; do
  [ -n "$n" ] && sign "$n"
done <<< "$NESTED"
sign "$APP"
codesign --verify --deep --strict "$APP" || { echo "FAILED: codesign --verify"; exit 1; }
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q get-task-allow; then
  echo "FAILED: get-task-allow still in the signed entitlements"; exit 1
fi
codesign -dv "$APP" 2>&1 | grep -q "flags=.*runtime" || { echo "FAILED: hardened runtime flag missing"; exit 1; }

# Portability: only system libraries, no absolute rpaths, nothing outside the bundle.
BIN="$APP/Contents/MacOS/Sequence Studio"
bad=$(otool -L "$BIN" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/System/|/usr/lib/|@rpath|@executable_path|@loader_path)')
[ -z "$bad" ] || { echo "FAILED: non-system linked libraries:"; echo "$bad"; exit 1; }
rp=$(otool -l "$BIN" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' | grep -v -E '^(@|/usr/lib|/System)')
[ -z "$rp" ] || { echo "FAILED: absolute rpaths:"; echo "$rp"; exit 1; }
if strings -a "$BIN" | grep -q "$HOME"; then
  echo "NOTE: binary contains paths under $HOME (usually debug/#file strings):"
  strings -a "$BIN" | grep "$HOME" | sort -u | head -5
fi
ls "$APP/Contents/Frameworks" 2>/dev/null | sed 's/^/bundled framework: /'

# Notarization (Developer ID only, needs the one-time keychain profile; credentials are never read or stored here).
NOTARIZED=0
notarize_ok=0
if [ "$ID" != "-" ] && [ "$NOTARIZE" != 0 ]; then
  probe=$(xcrun notarytool history --keychain-profile "$PROFILE" 2>&1) && probe_ok=1 || probe_ok=0
  if [ "$probe_ok" = 1 ]; then
    notarize_ok=1
  else
    echo "Notarization skipped. notarytool said: $(echo "$probe" | head -2 | tr '\n' ' ')"
    echo "If the profile '$PROFILE' really is missing, one-time setup (run it yourself, it asks for an app-specific password):"
    echo "  xcrun notarytool store-credentials $PROFILE --apple-id <your Apple ID> --team-id 63L6TSM2Y9"
    echo "  (create the app-specific password at appleid.apple.com > Sign-In and Security > App-Specific Passwords)"
  fi
fi
submit() { # $1 = file to notarize
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1 | tee build/notary.log | tail -5
  grep -q "status: Accepted" build/notary.log
}
if [ "$notarize_ok" = 1 ]; then
  ditto -c -k --keepParent "$APP" build/notarize-app.zip
  if submit build/notarize-app.zip && xcrun stapler staple "$APP"; then
    NOTARIZED=1
  else
    echo "FAILED: notarization of the app (log: build/notary.log; details: xcrun notarytool log <id> --keychain-profile $PROFILE)"; exit 1
  fi
  rm -f build/notarize-app.zip
fi

ditto -c -k --keepParent "$APP" "build/Sequence Studio.zip" || exit 1
# DMG with an Applications shortcut (drag to install), made from the signed (and stapled) app.
DMGDIR=build/dmg
DMG="build/Sequence Studio.dmg"
rm -rf "$DMGDIR" "$DMG"
mkdir -p "$DMGDIR"
ditto "$APP" "$DMGDIR/Sequence Studio.app"
ln -s /Applications "$DMGDIR/Applications"
scripts/make-dmg.sh "$DMGDIR" "$DMG" "Sequence Studio" || { echo "FAILED: hdiutil"; exit 1; }
rm -rf "$DMGDIR"
if [ "$ID" != "-" ]; then
  codesign --force --timestamp -s "$ID" "$DMG" || { echo "FAILED: codesign dmg"; exit 1; }
fi
if [ "$NOTARIZED" = 1 ]; then
  if submit "$DMG" && xcrun stapler staple "$DMG"; then :; else
    echo "FAILED: notarization of the DMG (log: build/notary.log)"; exit 1
  fi
fi
if [ "$DIST" = 1 ]; then
  mkdir -p dist
  cp -f "$DMG" "dist/SequenceStudio-$(date +%Y-%m-%d).dmg"
  echo "OK: dist/SequenceStudio-$(date +%Y-%m-%d).dmg"
fi
du -h "$DMG" | awk '{print "OK: build/Sequence Studio.dmg ("$1")"}'
du -h "build/Sequence Studio.zip" | awk '{print "OK: build/Sequence Studio.zip ("$1")"}'
if [ "$ID" = "-" ]; then
  echo "Ad-hoc signed (a downloaded copy is usually refused on current macOS): tester runs xattr -dr com.apple.quarantine \"/Applications/Sequence Studio.app\"."
elif [ "$NOTARIZED" = 1 ]; then
  echo "Developer ID signed and notarized: the tester just drags the app to Applications and double-clicks it."
else
  echo "Developer ID signed, NOT notarized: on current macOS the tester opens it once, gets the refusal, then System Settings > Privacy & Security > Open Anyway (or: xattr -dr com.apple.quarantine \"/Applications/Sequence Studio.app\"). Notarize once the profile exists (see above)."
fi
echo "Check: scripts/verify-package.sh \"$DMG\""
