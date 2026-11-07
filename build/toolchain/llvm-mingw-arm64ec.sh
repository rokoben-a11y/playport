#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Rebuild the aarch64 CRT in an extracted llvm-mingw 20260922 UCRT tree so it
# has the arm64ec import libraries FEX needs (docs/BUILDING.md, "llvm-mingw").
#
# The published tarball is built without arm64ec in ARCHS, so its aarch64 CRT
# configure does not pass --enable-arm64x (mstorsjo/llvm-mingw build-mingw-w64.sh
# at tag 20260922 sets that flag only when arm64ec is in ARCHS, then skips
# building an arm64ec CRT of its own). This script configures the locked
# mingw-w64 commit the same way that script configures aarch64, with the
# flags BUILDING.md names: --enable-libarm64 --enable-arm64x --enable-cfguard
# --with-default-msvcrt=ucrt --enable-silent-rules.
#
# The prefix is the aarch64 sysroot, $LLVM_MINGW/aarch64-w64-mingw32, which is
# where that script installs and where aarch64-w64-mingw32-clang searches.
# BUILDING.md writes --prefix=$LLVM_MINGW. A prefix of the toolchain root
# would install into $LLVM_MINGW/lib, which the aarch64 driver does not search,
# so the rebuilt import libraries would not be the ones the compiler links.
#
# Then the compiler-rt builtins are copied over the sysroot's libgcc names,
# as BUILDING.md's second step. The tarball's own libclang_rt.builtins-aarch64.a
# is the file that is copied. Nothing here fetches a second compiler-rt.

set -euo pipefail

LLVM_MINGW=${1:?llvm-mingw root}
MINGW_W64_VERSION=57b595039040eaa15bece85b7cc71d952281b269
src=${MINGW_W64_SRC:-${PLAYPORT_BUILD:-$(cd "$(dirname "$0")/../.." && pwd)/.work}/cache/mingw-w64}
sysroot=$LLVM_MINGW/aarch64-w64-mingw32

[ -x "$LLVM_MINGW/bin/aarch64-w64-mingw32-clang" ] || {
    echo "no aarch64-w64-mingw32-clang in $LLVM_MINGW" >&2
    exit 1
}

if [ ! -f "$src/mingw-w64-crt/configure" ]; then
    rm -rf "$src"
    mkdir -p "$(dirname "$src")"
    git init -q "$src"
    git -C "$src" remote add origin https://github.com/mingw-w64/mingw-w64.git
    git -C "$src" fetch -q --depth 1 origin "$MINGW_W64_VERSION"
    git -C "$src" checkout -q FETCH_HEAD
fi
got=$(git -C "$src" rev-parse HEAD)
[ "$got" = "$MINGW_W64_VERSION" ] || { echo "mingw-w64 at $src is $got, not $MINGW_W64_VERSION" >&2; exit 1; }

build=$src/mingw-w64-crt/build-aarch64-arm64x
rm -rf "$build"
mkdir -p "$build"
export PATH="$LLVM_MINGW/bin:$PATH"
(
    cd "$build"
    ../configure --prefix="$sysroot" --host=aarch64-w64-mingw32 \
        --disable-lib32 --disable-lib64 --enable-libarm64 --enable-arm64x \
        --with-default-msvcrt=ucrt --enable-cfguard --enable-silent-rules
    make -j"$(nproc)"
    make install
)

builtin=$(find "$LLVM_MINGW" -name 'libclang_rt.builtins-aarch64.a' -type f -print -quit)
[ -n "$builtin" ] || { echo "libclang_rt.builtins-aarch64.a not in $LLVM_MINGW" >&2; exit 1; }
cp "$builtin" "$sysroot/lib/libgcc.a"
cp "$builtin" "$sysroot/lib/libgcc_eh.a"
cp "$builtin" "$sysroot/lib/libgcc_s.a"
test -f "$sysroot/lib/libgcc.a"
echo "arm64ec CRT installed in $sysroot"
