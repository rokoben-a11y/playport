#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Ubuntu x86_64 host for `./pp build --variant release --unsigned`.
#
# The Darwin SDK is a darwin.xtoolsdk directory already built by
# build/ci/darwin-sdk-export.sh (xtool 1.20.1 `sdk build` of Xcode.app).
# This script installs it with the official xtool 1.20.1 Linux AppImage.
# `sdk install` of a .xtoolsdk copies the bundle and adds this machine's
# clang resource directory (PackLib/DarwinSDK.swift addHostClangResourceDir).
# That step has to run here, on the clang that will compile, not on the Mac.
#
# The patched xtool the app link uses is still build/toolchain/xtool.sh,
# which `pp build` runs itself. The AppImage is only the SDK installer and
# matches the 1.20.1 SDK layout. It is not a substitute for the patched binary.
#
# pp setup exits 1 when netmuxd's socket is absent. A build machine has no
# phone. The SDK and llvm-mingw are checked afterwards; a missing socket does
# not hide a missing toolchain.

set -euo pipefail

SDK=${1:?path to darwin.xtoolsdk}
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
export PLAYPORT_BUILD=${PLAYPORT_BUILD:-$ROOT/.work}
mkdir -p "$PLAYPORT_BUILD/cache" "$PLAYPORT_BUILD/ci"
export DEBIAN_FRONTEND=noninteractive

LLVM_MINGW_SHA256=bb7bb7654b33d5aa8712acb837c963b2e0c56352560c76105270a3268c665c21
LLVM_MINGW_URL=https://github.com/mstorsjo/llvm-mingw/releases/download/20260922/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64.tar.xz
XTOOL_APPIMAGE_SHA256=040c58d5c708f613b9b74cbdb24e25e8d72c47ff86941f19463626d811159831
SWIFT_URL=https://download.swift.org/swift-6.4.1-release/ubuntu2404/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-ubuntu24.04.tar.gz

if [ "$(uname -m)" != x86_64 ]; then
    echo "this bootstrap is the x86_64 Linux one (llvm-mingw and rustup-init); this machine is $(uname -m)" >&2
    exit 2
fi

sudo apt-get update -qq
sudo apt-get install -y -qq \
    build-essential ca-certificates curl gnupg xz-utils zstd git \
    cmake ninja-build meson python3 python3-pefile \
    bison flex gettext openssl xxd rsync p7zip-full pkg-config \
    libncurses6 libxml2 libcurl4 zlib1g

# LLVM 22 from apt.llvm.org. The pipeline's inputs stage wants the unversioned names.
if ! command -v clang-22 >/dev/null 2>&1; then
    curl -fsSL https://apt.llvm.org/llvm.sh -o "$PLAYPORT_BUILD/cache/llvm.sh"
    sudo bash "$PLAYPORT_BUILD/cache/llvm.sh" 22
fi
llvm_bin=$(dirname "$(readlink -f "$(command -v clang-22)")")
for tool in clang clang++ ld64.lld llvm-ar llvm-nm llvm-objdump llvm-objcopy llvm-lipo; do
    if [ ! -x "$llvm_bin/$tool" ]; then
        echo "LLVM 22 bin $llvm_bin has no $tool" >&2
        exit 1
    fi
    sudo ln -sfn "$llvm_bin/$tool" "/usr/local/bin/$tool"
done
hash -r
clang --version | head -1

# Swift 6.4.1. xtool 1.20.1's SDK toolset comment requires Swift 6.4 or newer
# for the Linux swift-build librarian paths. The workstation that built 0.5.0
# was on 6.4 (docs/evidence/2026-10-15-memory-defaults.md).
swift_root=$PLAYPORT_BUILD/inputs/swift
if [ ! -x "$swift_root/usr/bin/swift" ]; then
    tar=$PLAYPORT_BUILD/cache/swift-6.4.1-RELEASE-ubuntu24.04.tar.gz
    curl -fL --retry 3 -o "$tar" "$SWIFT_URL"
    curl -fsSL --compressed -o "$tar.sig" "$SWIFT_URL.sig"
    # www.swift.org/keys/all-keys.asc is the official keyring (Swift 6.x Release
    # Signing Key 52BB7E3DE28A71BE22EC05FFEF80A866B47A981F). The server gzip-encodes
    # it; piping the compressed bytes to gpg is "no valid OpenPGP data found"
    # (run 42406791715). --compressed decodes that. HTML or an empty body is refused.
    key=$PLAYPORT_BUILD/cache/swift-all-keys.asc
    curl -fsSL --compressed -o "$key" "https://www.swift.org/keys/all-keys.asc"
    python3 - "$key" << 'PY'
import pathlib, sys
b = pathlib.Path(sys.argv[1]).read_bytes().lstrip()
if not b or b.startswith((b"<", b"<!DOCTYPE", b"\x1f\x8b")) or not b.startswith(b"-----BEGIN PGP PUBLIC KEY BLOCK-----"):
    sys.exit("Swift signing key is empty, HTML, or still compressed")
