#!/bin/bash
# make screens: boots the sim, drives key screens via launch args, captures
# PNGs into Artifacts/run-<date>/ so Osman can eyeball the UI (spec C10).
set -e
SIM_ID="$1"; APP="$2"; BUNDLE="$3"
OUT="Artifacts/run-$(date +%Y-%m-%d)"
mkdir -p "$OUT"
xcrun simctl boot "$SIM_ID" 2>/dev/null || true
xcrun simctl privacy "$SIM_ID" grant photos-add "$BUNDLE" 2>/dev/null || true
xcrun simctl install "$SIM_ID" "$APP"

shot() {
  local name="$1"; shift
  xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null || true
  xcrun simctl launch "$SIM_ID" "$BUNDLE" --suppress-onboarding "$@" >/dev/null
  sleep 5
  xcrun simctl io "$SIM_ID" screenshot "$OUT/$name.png" >/dev/null
  echo "screens: $OUT/$name.png"
}

shot library
shot editor --screen editor
shot editor-photo --screen editor-photo
shot paywall --screen paywall
xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$SIM_ID" "$BUNDLE" --reset-onboarding >/dev/null
sleep 4
xcrun simctl io "$SIM_ID" screenshot "$OUT/onboarding.png" >/dev/null
echo "screens: $OUT/onboarding.png"
xcrun simctl terminate "$SIM_ID" "$BUNDLE" 2>/dev/null || true
echo "screens: captured into $OUT"
