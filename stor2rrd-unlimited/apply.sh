#!/bin/sh
#
# apply.sh - install the unlimited edition module into a STOR2RRD tree
#
# Copyright (C) 2026 STOR2RRD unlimited fork contributors
# Licensed under the GNU General Public License v3 or later.
#
# Supports both edition-module layouts:
#   7.x  bin/standard.pl + optional bin/premium.pl  -> install premium.pl (additive)
#   8.x  bin/XoruxEdition.pm                        -> replace it (backed up)
#
# Usage:
#   ./apply.sh [--harden] [--force] [<STOR2RRD_HOME>]
#   ./apply.sh --revert            [<STOR2RRD_HOME>]
#   ./apply.sh --status            [<STOR2RRD_HOME>]
#
#   --harden   also raise the residual hardcoded free-edition literals to
#              9999. Not required (they are unreachable once the edition
#              module is in place) - belt and braces only.
#   --force    overwrite an existing 7.x bin/premium.pl. Refused by default
#              so a genuine XORUX Enterprise module is never clobbered.
#   --revert   undo everything this script did.
#   --status   report current state, change nothing.

set -e

SELF_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LIMIT=9999
MARKER='STOR2RRD unlimited fork'

HARDEN=0
FORCE=0
MODE=apply
HOME_ARG=""

for arg in "$@"; do
  case "$arg" in
    --harden) HARDEN=1 ;;
    --force)  FORCE=1 ;;
    --revert) MODE=revert ;;
    --status) MODE=status ;;
    -h|--help) sed -n '3,26p' "$0"; exit 0 ;;
    -*) echo "apply.sh: unknown option: $arg" >&2; exit 2 ;;
    *)  HOME_ARG="$arg" ;;
  esac
done

# ---------------------------------------------------------------- locate tree
S2R="$HOME_ARG"
[ -n "$S2R" ] || S2R="$STOR2RRD_HOME"
[ -n "$S2R" ] || for c in /home/stor2rrd/stor2rrd /opt/stor2rrd /usr/local/stor2rrd; do
  { [ -f "$c/bin/XoruxEdition.pm" ] || [ -f "$c/bin/standard.pl" ]; } && S2R="$c" && break
done

if [ -z "$S2R" ] || [ ! -d "$S2R" ]; then
  echo "apply.sh: STOR2RRD home not found. Pass it explicitly:" >&2
  echo "  $0 /home/stor2rrd/stor2rrd" >&2
  exit 1
fi

# ------------------------------------------------------------- detect layout
if [ -f "$S2R/bin/XoruxEdition.pm" ]; then
  LAYOUT=8
  EDITION="$S2R/bin/XoruxEdition.pm"
  SOURCE="$SELF_DIR/XoruxEdition.pm"
elif [ -f "$S2R/bin/standard.pl" ]; then
  LAYOUT=7
  EDITION="$S2R/bin/premium.pl"
  SOURCE="$SELF_DIR/premium.pl"
else
  echo "apply.sh: $S2R does not look like a STOR2RRD install" >&2
  echo "          (neither bin/XoruxEdition.pm nor bin/standard.pl found)" >&2
  exit 1
fi

DEVCFG="$S2R/bin/DeviceCfg.pm"
ALERTPM="$S2R/bin/AlertStor2rrd.pm"
MAINJS="$S2R/html/jquery/main.js"
LIBJS="$S2R/html/jquery/mainLib.js"
HARDEN_FILES="$DEVCFG $ALERTPM $MAINJS $LIBJS"

is_ours() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

edition_string() {
  if [ "$LAYOUT" = 8 ]; then
    perl -I"$S2R/bin" -MXoruxEdition -e 'print premium()' 2>/dev/null || echo "?"
  else
    ( cd "$S2R/bin" && perl -e 'if (-f "./premium.pl") { require "./premium.pl" } else { require "./standard.pl" } print premium()' 2>/dev/null ) || echo "?"
  fi
}

