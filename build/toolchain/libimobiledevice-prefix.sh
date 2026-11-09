#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# The libimobiledevice stack xtool 1.20.1's Dockerfile builds before
# `swift build` (xtool-org/xtool Dockerfile, tag 1.20.1). Ubuntu's packaged
# libraries do not ship the headers xtool-core's C modules include
# (libimobiledevice/afc.h and the rest).
#
# Same order, configure flags and apt packages as that Dockerfile.
# --prefix is this prefix instead of /usr, so a CI job can cache it and
# pkg-config/ldconfig can point at it. The Dockerfile's libimobiledevice
# pin is the git ref "master"; at the 1.20.1 tag (916cdff, 2026-09-21)
# that ref is fa0f79190142bc309307967c058f89c1b36eb6b8.
#
#   build/toolchain/libimobiledevice-prefix.sh [PREFIX]
# PREFIX defaults to $PLAYPORT_BUILD/inputs/limd. Writes PREFIX/env.sh.

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
export PLAYPORT_BUILD=${PLAYPORT_BUILD:-$ROOT/.work}
PREFIX=${1:-$PLAYPORT_BUILD/inputs/limd}
SRC=$PLAYPORT_BUILD/cache/limd-src

LIBPLIST_REF=2.6.0
GLUE_REF=1.3.1
USBMUXD_REF=2.1.0
TATSU_REF=1.0.4
LIMD_REF=fa0f79190142bc309307967c058f89c1b36eb6b8

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq
sudo apt-get install -y -qq \
    ca-certificates build-essential checkinstall git \
    autoconf automake libtool-bin libssl-dev pkg-config \
    libxml2 curl libcurl4-openssl-dev \
    zip unzip liblzma-dev zlib1g-dev

mkdir -p "$PREFIX" "$SRC"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
export C_INCLUDE_PATH="$PREFIX/include${C_INCLUDE_PATH:+:$C_INCLUDE_PATH}"
export LIBRARY_PATH="$PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# xtool-core 1.5.0's openssl module still includes openssl/rand_drbg.h.
# OpenSSL 3 removed that header. Nothing in the module calls RAND_DRBG;
# the header only has to be present for the module to parse.
mkdir -p "$PREFIX/include/openssl"
cat > "$PREFIX/include/openssl/rand_drbg.h" << 'EOF'
#ifndef PLAYPORT_OPENSSL_RAND_DRBG_H
#define PLAYPORT_OPENSSL_RAND_DRBG_H
#endif
EOF

stamp=$PREFIX/stamp
want=$(printf '%s\n' \
    "libplist $LIBPLIST_REF" \
    "libimobiledevice-glue $GLUE_REF" \
    "libusbmuxd $USBMUXD_REF" \
    "libtatsu $TATSU_REF" \
    "libimobiledevice $LIMD_REF")

checkout() {
    local name=$1 url=$2 ref=$3
    local dir=$SRC/$name
    if [ ! -d "$dir/.git" ]; then
        git clone --quiet "$url" "$dir"
    fi
    git -C "$dir" fetch --quiet --tags origin
    git -C "$dir" checkout --quiet --force "$ref"
}

build_one() {
    local name=$1
    shift
    echo "limd: building $name"
    (
        cd "$SRC/$name"
        ./autogen.sh "$@"
        make -j"$(nproc)"
        make install
    )
}

if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ] \
    && pkg-config --exists libplist-2.0 libimobiledevice-glue-1.0 libusbmuxd-2.0 libtatsu-1.0 libimobiledevice-1.0; then
    echo "limd prefix ready $PREFIX"
else
    checkout libplist https://github.com/libimobiledevice/libplist.git "$LIBPLIST_REF"
    build_one libplist --prefix "$PREFIX" --without-cython

    checkout libimobiledevice-glue https://github.com/libimobiledevice/libimobiledevice-glue.git "$GLUE_REF"
    build_one libimobiledevice-glue --prefix "$PREFIX"

    checkout libusbmuxd https://github.com/libimobiledevice/libusbmuxd.git "$USBMUXD_REF"
    build_one libusbmuxd --prefix "$PREFIX"

    checkout libtatsu https://github.com/libimobiledevice/libtatsu.git "$TATSU_REF"
    build_one libtatsu --prefix "$PREFIX"

    checkout libimobiledevice https://github.com/libimobiledevice/libimobiledevice.git "$LIMD_REF"
    build_one libimobiledevice --prefix "$PREFIX" --without-cython

    printf '%s\n' "$want" > "$stamp"
