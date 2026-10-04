#!/bin/sh
# Cross-compile the Linux release archives.
#
# CGO IS MANDATORY. The storage layer opens SQLite through
# gorm.io/driver/sqlite, which is built on mattn/go-sqlite3 -- a cgo binding.
# Compiled with CGO_ENABLED=0 that binding becomes a stub, and the panel dies
# on its very first start:
#
#     InitDB: Binary was compiled with 'CGO_ENABLED=0', go-sqlite3 requires
#     cgo to work. This is a stub
#
# The binary looks fine, is the right size, and produces no build error. So
# this script treats a C compiler for the target as a hard requirement and
# refuses (or skips, with instructions) rather than emitting that trap.
#
# The naive outbound is built with what build-tags.sh calls the "docker"
# profile: with_purego opens the cronet library at runtime instead of linking
# it, so the Chromium toolchain upstream's release job assembles is not needed
# here. Upstream uses the same profile for its own container image.
#
# Usage:
#   ./build-release.sh                       # every target whose compiler exists
#   ./build-release.sh linux/amd64           # selected targets
#   SUI_STATIC=1 ./build-release.sh          # add -static (musl / fully portable)
#   CC_arm64=aarch64-linux-musl-gcc ./build-release.sh linux/arm64
set -eu

cd "$(dirname "$0")"

PANEL_REPO="${PANEL_REPO:-Huzhao-1991/s-ui-mo}"
MODULE="github.com/alireza0/s-ui"
OUT="${OUT:-dist}"
VERSION="$(cat config/version 2>/dev/null || echo dev)"
VERSION="${VERSION%$'\n'}"

if [ ! -d web/html ] || [ -z "$(ls -A web/html 2>/dev/null)" ]; then
    echo "web/html is empty -- run: (cd frontend && npm install && npm run build) && rm -rf web/html/* && cp -r frontend/dist/* web/html/" >&2
    exit 1
fi

# shellcheck disable=SC1091
. ./build-tags.sh
TAGS=$(tags_for docker)
LDFLAGS="$(ldflags_for docker) -X ${MODULE}/config.PanelRepo=${PANEL_REPO}"

# The C compiler for one target. CC_<plat> wins, then a per-platform default.
# The defaults are the Debian/Ubuntu cross packages; install them with e.g.
#   apt-get install -y gcc-aarch64-linux-gnu gcc-arm-linux-gnueabihf
cc_for() {
    plat="$1"
    eval "override=\${CC_${plat}:-}"
    if [ -n "$override" ]; then
        echo "$override"
        return
    fi
    case "$plat" in
    amd64) echo "${CC_NATIVE:-gcc}" ;;
    arm64) echo "aarch64-linux-gnu-gcc" ;;
    armv7 | armv6) echo "arm-linux-gnueabihf-gcc" ;;
    386) echo "${CC_NATIVE:-gcc} -m32" ;;
    *) echo "" ;;
    esac
}

targets="${*:-linux/amd64 linux/arm64 linux/armv7 linux/armv6 linux/386 linux/s390x}"

rm -rf "$OUT"
mkdir -p "$OUT"

export GOFLAGS="${GOFLAGS:--mod=mod}"
export CGO_ENABLED=1

built=""
skipped=""

for t in $targets; do
    plat="${t#*/}"
    goarch="$plat"
    goarm=""
    case "$plat" in
    armv7) goarch=arm; goarm=7 ;;
    armv6) goarch=arm; goarm=6 ;;
    armv5) goarch=arm; goarm=5 ;;
    esac

    cc="$(cc_for "$plat")"
    ccbin="${cc%% *}"
    if [ -n "$ccbin" ] && ! command -v "$ccbin" >/dev/null 2>&1; then
        echo "=== linux/${plat}: skipped, no C compiler '${ccbin}' on PATH ==="
        skipped="${skipped} linux/${plat}"
        continue
    fi

    echo "=== linux/${plat}  (GOARCH=${goarch}${goarm:+ GOARM=$goarm}  CC=${cc:-none}) ==="

    stmp=".stage-${plat}"
    rm -rf "$stmp"
    mkdir -p "$stmp/s-ui"

    # Exported rather than prefixed onto the command line. A word produced by a
    # parameter expansion is never recognised as an assignment prefix, so the
    # earlier `${goarm:+GOARM="$goarm"}` form was parsed as a command named
    # "GOARM=7" and failed with "command not found" on every arm target.
    # GOARM is unset when unused so it cannot leak into a later platform.
    GOOS=linux GOARCH="$goarch"
    export GOOS GOARCH
    if [ -n "$goarm" ]; then
        GOARM="$goarm"
        export GOARM
    else
        unset GOARM
    fi
    if [ -n "$cc" ]; then
        CC="$cc"
        export CC
    fi

    build_ldflags="$LDFLAGS"
    if [ "${SUI_STATIC:-0}" = "1" ]; then
        # A fully static binary carries its own libc, which is what lets one
        # tarball run on any distribution instead of only on ones at least as
        # new as the build host.
        #
        # External link mode is mandatory: the internal linker silently ignores
        # -static and emits a dynamically linked executable anyway. The single
        # quotes are for Go's -ldflags parser, not for the shell -- the whole
        # string is handed to the compiler as one argument.
        #
        # Pair with a musl C compiler. Static glibc warns about getaddrinfo and
        # can only resolve hostnames through whatever NSS is compiled into
        # libc; musl has no such split.
        build_ldflags="$build_ldflags -linkmode external -extldflags '-static'"
    fi

    go build -trimpath -ldflags="$build_ldflags" -tags "$TAGS" -o "$stmp/s-ui/sui" main.go
    cp s-ui.service s-ui.sh "$stmp/s-ui/"
    chmod +x "$stmp/s-ui/sui" "$stmp/s-ui/s-ui.sh"
    tar -C "$stmp" -czf "$OUT/s-ui-linux-${plat}.tar.gz" s-ui
    # Tolerant on purpose: the archive is already written, so a staging
    # directory that refuses to go (a virus scanner holding the freshly built
    # executable, say) must not abort the rest of the matrix.
    rm -rf "$stmp" || true
    built="${built} linux/${plat}"
done

# Ship the one-click installer next to the archives. install.sh is not part of
# the upstream tarball (it is uploaded as a separate release asset), but this
# delivery is meant to be dropped onto a server as-is, so it travels with it.
cp install.sh "$OUT/install.sh"
chmod +x "$OUT/install.sh"

if [ -n "$(ls -A "$OUT" 2>/dev/null)" ]; then
    ( cd "$OUT" && sha256sum ./*.tar.gz > SHA256SUMS )
fi

echo
echo "built s-ui ${VERSION}:${built:- none}"
[ -n "$skipped" ] && echo "skipped (no compiler):${skipped}"
[ -n "$built" ] && ( cd "$OUT" && cat SHA256SUMS )
exit 0
