#!/bin/sh
#
# apply.sh - lift the free-edition caps in a XORUX product tree
#
# Copyright (C) 2026 XORUX unlimited fork contributors
# Licensed under the GNU General Public License v3 or later.
#
# Works on STOR2RRD and LPAR2RRD, both edition-module layouts:
#   7.x  bin/standard.pl        -> derive bin/premium.pl from it (additive)
#   8.x  bin/XoruxEdition.pm    -> rewrite it in place (backed up)
#
# The module is DERIVED from the one already installed - only the return
# value of premium() changes - so every other sub it exports survives. That
# matters: STOR2RRD's module exports premium() alone, LPAR2RRD's also exports
# get_rperf_all, rperf_check, lpm, get_lpar_num and lpm_find_files, and a
# future version may export more.
#
# LPAR2RRD additionally gates each platform on an empty marker file under
# html/ (its paths are hex-escaped in bin/HostCfg.pm). A platform is capped
# unless premium() is 6 chars AND its marker exists, and stock ships only
# some of them, so the missing ones are created here.
#
# Usage:
#   ./apply.sh [--harden] [--fix-vendor-bugs] [--fix-permissions] [--force]
#              [<PRODUCT_HOME>]
#   ./apply.sh --revert                                 [<PRODUCT_HOME>]
#   ./apply.sh --status                                 [<PRODUCT_HOME>]
#
#   --harden            also raise the residual hardcoded limit literals to
#                       9999. Not required - those branches are unreachable
#                       once the edition module is in place - belt and braces.
#   --fix-vendor-bugs   repair defects in the stock product that have nothing
#                       to do with the free/Enterprise split. Opt-in and kept
#                       separate so the fork's scope stays legible. See
#                       vendorfix_file() for what each one is.
#   --fix-permissions   make the tree group-readable so the web server user
#                       (which runs the CGI) can read it alongside the product
#                       user (which runs collection). Additive only; --revert
#                       does NOT undo it. A group membership change is a system
#                       change, so it is printed for you to run, never applied.
#   --force             overwrite an existing 7.x bin/premium.pl. Refused by
#                       default so a genuine Enterprise module is never
#                       clobbered.
#   --revert            undo everything this script did.
#   --status            report current state, change nothing.

set -e

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

LIMIT=9999
MARKER='XORUX unlimited fork'
EDITION_STRING=forked          # must be exactly 6 characters

HARDEN=0
VENDORFIX=0
FIXPERMS=0
FORCE=0
MODE=apply
HOME_ARG=""

for arg in "$@"; do
  case "$arg" in
    --harden) HARDEN=1 ;;
    --fix-vendor-bugs) VENDORFIX=1 ;;
    --fix-permissions) FIXPERMS=1 ;;
    --force)  FORCE=1 ;;
    --revert) MODE=revert ;;
    --status) MODE=status ;;
    -h|--help) sed -n '3,42p' "$0"; exit 0 ;;
    -*) echo "apply.sh: unknown option: $arg" >&2; exit 2 ;;
    *)  HOME_ARG="$arg" ;;
  esac
done

command -v perl >/dev/null || { echo "apply.sh: perl is required" >&2; exit 1; }

# ---------------------------------------------------------------- locate tree
S2R="$HOME_ARG"
[ -n "$S2R" ] || S2R="$XORUX_HOME"
[ -n "$S2R" ] || S2R="$STOR2RRD_HOME"
[ -n "$S2R" ] || S2R="$LPAR2RRD_HOME"
[ -n "$S2R" ] || for c in /home/stor2rrd/stor2rrd /home/lpar2rrd/lpar2rrd \
                          /opt/stor2rrd /opt/lpar2rrd \
                          /usr/local/stor2rrd /usr/local/lpar2rrd; do
  { [ -f "$c/bin/XoruxEdition.pm" ] || [ -f "$c/bin/standard.pl" ]; } && S2R="$c" && break
done

if [ -z "$S2R" ] || [ ! -d "$S2R" ]; then
  echo "apply.sh: product home not found. Pass it explicitly:" >&2
  echo "  $0 /home/lpar2rrd/lpar2rrd" >&2
  exit 1
fi

