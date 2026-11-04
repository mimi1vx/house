#!/bin/sh
# Seed the house-ghc-build volume (house-q0g.4 S1+S2 outputs) for CI.
# Idempotent: when the PIC archives + S2 objects are present with the
# census mk-house-image.sh asserts (285/241 members, 14 C objects),
# this exits 0 without rebuilding. On a cold cache miss it runs the
# S1 Hadrian source build (--flavour=quick) + S2 -fPIC recompile.
# Runs inside house-port:latest with house-ghc-build mounted at /ghc-build
# (plus house-cabal/house-cargo for `cabal update` persistence).
set -eu

PIC_ARCHIVES=${HOUSE_GHC_PIC:-/ghc-build/pic-archives}
S2_OBJS=${HOUSE_GHC_S2:-/ghc-build/s2/objs}
GHC_VERSION=9.14.1
SRC_ROOT=/ghc-build/ghc-$GHC_VERSION
TARBALL=/ghc-build/ghc-$GHC_VERSION-src.tar.xz
TARBALL_URL=https://downloads.haskell.org/ghc/$GHC_VERSION/ghc-$GHC_VERSION-src.tar.xz
TARBALL_SHA256=2a83779c9af86554a3289f2787a38d6aa83d00d136aa9f920361dd693c101e77

have_seed() {
	[ -f "$PIC_ARCHIVES/libHSghc-internal-pic.a" ] &&
		[ -f "$PIC_ARCHIVES/libHSbase-pic.a" ] &&
		[ "$(ar t "$PIC_ARCHIVES/libHSghc-internal-pic.a" 2>/dev/null | wc -l | tr -d ' ')" = 285 ] &&
		[ "$(ar t "$PIC_ARCHIVES/libHSbase-pic.a" 2>/dev/null | wc -l | tr -d ' ')" = 241 ] &&
		[ -n "$(ls "$S2_OBJS"/*.dyn_o 2>/dev/null)" ]
}

if have_seed; then
	echo "seed-ghc-build: seed present (285/241 + S2 objects), skipping rebuild"
	exit 0
fi

echo "seed-ghc-build: cold miss, provisioning S1+S2 (Hadrian quick ~11min, 4.9G)"
mkdir -p /ghc-build "$PIC_ARCHIVES" "$S2_OBJS"

if [ ! -f "$TARBALL" ]; then
	curl -sSfL "$TARBALL_URL" -o "$TARBALL"
fi
echo "$TARBALL_SHA256  $TARBALL" | sha256sum -c -

if [ ! -d "$SRC_ROOT" ]; then
	tar -xf "$TARBALL" -C /ghc-build
fi

# S1 volume-local patch (NOT in git): the pinned index predates boot
# GHC 9.14.1/base-4.22, so hashable rejects base>=4.22 without the bump.
sed -i 's/^index-state: .*/index-state: 2026-10-15T00:00:00Z/' "$SRC_ROOT/hadrian/cabal.project"
grep -q '^index-state: 2026-10-15T00:00:00Z$' "$SRC_ROOT/hadrian/cabal.project"

cabal update || true

cd "$SRC_ROOT"
./configure --prefix=/ghc-build/install >/ghc-build/configure.log 2>&1
./hadrian/build -j"$(nproc)" --flavour=quick >/ghc-build/build-quick.log 2>&1

INTERNAL_BUILD="$SRC_ROOT/_build/stage1/libraries/ghc-internal/build"
BASE_BUILD="$SRC_ROOT/_build/stage1/libraries/base/build"
find "$INTERNAL_BUILD" -name '*.dyn_o' | LC_ALL=C sort | tr '\n' ' ' | xargs ar rcs "$PIC_ARCHIVES/libHSghc-internal-pic.a"
find "$BASE_BUILD" -name '*.dyn_o' | LC_ALL=C sort | tr '\n' ' ' | xargs ar rcs "$PIC_ARCHIVES/libHSbase-pic.a"
[ "$(ar t "$PIC_ARCHIVES/libHSghc-internal-pic.a" | wc -l | tr -d ' ')" -eq 285 ]
[ "$(ar t "$PIC_ARCHIVES/libHSbase-pic.a" | wc -l | tr -d ' ')" -eq 241 ]

FILES="DarwinUtils PrelIOUtils SetEnv iconv inputReady md5 primFloat sysconf fs strerror debug Stack_c RtsIface gmp_wrappers"
INCS="-Irts/include -I_build/stage1/libraries/ghc-internal/build -I_build/stage1/libraries/ghc-internal/build/include -Ilibraries/ghc-internal/include -I_build/stage1/rts/build/include"
for f in $FILES; do
	# shellcheck disable=SC2086
	gcc -Wall -fPIC -DDYNAMIC -O2 $INCS -c "libraries/ghc-internal/cbits/$f.c" -o "$S2_OBJS/$f.dyn_o"
done
[ -n "$(ls "$S2_OBJS"/*.dyn_o 2>/dev/null)" ]

have_seed || {
	echo "seed-ghc-build: provisioning finished without a valid seed" >&2
	exit 1
}
echo "seed-ghc-build: provisioned (285/241 + S2 objects)"
