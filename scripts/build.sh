#!/bin/zsh
# Builds build/FanCurve.app (app + root helper), runs the tests, signs the bundle.
#   scripts/build.sh            build + test
#   scripts/build.sh --install  also copy to /Applications
set -euo pipefail
cd "${0:A:h}/.."
ROOT=$PWD
BUILD=$ROOT/build
APP=$BUILD/FanCurve.app
mkdir -p "$BUILD"

echo "▸ helper"
clang -O2 -fobjc-arc -Wall -Werror -mmacosx-version-min=14.0 -framework Foundation -framework IOKit \
  -o "$BUILD/fancurved" Helper/fancurved.m

echo "▸ helper tests"
# Full output only on failure.
if ! out=$(/usr/bin/python3 -I Tests/helper_test.py "$BUILD/fancurved" 2>/dev/null); then
  print -r -- "$out" | grep -v '^PASS'; exit 1
fi
print -r -- "${out##*$'\n'}"

echo "▸ app"
SOURCES=(App/Localization.swift App/Curve.swift App/HelperClient.swift App/HelperInstaller.swift App/AppModel.swift \
         App/CurveEditor.swift App/Views.swift App/FanCurveApp.swift)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 -parse-as-library \
  -o "$APP/Contents/MacOS/FanCurve" $SOURCES

echo "▸ unit tests"
swiftc -swift-version 5 -target arm64-apple-macosx14.0 -o "$BUILD/unit-tests" \
  App/Localization.swift App/Curve.swift Tests/CurveTests.swift
if ! out=$("$BUILD/unit-tests"); then print -r -- "$out" | grep -v '^PASS'; exit 1; fi
print -r -- "${out##*$'\n'}"

echo "▸ bundle"
cp App/Info.plist "$APP/Contents/Info.plist"
cp "$BUILD/fancurved" Helper/install-helper.sh "$APP/Contents/Resources/"
for lp in App/Localization/*.lproj; do
  plutil -lint -s "$lp/Localizable.strings"
  cp -R "$lp" "$APP/Contents/Resources/"
done
if [[ ! -f "$BUILD/AppIcon.icns" || scripts/make-icon.swift -nt "$BUILD/AppIcon.icns" ]]; then
  rm -rf "$BUILD/AppIcon.iconset"
  swift scripts/make-icon.swift "$BUILD/AppIcon.iconset"
  iconutil -c icns -o "$BUILD/AppIcon.icns" "$BUILD/AppIcon.iconset"
fi
cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ sign"
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')
IDENTITY=${IDENTITY:--}
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP/Contents/Resources/fancurved"
codesign --force --options runtime --timestamp=none -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "  signed with: ${IDENTITY%%\(*}"

if [[ "${1:-}" == "--install" ]]; then
  echo "▸ install to /Applications"
  pkill -x FanCurve 2>/dev/null && sleep 0.5 || true
  rm -rf /Applications/FanCurve.app
  cp -R "$APP" /Applications/
fi
echo "✓ $APP"