# ------------------------------------------------------------- detect layout
if [ -f "$S2R/bin/XoruxEdition.pm" ]; then
  LAYOUT=8
  STOCK="$S2R/bin/XoruxEdition.pm"
  EDITION="$S2R/bin/XoruxEdition.pm"
elif [ -f "$S2R/bin/standard.pl" ]; then
  LAYOUT=7
  STOCK="$S2R/bin/standard.pl"
  EDITION="$S2R/bin/premium.pl"
else
  echo "apply.sh: $S2R does not look like a XORUX product install" >&2
  echo "          (neither bin/XoruxEdition.pm nor bin/standard.pl found)" >&2
  exit 1
fi

if [ -f "$S2R/bin/HostCfg.pm" ]; then PRODUCT=LPAR2RRD; else PRODUCT=STOR2RRD; fi

HOSTCFG="$S2R/bin/HostCfg.pm"
DEVCFG="$S2R/bin/DeviceCfg.pm"
ALERTPM="$S2R/bin/AlertStor2rrd.pm"
MAINJS="$S2R/html/jquery/main.js"
LIBJS="$S2R/html/jquery/mainLib.js"
HARDEN_FILES="$HOSTCFG $DEVCFG $ALERTPM $MAINJS $LIBJS"

# files touched by --fix-vendor-bugs, kept apart from the cap removal
HOSTCFGPL="$S2R/bin/host_cfg.pl"
RESTAPIPL="$S2R/bin/hmc_rest_api.pl"
VENDORFIX_FILES="$HOSTCFGPL $RESTAPIPL"

MANIFEST="$S2R/.xoruxfork-created"

is_ours() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

edition_string() {
  if [ "$LAYOUT" = 8 ]; then
    perl -I"$S2R/bin" -MXoruxEdition -e 'print premium()' 2>/dev/null || echo "?"
  else
    ( cd "$S2R/bin" && perl -e 'if (-f "./premium.pl") { require "./premium.pl" } else { require "./standard.pl" } print premium()' 2>/dev/null ) || echo "?"
  fi
}

# ------------------------------------------------- platform marker files
# LPAR2RRD hex-escapes these paths in HostCfg.pm; decode them rather than
# hardcoding, so a version that adds a platform is picked up automatically.
marker_list() {
  [ -f "$HOSTCFG" ] || return 0
  perl -ne '
    while ( /basedir((?:\\x[0-9A-Fa-f]{2})+)/g ) {
      my $p = $1; $p =~ s/\\x([0-9A-Fa-f]{2})/chr(hex($1))/ge;
      print "$p\n" if $p =~ m{^/html/\.};
    }' "$HOSTCFG" | sort -u
}

# ------------------------------------------------------------------- hardening
harden_file() {
  f=$1
  [ -f "$f" ] || return 0
  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"
  perl -0777 -i -pe '
    my $n = '"$LIMIT"';
    # LPAR2RRD per-platform host cap in HostCfg::getHostConnections
    s/(\&\& \$cntr > )\d+/$1$n/g;
    # LPAR2RRD HostCfg::getUnlicensed - display only, but update.sh prints a
    # scary "excluded HMCs" warning from it, and it never consults premium()
    s/(\$platform eq "IBM Power Systems" \) \? )\d+/$1$n/g;
    s/(\$platform eq "VMware" \) \? )\d+/$1$n/g;
    # STOR2RRD 8.x device cap in DeviceCfg::getActiveDeviceList
    s/(\$counter\+\+;\s*\n\s*if \( \$counter <= )\d+/$1$n/g;
    # alert rule cap
    s/(!defined\s+\$devices\{\$storage\}\s*&&\s*\$index\s*<\s*)\d+/$1$n/g;
    # browser-side caps
    s/(sysInfo\.free\s*==\s*1\s*&&\s*\$alrttree\.getRootNode\(\)\.countChildren\(false\)\s*>=\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*devcnt\s*>=\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*activeDevices\s*>=\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*vals\.type\s*==\s*\\?"VOLUME\\?"\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*vals\.type\s*==\s*\\?"POOL\\?"\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*\/\[SL\]ANPORT\/\.test\(vals\.type\)\s*&&\s*count\s*>\s*)\d+/$1$n/g;
  ' "$f"
  if cmp -s "$f" "$f.xoruxfork-orig"; then
    rm -f "$f.xoruxfork-orig"      # nothing matched, keep the tree clean
  else
    echo "  hardened: ${f#$S2R/}"
  fi
}

