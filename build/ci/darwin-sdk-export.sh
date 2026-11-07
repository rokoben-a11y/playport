#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build xtool 1.20.1's slim Darwin SDK from the Xcode.app already on the runner.
#
# xtool 1.20.1 (pins.lock) accepts an installed Xcode.app:
#   Sources/XToolSupport/SDKCommand.swift  DevSDKBuildCommand path help is
#   "Path to Xcode.xip or Xcode.app"
#   SDKBuilder.Input treats a directory with Contents/Developer as .app
# `xtool sdk install` on macOS does not build anything. InstallSDKOperation
# prints "Skipping SDK install; the iOS SDK ships with Xcode on macOS".
# The bundle Linux can install is `xtool sdk build`'s darwin.xtoolsdk.
# That command always uses Mode.buildSlim (independent copies of the files
# SDKEntry.wanted lists, including both iPhoneOS and MacOSX SDKs, the
# toolchain usr/lib, and the platform Developer/usr/lib). It is not a
# hand-picked subset of the .app.
#
# The Linux host is x86_64 (llvm-mingw's Ubuntu archive and rust.sh's
# rustup-init). --arch x86_64 fetches xtool's linux toolset for that host.
#
# Run only from the private ios-signing workflow. Do not upload this bundle
# from the public Playport repository.

set -euo pipefail

XCODE=${XCODE:-/Applications/Xcode_26.6.app}
OUT=${1:?output directory}
ARCH=${ARCH:-x86_64}
XTOOL_TAG=1.20.1
XTOOL_ZIP_SHA256=39123efc283528b119fa3567dc1123059d6690aab76c80e6003470d17c333ca2

case "$ARCH" in
x86_64|arm64) ;;
*) echo "ARCH must be x86_64 or arm64, not $ARCH" >&2; exit 2 ;;
esac

ios="$XCODE/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk"
mac="$XCODE/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
if [ ! -d "$XCODE/Contents/Developer" ] || [ ! -d "$ios" ] || [ ! -d "$mac" ]; then
    echo "Xcode at $XCODE is not the 26.6 app with iPhoneOS26.5.sdk and MacOSX26.5.sdk" >&2
    exit 1
fi
echo "xcode $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$XCODE/Contents/Info.plist" 2>/dev/null || true) $XCODE"

mkdir -p "$OUT"
work=$(mktemp -d "${OUT%/}/xtool-XXXX")
trap 'rm -rf "$work"' EXIT

zip=$work/xtool.app.zip
curl -fL --retry 3 -o "$zip" "https://github.com/xtool-org/xtool/releases/download/${XTOOL_TAG}/xtool.app.zip"
echo "$XTOOL_ZIP_SHA256  $zip" | shasum -a 256 -c -
ditto -x -k "$zip" "$work/app"
xtool=
while IFS= read -r -d '' f; do xtool=$f; break; done < <(find "$work/app" -type f -path '*/Contents/MacOS/xtool' -print0)
[ -n "$xtool" ] && [ -x "$xtool" ] || { echo "xtool.app.zip has no Contents/MacOS/xtool" >&2; exit 1; }
"$xtool" --version

rm -rf "$OUT/darwin.xtoolsdk"
"$xtool" sdk build "$XCODE" "$OUT" --arch "$ARCH"
sdk=$OUT/darwin.xtoolsdk
test -d "$sdk/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk"
test -d "$sdk/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
test -f "$sdk/info.json"
test -f "$sdk/swift-sdk.json"
test -f "$sdk/toolset.json"
test -d "$sdk/toolset/bin"
# Slim bundles omit the Xcode.app copy. A normal bundle keeps it.
if [ -d "$sdk/Xcode.app" ]; then
    echo "darwin.xtoolsdk contains Xcode.app; xtool 1.20.1 sdk build is slim and must not" >&2
    exit 1
fi
echo "darwin sdk $sdk"
find "$sdk/Developer/Platforms" -maxdepth 4 -type d -name '*.sdk' -print
