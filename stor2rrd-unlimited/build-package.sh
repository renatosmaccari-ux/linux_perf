#!/bin/sh
#
# build-package.sh - produce a pre-patched XORUX distribution tarball
#
# Copyright (C) 2026 XORUX unlimited fork contributors
# Licensed under the GNU General Public License v3 or later.
#
# Takes an original XORUX distribution tarball and emits one with the
# unlimited edition module already applied, so the vendor's own install.sh
# and update.sh install the fork directly - no post-install step.
#
# Usage:
#   ./build-package.sh <stor2rrdX.YY.tar|lpar2rrdX.YY.tar> [output-dir]
#
# Handles both products and both package layouts:
#   7.x  the payload directory sits directly in the tarball
#   8.x  the payload is an inner <product>.tar.Z (LZW), rebuilt as a real .Z
#        so both uncompress(1) and gunzip(1) accept it
# The payload directory is dist_storage for STOR2RRD and dist for LPAR2RRD.

set -e

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SRC=$1
OUT=${2:-$PWD}

[ -n "$SRC" ] || { sed -n '3,19p' "$0"; exit 2; }
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
# 8.x wraps the tree in an inner <product>.tar.Z; 7.x ships it directly.
# The payload directory is dist_storage for STOR2RRD and dist for LPAR2RRD.
find_tree() {
  for d in "$1"/dist_storage "$1"/dist; do
    [ -d "$d" ] && echo "$d" && return 0
  done
  return 1
}

INNER=$(find "$PKGDIR" -maxdepth 1 -name '*.tar.Z' ! -name 'perl_aix_ssl.tar.Z' | head -1)
if [ -n "$INNER" ]; then
  LAYOUT=8
  echo "Expanding inner payload ($(basename "$INNER"))"
  gzip -dc "$INNER" > "$WORK/inner.tar"
  mkdir -p "$WORK/inner"
  tar -xf "$WORK/inner.tar" -C "$WORK/inner"
  TREE=$(find_tree "$WORK/inner") || {
    echo "build-package.sh: no dist/ or dist_storage/ inside $(basename "$INNER")" >&2; exit 1; }
elif TREE=$(find_tree "$PKGDIR"); then
  LAYOUT=7
else
  echo "build-package.sh: no dist/, dist_storage/ or inner .tar.Z in $PKGNAME" >&2
  exit 1
fi
echo "  layout : ${LAYOUT}.x, payload $(basename "$TREE")/"

# -------------------------------------------------------------- apply the fork
echo "Applying the unlimited edition module"
"$SELF_DIR/apply.sh" --harden --fix-vendor-bugs "$TREE" | sed 's/^/  /'

# the package IS the fork; per-file backups and the revert manifest belong to
# in-place installs only
find "$TREE" -name '*.xoruxfork-orig' -delete
rm -f "$TREE/.xoruxfork-created"

# The product user runs collection from cron and the web server user runs the
# CGI, so both need to read the tree. Ship it group-readable; the installer's
# `cp -R` masks the source mode with the calling umask, so this only holds if
# install.sh/update.sh run under a umask that leaves group bits alone (022).
chmod -R g+rX "$TREE"
[ -d "$TREE/etc/web_config" ] && chmod g+w "$TREE/etc/web_config"
echo "  perms  : payload made group-readable (etc/web_config group-writable)"

# --------------------------------------------------- mark the modified version
# GPLv3 section 5(a): a modified version must carry prominent notices saying so.
PRODUCT=$(echo "$PKGNAME" | sed 's/-.*//' | tr 'a-z' 'A-Z')
cat > "$PKGDIR/FORK-NOTICE.txt" <<NOTICE
This is a MODIFIED version of $PRODUCT $VERSION.

It is not distributed by XORUX and is not supported by XORUX. Do not report
problems with this build to them.

Changes from the version released by XORUX:

  The edition-selection module was rewritten so that premium() returns a
  6-character string. The product gates every free-edition limit on
  length( premium() ) == 6, so this build runs without them - monitored
  device or host count, alert rules, custom group members, PDF export and
  SAN topology. Only that return value changed; every other subroutine the
  module exports was carried over unaltered.

  ${LAYOUT}.x layout: $( [ "$LAYOUT" = 8 ] && echo "bin/XoruxEdition.pm rewritten" || echo "bin/premium.pl added, derived from bin/standard.pl" )

  On LPAR2RRD each platform is gated a second time on an empty marker file
  under html/ (.p Power and CMC, .v VMware, .o RHV, .n Nutanix, .t
  Openshift). A platform stays capped unless premium() is 6 characters AND
  its marker exists, and stock ships only .p and .v, so the missing markers
  were created.

  The residual hardcoded limit literals behind those gates were additionally
  raised to 9999, in whichever of these files the product has:
  bin/HostCfg.pm, bin/DeviceCfg.pm, bin/AlertStor2rrd.pm,
  html/jquery/main.js, html/jquery/mainLib.js.
  A file is left untouched where nothing matched.