# ------------------------------------------------------- vendor bug workarounds
# Strictly separate from the cap removal: these repair defects in the stock
# product that have nothing to do with the free/Enterprise split.
#
#   LPAR2RRD 8.08 - the admin menu in html/index.html links to
#   hosts.sh?cmd=form&platform=ibm, but "ibm" is not a key of %platforms in
#   bin/host_cfg.pl, so line 144 rewrites it to "" ("drop unknown platforms")
#   and the elsif that renders the HMC/CMC tabs is unreachable. The page comes
#   back with an empty host table and the New button does nothing.
perl_ok() {
  # host_cfg.pl pulls in the product's own modules and CPAN deps, so a bare
  # perl -c can fail for reasons that have nothing to do with our edit. Give
  # it the product's lib paths and compare before/after rather than demanding
  # an absolute pass.
  perl -I"$S2R/bin" -I"$S2R/lib" -c "$1" >/dev/null 2>&1
}

vendorfix_file() {
  case ${1##*/} in
    host_cfg.pl)     vendorfix_hostcfg "$1" ;;
    hmc_rest_api.pl) vendorfix_restapi "$1" ;;
  esac
}

# LPAR2RRD - one VIOS with a broken PhysicalVolume inventory makes the HMC
#   answer 500 for the whole ManagedSystem/<uuid>/VirtualIOServer collection,
#   so hmc_rest_api.pl gets nothing and every healthy VIOS on that server
#   loses its SEA, NPIV and VSCSI data too. Fall back to ?group=None plus one
#   call per VIOS. Needs SELF_DIR/patches/vios-collection-fallback.pl.
vendorfix_restapi() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork: VIOS collection fallback' "$f" && return 0   # already fixed
  grep -q 'my @LPs;' "$f" || return 0
  if [ ! -f "$SELF_DIR/patches/vios-collection-fallback.pl" ]; then
    echo "apply.sh: patches/vios-collection-fallback.pl missing, skipping $f" >&2
    return 0
  fi

  compiled_before=0
  perl_ok "$f" && compiled_before=1

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"

  PATCHBODY="$SELF_DIR/patches/vios-collection-fallback.pl" perl -0777 -i -pe '
    BEGIN { local $/; open my $fh, "<", $ENV{PATCHBODY} or die; $body = <$fh> }
    s{(\n)(  my \@LPs;\n)}{$1$body$2}
      or die "apply.sh: no VIOS collection block to patch\n";
  ' "$f" || { mv "$f.xoruxfork-orig" "$f"; return 1; }

  if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
    echo "apply.sh: $f compiled before the vendor fix and not after, restoring" >&2
    mv "$f.xoruxfork-orig" "$f"
    return 1
  fi
  echo "  fixed   : ${f#$S2R/} (a broken VIOS no longer blanks the healthy ones)"
}

vendorfix_hostcfg() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q '^  ibm  *=>' "$f" && return 0          # already fixed
  grep -q '^  power  *=> { longname => "IBM Power Systems"' "$f" || return 0

  compiled_before=0
  perl_ok "$f" && compiled_before=1

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"
  sed -i '/^  power  *=> { longname => "IBM Power Systems"/a\  ibm           => { longname => "IBM Power Systems" },' "$f"

  if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
    echo "apply.sh: $f compiled before the vendor fix and not after, restoring" >&2
    mv "$f.xoruxfork-orig" "$f"
    return 1
  fi
  echo "  fixed   : ${f#$S2R/} (platform=ibm now reaches the HMC/CMC tabs)"
}

# ------------------------------------------------------------ permissions
# Two different users touch this tree: the product user runs collection from
# cron, and the web server user runs the CGI. update.sh chowns the tree to
# whoever runs it and explicitly skips etc/web_config ("do not touch
# etc/web_config here!"), so a chown to the product user can leave the CGI
# unable to read hosts.json - which surfaces as "authorization failed" on
# every device, because the test gets no credentials to send.
web_user() {
  for u in apache httpd www-data nginx wwwrun; do
    id "$u" >/dev/null 2>&1 && echo "$u" && return 0
  done
  return 1
}

