#!/usr/bin/bash
set -euo pipefail

# Resolve the log directory before entering any source tree.
logs=$(cd "$1" && pwd)
export LC_ALL=C
export PATH="/usr/gnu/bin:/usr/bin:/usr/sbin:$PATH"
export CC=gcc CXX=g++
export CFLAGS='-m64 -O2 -std=gnu17' CXXFLAGS='-m64 -O2'

{
    cat /etc/release
    uname -a
    isainfo -k
    "$CC" --version
    printf 'CDE checkout: %s\n' "$GITHUB_SHA"
} | tee "$logs/environment.log"

pkg_status=0
timeout 15m pkg install --no-backup-be --accept \
    developer/build/autoconf developer/build/automake \
    developer/build/gnu-make developer/build/libtool developer/build/pkg-config \
    developer/macro/gnu-m4 bison flex \
    image/library/libjpeg image/library/libpng16 \
    runtime/perl-538 runtime/tcl-8 shell/ksh93 \
    system/extended-system-utilities system/file-system/ufs system/header system/locale/en_us \
    text/gnu-sed text/locale web/curl \
    x11/data/xbitmaps x11/font-utilities x11/header/x11-protocols \
    x11/library/libx11 x11/library/libxau x11/library/libxdmcp \
    x11/library/libxext x11/library/libxft x11/library/libxinerama x11/library/libxmu \
    x11/library/libxpm x11/library/libxrender x11/library/toolkit/libxt \
    x11/session/sessreg x11/x11-server-utilities \
    2>&1 | tee "$logs/ips.log" || pkg_status=$?
case "$pkg_status" in
    0|4) ;;
    *) exit "$pkg_status" ;;
esac

# Build in guest-local storage so copyback only transfers source and diagnostics.
build_root=$(mktemp -d "${TMPDIR:-/var/tmp}/cde-ci.XXXXXX")
source_dir=$build_root/cde
deps=$build_root/deps
stage=$build_root/stage
cp -R cde "$source_dir"
mkdir -p "$deps/include" "$deps/lib"

trap 'if [[ -f "$source_dir/config.log" ]]; then cp "$source_dir/config.log" "$logs/config.log"; fi' EXIT

fetch_source() {
    local url=$1 hash=$2 archive=$3

    curl -fsSL --retry 3 --max-time 90 -o "$archive" "$url"
    if [[ "$(/usr/bin/digest -a sha256 "$archive")" != "$hash" ]]; then
        printf 'SHA-256 mismatch for %s\n' "$url" >&2
        return 1
    fi
    gzip -dc "$archive" | tar -xf -
}

(
    cd "$build_root"

    # The Solaris release publisher obsoleted OpenSP. CDE uses onsgmls for its help.
    fetch_source \
        https://deb.debian.org/debian/pool/main/o/opensp/opensp_1.5.2.orig.tar.gz \
        334c444c97590a000f20bcef7c1bec63d4e396bae6ba48b3ff49596443c467dd \
        opensp.tar.gz
    cd opensp-1.5.2
    CXXFLAGS="$CXXFLAGS -std=gnu++98" ./configure \
        --prefix="$deps" --disable-doc-build --disable-nls --disable-shared
    gmake -j4
    gmake install
) 2>&1 | tee "$logs/opensp.log"

(
    cd "$build_root"

    # LMDB is required by CDE and is absent from the Solaris release publisher.
    fetch_source \
        https://codeload.github.com/LMDB/lmdb/tar.gz/refs/tags/LMDB_0.9.33 \
        9c352fa9bdad53d920128ac6a62296f2850c7e29862a610d3a72f5f49a1cd7ea \
        lmdb.tar.gz
    cd lmdb-LMDB_0.9.33/libraries/liblmdb
    gmake -j4 XCFLAGS='-m64 -fPIC' liblmdb.a
    cp lmdb.h "$deps/include/"
    cp liblmdb.a "$deps/lib/"
) 2>&1 | tee "$logs/lmdb.log"

(
    cd "$build_root"

    # Use the upstream Open Motif 2.3.8 release.
    # This provides the Xme APIs and xm_* bitmap headers used by CDE.
    fetch_source \
        'https://downloads.sourceforge.net/project/motif/Motif%202.3.8%20Source%20Code/motif-2.3.8.tar.gz' \
        859b723666eeac7df018209d66045c9853b50b4218cecadb794e2359619ebce7 \
        motif.tar.gz
    cd motif-2.3.8
    # Motif passes a TabBox through the generic Xt Widget pointer type.
    CFLAGS="$CFLAGS -Wno-error=incompatible-pointer-types" \
        ./configure --prefix="$deps" --libdir="$deps/lib"
    for directory in bindings bitmaps config localized lib include tools; do
        gmake -C "$directory" -j4
        gmake -C "$directory" install
    done

    # Read Solaris declarations before Motif defines the legacy string macros.
    gmake -C clients/uil -j4 CPPFLAGS='-include strings.h'
    gmake -C clients/uil install CPPFLAGS='-include strings.h'
) 2>&1 | tee "$logs/motif.log"

export PATH="$deps/bin:$PATH"
export PKG_CONFIG_PATH="$deps/lib/pkgconfig"
# Libtool wrappers prepend the uninstalled CDE libraries to LD_LIBRARY_PATH.
unset LD_LIBRARY_PATH_64
export LD_LIBRARY_PATH="$deps/lib"
export CPPFLAGS="-I$deps/include"
export LDFLAGS="-L$deps/lib"

cd "$source_dir"
./autogen.sh 2>&1 | tee "$logs/cde-autogen.log"
./configure --prefix=/usr/dt --with-tcl=/usr/lib/amd64 2>&1 | tee "$logs/cde-configure.log"
gmake --keep-going -j4 2>&1 | tee "$logs/cde-make.log"
gmake install DESTDIR="$stage" 2>&1 | tee "$logs/cde-install.log"

{
    grep -F 'Motif Version 2.3.8"' "$deps/include/Xm/Xm.h"
    test -x "$deps/bin/uil"

    for program in dtwm dtlogin dtterm dtksh dtsearchpath rpc.cmsd; do
        target="$stage/usr/dt/bin/$program"
        test -x "$target"
        /usr/bin/file "$target" | grep -F 'ELF 64-bit'
    done
} | tee "$logs/staged-programs.log"