# ------------------------------------------------------------------- hardening
harden_file() {
  f=$1
  [ -f "$f" ] || return 0
  [ -f "$f.s2rfork-orig" ] || cp -p "$f" "$f.s2rfork-orig"
  perl -0777 -i -pe '
    my $n = '"$LIMIT"';
    # 8.x device cap: DeviceCfg::getActiveDeviceList splits goon/byebye
    s/(\$counter\+\+;\s*\n\s*if \( \$counter <= )\d+/$1$n/g;
    # alert rule cap (7.x and 8.x)
    s/(!defined\s+\$devices\{\$storage\}\s*&&\s*\$index\s*<\s*)\d+/$1$n/g;
    # browser-side caps (7.x and 8.x)
    s/(sysInfo\.free\s*==\s*1\s*&&\s*\$alrttree\.getRootNode\(\)\.countChildren\(false\)\s*>=\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*devcnt\s*>=\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*activeDevices\s*>=\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*vals\.type\s*==\s*\\?"VOLUME\\?"\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*vals\.type\s*==\s*\\?"POOL\\?"\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*\/\[SL\]ANPORT\/\.test\(vals\.type\)\s*&&\s*count\s*>\s*)\d+/$1$n/g;
  ' "$f"
  if cmp -s "$f" "$f.s2rfork-orig"; then
    rm -f "$f.s2rfork-orig"      # nothing matched, keep the tree clean
  else
    echo "  hardened: $f"
  fi
}

unharden_file() {
  f=$1
  if [ -f "$f.s2rfork-orig" ]; then
    mv "$f.s2rfork-orig" "$f"
    echo "  restored: $f"
  fi
}

# ---------------------------------------------------------------------- status
report_status() {
  echo "STOR2RRD home : $S2R"
  echo "layout        : ${LAYOUT}.x  (edition module: ${EDITION#$S2R/})"
  if is_ours "$EDITION"; then
    echo "edition module: this fork"
  elif [ -f "$EDITION" ]; then
    echo "edition module: stock or vendor"
  else
    echo "edition module: absent (7.x free edition)"
  fi
  ed=$(edition_string)
  echo "premium()     : \"$ed\" (len ${#ed}) -> $([ ${#ed} -eq 6 ] && echo UNLIMITED || echo CAPPED)"
  for f in $HARDEN_FILES; do
    [ -f "$f.s2rfork-orig" ] && echo "hardened      : ${f#$S2R/}"
  done
  exit 0
}

[ "$MODE" = status ] && report_status

# ---------------------------------------------------------------------- revert
if [ "$MODE" = revert ]; then
  echo "Reverting fork in $S2R (layout ${LAYOUT}.x)"
  if is_ours "$EDITION"; then
    if [ -f "$EDITION.s2rfork-orig" ]; then
      mv "$EDITION.s2rfork-orig" "$EDITION"
      echo "  restored: $EDITION"
    else
      rm -f "$EDITION"
      echo "  removed : $EDITION"
    fi
  elif [ -f "$EDITION" ]; then
    echo "  skipped : $EDITION is not this fork's file, left untouched"
  fi
  for f in $HARDEN_FILES; do unharden_file "$f"; done
  echo "Done. Restart the GUI / wait for the next collection cycle."
  exit 0
fi

# ----------------------------------------------------------------------- apply
if [ "$LAYOUT" = 7 ] && [ -f "$EDITION" ] && ! is_ours "$EDITION" && [ "$FORCE" -eq 0 ]; then
  echo "apply.sh: $EDITION already exists and was not created by this fork." >&2
  echo "          It may be a genuine XORUX Enterprise module. Refusing to" >&2
  echo "          overwrite. Re-run with --force if you are sure." >&2
  exit 1
fi

echo "Installing unlimited edition module into $S2R (layout ${LAYOUT}.x)"

# keep exactly one pristine copy of whatever was there first
if [ -f "$EDITION" ] && ! is_ours "$EDITION" && [ ! -f "$EDITION.s2rfork-orig" ]; then
  cp -p "$EDITION" "$EDITION.s2rfork-orig"
  echo "  backed up: $EDITION.s2rfork-orig"
fi

cp "$SOURCE" "$EDITION"

REF="$S2R/bin/DeviceCfg.pm"
chmod --reference="$REF" "$EDITION" 2>/dev/null || chmod 644 "$EDITION"
chown --reference="$REF" "$EDITION" 2>/dev/null || true
echo "  installed: $EDITION"

if ! perl -c "$EDITION" >/dev/null 2>&1; then
  echo "apply.sh: installed edition module fails perl -c, reverting" >&2
  if [ -f "$EDITION.s2rfork-orig" ]; then mv "$EDITION.s2rfork-orig" "$EDITION"; else rm -f "$EDITION"; fi
  exit 1
fi

ed=$(edition_string)
if [ ${#ed} -ne 6 ]; then
  echo "apply.sh: premium() returned \"$ed\" (len ${#ed}), expected 6 chars. Reverting." >&2
  if [ -f "$EDITION.s2rfork-orig" ]; then mv "$EDITION.s2rfork-orig" "$EDITION"; else rm -f "$EDITION"; fi
  exit 1
fi

if [ "$HARDEN" -eq 1 ]; then
  echo "Raising residual hardcoded limits to $LIMIT"
  for f in $HARDEN_FILES; do harden_file "$f"; done
fi

# force the GUI to rebuild menu.txt so the edition flag flips to full
rm -f "$S2R/tmp/menu.txt" "$S2R/tmp/menu.txt-tmp" 2>/dev/null || true

echo
report_status