fix_permissions() {
  grp=$(ls -ld "$S2R" | awk '{print $4}')
  echo "  group of $S2R: $grp"

  chmod -R g+rX "$S2R"
  echo "  applied : chmod -R g+rX (group can read and traverse)"

  for d in etc/web_config tmp logs; do
    [ -d "$S2R/$d" ] && chmod g+w "$S2R/$d" && echo "  applied : chmod g+w $d"
  done

  # the CGI also has to traverse every directory above the tree to reach it
  d=$(dirname "$S2R")
  while [ "$d" != "/" ] && [ "$d" != "." ] && [ -n "$d" ]; do
    mode=$(ls -ld "$d" | awk '{print $1}')
    gx=$(echo "$mode" | cut -c7)    # group execute, s when setgid
    ox=$(echo "$mode" | cut -c10)   # other execute, t when sticky
    case "$gx$ox" in
      *x*|*s*|*t*) : ;;
      *) echo "  ACTION  : $d ($mode) is not traversable by group or other,"
         echo "            so the web server cannot reach the tree. Run as root:"
         echo "              chmod o+x $d" ;;
    esac
    d=$(dirname "$d")
  done

  wu=$(web_user) || {
    echo "  note    : no web server user found among apache/httpd/www-data/nginx/wwwrun"
    return 0
  }
  if id -nG "$wu" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
    echo "  ok      : $wu is already in group $grp"
  else
    echo "  ACTION  : $wu is NOT in group $grp. Run as root, then restart the web server:"
    echo "              usermod -aG $grp $wu"
    echo "            A group membership change is system-wide, outside this"
    echo "            product tree, so it is not applied automatically."
  fi
}

# ---------------------------------------------------------------------- status
report_status() {
  echo "product home  : $S2R"
  echo "product       : $PRODUCT, layout ${LAYOUT}.x (${EDITION#$S2R/})"
  if is_ours "$EDITION"; then
    echo "edition module: this fork"
  elif [ -f "$EDITION" ]; then
    echo "edition module: stock or vendor"
  else
    echo "edition module: absent (7.x free edition)"
  fi
  ed=$(edition_string)
  echo "premium()     : \"$ed\" (len ${#ed}) -> $([ ${#ed} -eq 6 ] && echo UNLIMITED || echo CAPPED)"
  ml=$(marker_list)
  if [ -n "$ml" ]; then
    for m in $ml; do
      printf "marker %-9s %s\n" "${m#/html/}" "$( [ -f "$S2R$m" ] && echo present || echo MISSING )"
    done
  fi
  for f in $HARDEN_FILES; do
    [ -f "$f.xoruxfork-orig" ] && echo "hardened      : ${f#$S2R/}"
  done
  for f in $VENDORFIX_FILES; do
    [ -f "$f.xoruxfork-orig" ] && echo "vendor fix    : ${f#$S2R/}"
  done
  exit 0
}

[ "$MODE" = status ] && report_status

# ---------------------------------------------------------------------- revert
if [ "$MODE" = revert ]; then
  echo "Reverting fork in $S2R ($PRODUCT, layout ${LAYOUT}.x)"
  if is_ours "$EDITION"; then
    if [ -f "$EDITION.xoruxfork-orig" ]; then
      mv "$EDITION.xoruxfork-orig" "$EDITION"
      echo "  restored: ${EDITION#$S2R/}"
    else
      rm -f "$EDITION"
      echo "  removed : ${EDITION#$S2R/}"
    fi
  elif [ -f "$EDITION" ]; then
    echo "  skipped : ${EDITION#$S2R/} is not this fork's file, left untouched"
  fi
  if [ -f "$MANIFEST" ]; then
    while read -r p; do
      [ -n "$p" ] && [ -f "$S2R$p" ] && rm -f "$S2R$p" && echo "  removed : $p"
    done < "$MANIFEST"
    rm -f "$MANIFEST"
  fi
  for f in $HARDEN_FILES $VENDORFIX_FILES; do
    [ -f "$f.xoruxfork-orig" ] && mv "$f.xoruxfork-orig" "$f" && echo "  restored: ${f#$S2R/}"
  done
  echo "Done. Restart the GUI / wait for the next collection cycle."
  exit 0
