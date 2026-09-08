#!/bin/sh
#
# build-package.sh - produce a pre-patched STOR2RRD distribution tarball
#
# Copyright (C) 2026 STOR2RRD unlimited fork contributors
# Licensed under the GNU General Public License v3 or later.
#
# Takes an original XORUX distribution tarball and emits one with the
# unlimited edition module already applied, so the vendor's own install.sh
# and update.sh install the fork directly - no post-install step.
#
# Usage:
#   ./build-package.sh <stor2rrdX.YY.tar> [output-dir]
#
# Handles both package layouts:
#   7.x  dist_storage/ sits directly in the tarball
#   8.x  the payload is an inner stor2rrd.tar.Z (LZW), rebuilt as real .Z
#        so both uncompress(1) and gunzip(1) accept it

set -e

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$1
OUT=${2:-$PWD}

[ -n "$SRC" ] || { sed -n '3,18p' "$0"; exit 2; }
[ -f "$SRC" ] || { echo "build-package.sh: no such file: $SRC" >&2; exit 1; }

command -v python3 >/dev/null || { echo "build-package.sh: python3 is required" >&2; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT INT TERM

echo "Unpacking $SRC"
mkdir -p "$WORK/pkg"
tar -xf "$SRC" -C "$WORK/pkg"

PKGDIR=$(find "$WORK/pkg" -maxdepth 1 -mindepth 1 -type d | head -1)
[ -n "$PKGDIR" ] || { echo "build-package.sh: unexpected tarball layout" >&2; exit 1; }
PKGNAME=$(basename "$PKGDIR")
VERSION=$(cat "$PKGDIR/version.txt" 2>/dev/null | head -1 | tr -d ' \r')
[ -n "$VERSION" ] || VERSION=$PKGNAME
echo "  package: $PKGNAME (version $VERSION)"

# ------------------------------------------------------- locate the payload
INNER="$PKGDIR/stor2rrd.tar.Z"
if [ -f "$INNER" ]; then
  LAYOUT=8
  echo "Expanding inner payload (stor2rrd.tar.Z)"
  gzip -dc "$INNER" > "$WORK/inner.tar"
  mkdir -p "$WORK/inner"
  tar -xf "$WORK/inner.tar" -C "$WORK/inner"
  TREE="$WORK/inner/dist_storage"
elif [ -d "$PKGDIR/dist_storage" ]; then
  LAYOUT=7
  TREE="$PKGDIR/dist_storage"
else
  echo "build-package.sh: no dist_storage and no stor2rrd.tar.Z in $PKGNAME" >&2
  exit 1
fi
[ -d "$TREE" ] || { echo "build-package.sh: dist_storage missing from payload" >&2; exit 1; }
echo "  layout : ${LAYOUT}.x"

# -------------------------------------------------------------- apply the fork
echo "Applying the unlimited edition module"
"$SELF_DIR/apply.sh" --harden "$TREE" | sed 's/^/  /'

# the package IS the fork; per-file backups belong to in-place installs only
find "$TREE" -name '*.s2rfork-orig' -delete

# --------------------------------------------------- mark the modified version
# GPLv3 section 5(a): a modified version must carry prominent notices saying so.
cat > "$PKGDIR/FORK-NOTICE.txt" <<NOTICE
This is a MODIFIED version of STOR2RRD $VERSION.

It is not distributed by XORUX and is not supported by XORUX. Do not report
problems with this build to them.

Change from the version released by XORUX:

  The edition-selection module was replaced so that premium() returns a
  6-character string. The product gates every free-edition capacity limit on
  length( premium() ) == 6, so this build runs without those limits - device
  count, alert rules, custom group members, PDF export and SAN topology.
  The residual hardcoded literals behind those gates were additionally
  raised to 9999.

  ${LAYOUT}.x layout: $( [ "$LAYOUT" = 8 ] && echo "bin/XoruxEdition.pm replaced" || echo "bin/premium.pl added" )
  Also modified: bin/DeviceCfg.pm, bin/AlertStor2rrd.pm,
                 html/jquery/main.js, html/jquery/mainLib.js
  (only limit literals; a file is left untouched where nothing matched)

Features that lived only in XORUX's own Enterprise module are NOT restored by
this change and remain unimplemented - notably scheduled report generation.

STOR2RRD is distributed under the GNU General Public License v3; see
Copyright.txt. This modification is offered under the same licence and with
the same absence of warranty. "STOR2RRD" and "XORUX" are the marks of their
owner and are used here only to identify the software this build derives from.
NOTICE
echo "  wrote  : FORK-NOTICE.txt"

# ------------------------------------------------------------ repack payload
if [ "$LAYOUT" = 8 ]; then
  echo "Repacking inner payload"
  ( cd "$WORK/inner" && tar -cf "$WORK/inner-new.tar" dist_storage )
  python3 "$SELF_DIR/tools/lzw_compress.py" "$WORK/inner-new.tar" "$INNER"
  # prove the installer can read back what we just wrote
  gzip -dc "$INNER" > "$WORK/verify.tar"
  cmp "$WORK/verify.tar" "$WORK/inner-new.tar" || {
    echo "build-package.sh: inner .Z failed to round-trip" >&2; exit 1; }
  echo "  verified: stor2rrd.tar.Z decompresses byte-identical"
fi

# ------------------------------------------------------- regenerate files.sum
if [ -f "$PKGDIR/files.sum" ]; then
  echo "Regenerating files.sum"
  # build it outside the directory being listed, or it lists itself
  ( cd "$PKGDIR" && {
      head -1 files.sum
      for f in *; do
        [ -f "$f" ] && [ "$f" != files.sum ] && echo "$(sum "$f" | awk '{print $1}'):$f"
      done
    } > "$WORK/files.sum-new" )
  mv "$WORK/files.sum-new" "$PKGDIR/files.sum"
fi

# --------------------------------------------------------------- final tarball
mkdir -p "$OUT"
TARBALL="$OUT/${PKGNAME}-unlimited.tar"
( cd "$WORK/pkg" && tar -cf "$TARBALL" "$PKGNAME" )

echo
echo "Package: $TARBALL"
ls -la "$TARBALL" | awk '{printf "Size   : %.1f MB\n", $5/1048576}'
echo
echo "Install it exactly as the original:"
echo "  tar xf $(basename "$TARBALL")"
echo "  cd $PKGNAME && ./install.sh      # or ./update.sh to upgrade in place"