fi

# Every header xtool-core's system modules include, plus libtatsu, which
# libimobiledevice's own headers include.
headers=(
    libimobiledevice/afc.h
    libimobiledevice/debugserver.h
    libimobiledevice/diagnostics_relay.h
    libimobiledevice/file_relay.h
    libimobiledevice/heartbeat.h
    libimobiledevice/house_arrest.h
    libimobiledevice/installation_proxy.h
    libimobiledevice/libimobiledevice.h
    libimobiledevice/lockdown.h
    libimobiledevice/misagent.h
    libimobiledevice/mobile_image_mounter.h
    libimobiledevice/mobileactivation.h
    libimobiledevice/mobilebackup.h
    libimobiledevice/mobilebackup2.h
    libimobiledevice/mobilesync.h
    libimobiledevice/notification_proxy.h
    libimobiledevice/preboard.h
    libimobiledevice/property_list_service.h
    libimobiledevice/restore.h
    libimobiledevice/sbservices.h
    libimobiledevice/screenshotr.h
    libimobiledevice/service.h
    libimobiledevice/syslog_relay.h
    libimobiledevice/webinspector.h
    plist/plist.h
    usbmuxd.h
    libimobiledevice-glue/glue.h
    libtatsu/tatsu.h
    openssl/rand_drbg.h
)
for h in "${headers[@]}"; do
    if [ ! -f "$PREFIX/include/$h" ] && [ ! -f "/usr/include/$h" ] && [ ! -f "/usr/include/x86_64-linux-gnu/$h" ]; then
        echo "limd: missing header $h" >&2
        exit 1
    fi
done

modc=$SRC/xtool-modules.c
cat > "$modc" << 'EOF'
#include <libimobiledevice/afc.h>
#include <libimobiledevice/debugserver.h>
#include <libimobiledevice/diagnostics_relay.h>
#include <libimobiledevice/file_relay.h>
#include <libimobiledevice/heartbeat.h>
#include <libimobiledevice/house_arrest.h>
#include <libimobiledevice/installation_proxy.h>
#include <libimobiledevice/libimobiledevice.h>
#include <libimobiledevice/lockdown.h>
#include <libimobiledevice/misagent.h>
#include <libimobiledevice/mobile_image_mounter.h>
#include <libimobiledevice/mobileactivation.h>
#include <libimobiledevice/mobilebackup.h>
#include <libimobiledevice/mobilebackup2.h>
#include <libimobiledevice/mobilesync.h>
#include <libimobiledevice/notification_proxy.h>
#include <libimobiledevice/preboard.h>
#include <libimobiledevice/property_list_service.h>
#include <libimobiledevice/restore.h>
#include <libimobiledevice/sbservices.h>
#include <libimobiledevice/screenshotr.h>
#include <libimobiledevice/service.h>
#include <libimobiledevice/syslog_relay.h>
#include <libimobiledevice/webinspector.h>
#include <plist/plist.h>
#include <usbmuxd.h>
#include <openssl/ssl.h>
#include <openssl/rand_drbg.h>
EOF
# shellcheck disable=SC2046
clang -fsyntax-only -x c $(pkg-config --cflags libimobiledevice-1.0 libplist-2.0 libusbmuxd-2.0 libimobiledevice-glue-1.0 openssl) "$modc"

echo "$PREFIX/lib" | sudo tee /etc/ld.so.conf.d/playport-limd.conf >/dev/null
sudo ldconfig

cat > "$PREFIX/env.sh" << EOF
# Generated by build/toolchain/libimobiledevice-prefix.sh. Source before swift build.
if [ "\${LIMD_ENV_READY:-}" != 1 ]; then
    export LIMD_ENV_READY=1
    export LIMD_PREFIX='$PREFIX'
    export PKG_CONFIG_PATH='$PREFIX/lib/pkgconfig'\${PKG_CONFIG_PATH:+:\$PKG_CONFIG_PATH}
    export C_INCLUDE_PATH='$PREFIX/include'\${C_INCLUDE_PATH:+:\$C_INCLUDE_PATH}
    export LIBRARY_PATH='$PREFIX/lib'\${LIBRARY_PATH:+:\$LIBRARY_PATH}
    export LD_LIBRARY_PATH='$PREFIX/lib'\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
fi
EOF
echo "limd prefix $PREFIX"