PY
    gpg --batch --import "$key"
    fpr=52BB7E3DE28A71BE22EC05FFEF80A866B47A981F
    gpg --batch --with-colons --fingerprint | grep -q "$fpr" || {
        echo "official Swift 6.x release key $fpr is not in the imported keyring" >&2
        exit 1
    }
    gpg --batch --status-fd 1 --verify "$tar.sig" "$tar" | tee "$PLAYPORT_BUILD/ci/swift-sig.txt"
    grep -q '^\[GNUPG:\] VALIDSIG ' "$PLAYPORT_BUILD/ci/swift-sig.txt"
    mkdir -p "$swift_root"
    tar -C "$PLAYPORT_BUILD/cache" -xzf "$tar"
    src=$(find "$PLAYPORT_BUILD/cache" -maxdepth 1 -type d -name 'swift-6.4.1-RELEASE-*' -print -quit)
    [ -n "$src" ] || { echo "swift tarball has no swift-6.4.1-RELEASE directory" >&2; exit 1; }
    # The tarball's usr/ is the toolchain. Move it into the build area.
    rm -rf "$swift_root"
    mv "$src" "$swift_root"
fi
export PATH="$swift_root/usr/bin:$PATH"
swift --version

# llvm-mingw 20260922 UCRT, then the arm64ec CRT rebuild.
mingw=$PLAYPORT_BUILD/inputs/llvm-mingw-20260922-ucrt
if [ ! -x "$mingw/bin/aarch64-w64-mingw32-clang" ]; then
    arc=$PLAYPORT_BUILD/cache/llvm-mingw-20260922-ucrt-ubuntu-22.04-x86_64.tar.xz
    curl -fL --retry 3 -o "$arc" "$LLVM_MINGW_URL"
    echo "$LLVM_MINGW_SHA256  $arc" | sha256sum -c -
    tar -C "$PLAYPORT_BUILD/cache" -xJf "$arc"
    unpacked=$(find "$PLAYPORT_BUILD/cache" -maxdepth 1 -type d -name 'llvm-mingw-20260922-ucrt-*' -print -quit)
    [ -n "$unpacked" ] || { echo "llvm-mingw tarball has no top directory" >&2; exit 1; }
    rm -rf "$mingw"
    mv "$unpacked" "$mingw"
fi
bash "$ROOT/build/toolchain/llvm-mingw-arm64ec.sh" "$mingw"
export LLVM_MINGW=$mingw

# Install the prebuilt SDK with xtool 1.20.1. clang on PATH is LLVM 22, so the
# resource directory copied into the SDK is that clang's.
test -d "$SDK/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk"
test -d "$SDK/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk"
test -f "$SDK/toolset.json"
appimage=$PLAYPORT_BUILD/cache/xtool-1.20.1-x86_64.AppImage
curl -fL --retry 3 -o "$appimage" "https://github.com/xtool-org/xtool/releases/download/1.20.1/xtool-x86_64.AppImage"
echo "$XTOOL_APPIMAGE_SHA256  $appimage" | sha256sum -c -
chmod +x "$appimage"
"$appimage" --appimage-extract-and-run sdk install "$SDK"
# xtool 1.20.1 writes the SDK under $XDG_CONFIG_HOME/swiftpm when that variable
# is set (GitHub ubuntu runners set it), and under ~/.swiftpm otherwise.
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    installed=$XDG_CONFIG_HOME/swiftpm/swift-sdks/darwin.artifactbundle
else
    installed=$HOME/.swiftpm/swift-sdks/darwin.artifactbundle
fi
echo "installed Darwin SDK $installed"
if [ ! -d "$installed/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.5.sdk" ] \
    || [ ! -d "$installed/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk" ]; then
    echo "xtool sdk install did not leave iPhoneOS26.5.sdk and MacOSX26.5.sdk in $installed" >&2
    exit 1
fi
export DARWIN_SDK=$installed

# Record the two toolchains. A missing phone socket is the expected nonzero
# status on a machine that does not install; the two paths still have to be recorded.
set +e
./pp setup --llvm-mingw "$LLVM_MINGW" --darwin-sdk "$DARWIN_SDK"
setup_rc=$?
set -e
./pp setup --check > "$PLAYPORT_BUILD/ci/setup.txt" || true
grep -q "^LLVM_MINGW " "$PLAYPORT_BUILD/ci/setup.txt"
grep -q "^DARWIN_SDK " "$PLAYPORT_BUILD/ci/setup.txt"
if grep -E '^LLVM_MINGW |^DARWIN_SDK ' "$PLAYPORT_BUILD/ci/setup.txt" | grep -q '('; then
    cat "$PLAYPORT_BUILD/ci/setup.txt" >&2
    exit 1
fi
if [ "$setup_rc" -ne 0 ] && grep -q '^PLAYPORT_USBMUX_SOCKET .*(' "$PLAYPORT_BUILD/ci/setup.txt"; then
    echo "pp setup: no netmuxd socket; the build does not need the phone"
fi

export PLAYPORT_OUT=$PLAYPORT_BUILD/ci-out
rm -rf "$PLAYPORT_OUT"
./pp build --variant release --unsigned
mapfile -t ipas < <(find "$PLAYPORT_OUT" -type f -name 'Playport-*-release-unsigned-*.ipa' | sort)
[ "${#ipas[@]}" -eq 1 ] || { echo "expected one unsigned IPA, found ${#ipas[@]}"; printf '%s\n' "${ipas[@]-}"; exit 1; }
mkdir -p "$ROOT/ci"
cp "${ipas[0]}" "$ROOT/ci/Playport-release-unsigned.ipa"
sha256sum "$ROOT/ci/Playport-release-unsigned.ipa" | tee "$ROOT/ci/Playport-release-unsigned.ipa.sha256"
echo "unsigned IPA $ROOT/ci/Playport-release-unsigned.ipa"