fi

# ----------------------------------------------------------------------- apply
if [ "$LAYOUT" = 7 ] && [ -f "$EDITION" ] && ! is_ours "$EDITION" && [ "$FORCE" -eq 0 ]; then
  echo "apply.sh: ${EDITION#$S2R/} already exists and was not created by this" >&2
  echo "          fork. It may be a genuine XORUX Enterprise module. Refusing" >&2
  echo "          to overwrite. Re-run with --force if you are sure." >&2
  exit 1
fi

echo "Lifting free-edition caps in $S2R ($PRODUCT, layout ${LAYOUT}.x)"

# keep exactly one pristine copy of whatever was there first
if [ -f "$EDITION" ] && ! is_ours "$EDITION" && [ ! -f "$EDITION.xoruxfork-orig" ]; then
  cp -p "$EDITION" "$EDITION.xoruxfork-orig"
  echo "  backed up: ${EDITION#$S2R/}.xoruxfork-orig"
fi

# derive the fork's module from the stock one: change only premium()'s value
SRC="$STOCK"
[ -f "$EDITION.xoruxfork-orig" ] && SRC="$EDITION.xoruxfork-orig"
perl -0777 -pe '
  my $s = "'"$EDITION_STRING"'";
  s/(sub\s+premium\s*\{\s*return\s+)"[^"]*"/$1"$s"/
    or die "apply.sh: no premium() definition to rewrite\n";
  s{\A}{"# Modified by the '"$MARKER"': premium() returns a 6-character\n"
       . "# string, which is what every free-edition cap in this product tests.\n"
       . "# Licensed under the GNU General Public License v3 or later.\n\n"}e;
' "$SRC" > "$EDITION.xoruxfork-tmp"
mv "$EDITION.xoruxfork-tmp" "$EDITION"

chmod --reference="$STOCK" "$EDITION" 2>/dev/null || chmod 644 "$EDITION"
chown --reference="$STOCK" "$EDITION" 2>/dev/null || true
echo "  installed: ${EDITION#$S2R/} (derived from ${STOCK#$S2R/})"

if ! perl -c "$EDITION" >/dev/null 2>&1; then
  echo "apply.sh: rewritten edition module fails perl -c, reverting" >&2
  if [ -f "$EDITION.xoruxfork-orig" ]; then mv "$EDITION.xoruxfork-orig" "$EDITION"; else rm -f "$EDITION"; fi
  exit 1
fi

ed=$(edition_string)
if [ ${#ed} -ne 6 ]; then
  echo "apply.sh: premium() returned \"$ed\" (len ${#ed}), expected 6 chars. Reverting." >&2
  if [ -f "$EDITION.xoruxfork-orig" ]; then mv "$EDITION.xoruxfork-orig" "$EDITION"; else rm -f "$EDITION"; fi
  exit 1
fi

# LPAR2RRD: a platform stays capped unless its marker file exists as well
for m in $(marker_list); do
  if [ ! -f "$S2R$m" ]; then
    mkdir -p "$(dirname "$S2R$m")"
    : > "$S2R$m"
    chmod --reference="$STOCK" "$S2R$m" 2>/dev/null || chmod 644 "$S2R$m"
    chown --reference="$STOCK" "$S2R$m" 2>/dev/null || true
    echo "$m" >> "$MANIFEST"
    echo "  created  : $m"
  fi
done

if [ "$HARDEN" -eq 1 ]; then
  echo "Raising residual hardcoded limits to $LIMIT"
  for f in $HARDEN_FILES; do harden_file "$f"; done
fi

if [ "$VENDORFIX" -eq 1 ]; then
  echo "Applying vendor bug workarounds"
  for f in $VENDORFIX_FILES; do vendorfix_file "$f"; done
fi

if [ "$FIXPERMS" -eq 1 ]; then
  echo "Opening group access so the web server user can read the tree"
  fix_permissions
fi

# force the GUI to rebuild menu.txt so the edition flag flips to full
rm -f "$S2R/tmp/menu.txt" "$S2R/tmp/menu.txt-tmp" 2>/dev/null || true

echo
report_status
