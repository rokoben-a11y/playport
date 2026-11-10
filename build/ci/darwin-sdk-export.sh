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

# --probe stops after a bounded `xtool --version`. The private 5-minute job
# runs that before anyone starts `sdk build`.
mode=export
if [ "${1:-}" = "--probe" ]; then
    mode=probe
    shift
fi

# Xcode 27.1 (27A9275) is the default on the xcode-27 runner image.
# Its SDK names, from images/macos/xcode-27-arm64-Readme.md "Installed SDKs":
#   iOS 27.1  iphoneos27.1  (Xcode 27.1)
#   macOS 27.0 macosx27.0   (Xcode 27.0 and 27.1)
# Apple's Xcode support page lists the same SDKs: iOS 27.1 and macOS 27.
# The directories are those names in the platform SDK folder.
XCODE=${XCODE:-/Applications/Xcode_27.1.app}
IOS_SDK=iPhoneOS27.1.sdk
MAC_SDK=MacOSX27.0.sdk
OUT=${1:?output directory}
ARCH=${ARCH:-x86_64}
XTOOL_TAG=1.20.1
XTOOL_ZIP_SHA256=39123efc283528b119fa3567dc1123059d6690aab76c80e6003470d17c333ca2

case "$ARCH" in
x86_64|arm64) ;;
*) echo "ARCH must be x86_64 or arm64, not $ARCH" >&2; exit 2 ;;
esac

ios="$XCODE/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/$IOS_SDK"
mac="$XCODE/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/$MAC_SDK"
if [ ! -d "$XCODE/Contents/Developer" ] || [ ! -d "$ios" ] || [ ! -d "$mac" ]; then
    echo "Xcode at $XCODE does not contain $IOS_SDK and $MAC_SDK" >&2
    echo "Xcode 27.1 ships iphoneos27.1 and macosx27.0 (xcode-27-arm64-Readme.md)." >&2
    find "$XCODE/Contents/Developer/Platforms" -maxdepth 4 -type d -name '*.sdk' -print >&2 || true
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
# Contents/MacOS/xtool is the GUI (sh.xtool.XToolMac). XToolMac.swift starts
# XToolMacUI unless XTL_CLI=1. The app's own CLI is Contents/Resources/bin/xtool,
# which exports that variable and then execs the GUI binary. Probe 42405564066
# ran the GUI binary: --version never returned, and spctl already accepted it.
cli=
while IFS= read -r -d '' f; do cli=$f; break; done < <(find "$work/app" -type f -path '*/Contents/Resources/bin/xtool' -print0)
[ -n "$cli" ] && [ -x "$cli" ] || { echo "xtool.app.zip has no Contents/Resources/bin/xtool" >&2; find "$work/app" -type f -print >&2; exit 1; }
echo "xtool cli $cli"
grep -n 'XTL_CLI' "$cli"

run_bounded() {
    local secs=$1
    shift
    echo "run (${secs}s): $*"
    "$@" </dev/null &
    local pid=$!
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$i" -ge "$secs" ]; then
            echo "no exit after ${secs}s, stopping pid $pid" >&2
            kill "$pid" 2>/dev/null || true
            sleep 1
            kill -9 "$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
        i=$((i + 1))
    done
    wait "$pid"
}

version_failed() {
    echo "xtool --version failed" >&2
    codesign -dv --verbose=4 "$cli" >&2 || true
    exit 1
}
run_bounded 30 "$cli" --version || version_failed
echo "xtool --version ok"
if [ "$mode" = probe ]; then
    echo "probe done; sdk build not started"
    exit 0
fi

rm -rf "$OUT/darwin.xtoolsdk"
"$cli" sdk build "$XCODE" "$OUT" --arch "$ARCH"
sdk=$OUT/darwin.xtoolsdk
test -d "$sdk/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/$IOS_SDK"
test -d "$sdk/Developer/Platforms/MacOSX.platform/Developer/SDKs/$MAC_SDK"
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