Separately, and unrelated to the free/Enterprise split, this build carries a
workaround for a defect in the stock product:

  LPAR2RRD 8.08 - html/index.html links the admin menu to
  hosts.sh?cmd=form&platform=ibm, but "ibm" is not a key of %platforms in
  bin/host_cfg.pl, so that file rewrites it to "" ("drop unknown platforms")
  and the branch rendering the HMC/CMC tabs never runs: the page returns an
  empty host table and the New button does nothing. "ibm" was added as a
  key so that branch is reachable. bin/host_cfg.pl is modified only on
  products that have it.

File modes in this payload were opened to the group (g+rX, and g+w on
etc/web_config) because two users share the tree: the product user, which runs
collection from cron, and the web server user, which runs the CGI. update.sh
chowns the tree to whoever runs it but deliberately skips etc/web_config, so
after a plain chown to the product user the CGI can no longer read hosts.json
and every device test reports "authorization failed".

  Install or update with a umask of 022. The installer copies with cp -R,
  which masks the source mode with the calling umask, so a umask of 027 or 077
  strips these bits back off.

  One step no tarball can carry, because it is a system change outside the
  product tree - run it as root once, then restart the web server:

      usermod -aG <product group> <web server user>
      # e.g. usermod -aG stor2rrd apache && systemctl restart httpd

  apply.sh --fix-permissions reports both, and repairs an existing
  installation in place.

Features that lived only in XORUX's own Enterprise module are NOT restored by
this change and remain unimplemented - notably scheduled report generation.

$PRODUCT is distributed under the GNU General Public License v3; see
Copyright.txt. This modification is offered under the same licence and with
the same absence of warranty. "$PRODUCT" and "XORUX" are the marks of their
owner and are used here only to identify the software this build derives from.
NOTICE
echo "  wrote  : FORK-NOTICE.txt"

# ------------------------------------------------------------ repack payload
if [ "$LAYOUT" = 8 ]; then
  echo "Repacking inner payload"
  ( cd "$WORK/inner" && tar -cf "$WORK/inner-new.tar" "$(basename "$TREE")" )
  python3 "$SELF_DIR/tools/lzw_compress.py" "$WORK/inner-new.tar" "$INNER"
  # prove the installer can read back what we just wrote
  gzip -dc "$INNER" > "$WORK/verify.tar"
  cmp "$WORK/verify.tar" "$WORK/inner-new.tar" || {
    echo "build-package.sh: inner .Z failed to round-trip" >&2; exit 1; }
  echo "  verified: $(basename "$INNER") decompresses byte-identical"
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

# ------------------------------------------------------- name it a full edition
# scripts/update.sh decides the edition from the DIRECTORY NAME, not from the
# code: `echo $pwd | egrep -- "-full|-trial-"` sets free_edition_new, and a
# second pattern (lpar2rrd-<ver>-full) suppresses the "excluded HMCs" warning.
# Under a plain name the installer treats this as the free edition, deletes the
# Enterprise-only files and prints that warning even though the caps are gone.
case "$PKGNAME" in
  *-full*|*-trial-*) OUTNAME=$PKGNAME ;;
  *)                 OUTNAME="${PKGNAME}-full-unlimited" ;;
esac
if [ "$OUTNAME" != "$PKGNAME" ]; then
  mv "$WORK/pkg/$PKGNAME" "$WORK/pkg/$OUTNAME"
  echo "Naming the package directory $OUTNAME so the installer treats it as full"
fi

# --------------------------------------------------------------- final tarball
mkdir -p "$OUT"
TARBALL="$OUT/${OUTNAME}.tar"
( cd "$WORK/pkg" && tar -cf "$TARBALL" "$OUTNAME" )

echo
echo "Package: $TARBALL"
ls -la "$TARBALL" | awk '{printf "Size   : %.1f MB\n", $5/1048576}'
echo
echo "Install it exactly as the original:"
echo "  tar xf $(basename "$TARBALL")"
echo "  cd $OUTNAME && ./update.sh       # or ./install.sh for a fresh install"
