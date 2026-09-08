#!/bin/sh
#
# apply.sh - install the unlimited edition module into a STOR2RRD tree
#
# Copyright (C) 2026 STOR2RRD unlimited fork contributors
# Licensed under the GNU General Public License v3 or later.
#
# Usage:
#   ./apply.sh [--harden] [--force] [<STOR2RRD_HOME>]
#   ./apply.sh --revert            [<STOR2RRD_HOME>]
#   ./apply.sh --status            [<STOR2RRD_HOME>]
#
#   --harden   also raise the residual hardcoded free-edition literals to
#              9999. Not required (they are unreachable once the edition
#              module is installed) - belt and braces only.
#   --force    overwrite an existing bin/premium.pl. Refused by default so
#              a genuine XORUX Enterprise module is never clobbered.
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
    -h|--help) sed -n '3,22p' "$0"; exit 0 ;;
    -*) echo "apply.sh: unknown option: $arg" >&2; exit 2 ;;
    *)  HOME_ARG="$arg" ;;
  esac
done

# ---------------------------------------------------------------- locate tree
S2R="$HOME_ARG"
[ -n "$S2R" ] || S2R="$STOR2RRD_HOME"
[ -n "$S2R" ] || for c in /home/stor2rrd/stor2rrd /opt/stor2rrd /usr/local/stor2rrd; do
  [ -f "$c/bin/standard.pl" ] && S2R="$c" && break
done

if [ -z "$S2R" ] || [ ! -d "$S2R" ]; then
  echo "apply.sh: STOR2RRD home not found. Pass it explicitly:" >&2
  echo "  $0 /home/stor2rrd/stor2rrd" >&2
  exit 1
fi
if [ ! -f "$S2R/bin/standard.pl" ]; then
  echo "apply.sh: $S2R does not look like a STOR2RRD install (no bin/standard.pl)" >&2
  exit 1
fi

PREMIUM="$S2R/bin/premium.pl"
ALERTPM="$S2R/bin/AlertStor2rrd.pm"
MAINJS="$S2R/html/jquery/main.js"
LIBJS="$S2R/html/jquery/mainLib.js"

is_ours() { [ -f "$1" ] && grep -q "$MARKER" "$1" 2>/dev/null; }

# ------------------------------------------------------------------- hardening
harden_file() {
  f=$1
  [ -f "$f" ] || return 0
  [ -f "$f.s2rfork-orig" ] || cp -p "$f" "$f.s2rfork-orig"
  perl -0777 -i -pe '
    my $n = '"$LIMIT"';
    s/(sysInfo\.free\s*==\s*1\s*&&\s*\$alrttree\.getRootNode\(\)\.countChildren\(false\)\s*>=\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*vals\.type\s*==\s*\\?"VOLUME\\?"\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*vals\.type\s*==\s*\\?"POOL\\?"\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(sysInfo\.free\s*==\s*1\s*&&\s*\/\[SL\]ANPORT\/\.test\(vals\.type\)\s*&&\s*count\s*>\s*)\d+/$1$n/g;
    s/(!defined\s+\$devices\{\$storage\}\s*&&\s*\$index\s*<\s*)\d+/$1$n/g;
  ' "$f"
  echo "  hardened: $f"
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
  if [ -f "$PREMIUM" ]; then
    if is_ours "$PREMIUM"; then
      echo "edition module: bin/premium.pl (this fork)"
    else
      echo "edition module: bin/premium.pl (NOT this fork - vendor Enterprise?)"
    fi
    ed=$(cd "$S2R/bin" && perl -e 'require "./premium.pl"; print premium()' 2>/dev/null || echo "?")
    echo "premium()     : \"$ed\" (len ${#ed}) -> $([ ${#ed} -eq 6 ] && echo UNLIMITED || echo CAPPED)"
  else
    echo "edition module: none - bin/standard.pl in use -> CAPPED (free edition)"
  fi
  for f in "$ALERTPM" "$MAINJS" "$LIBJS"; do
    [ -f "$f.s2rfork-orig" ] && echo "hardened      : $f"
  done
  exit 0
}

[ "$MODE" = status ] && report_status

# ---------------------------------------------------------------------- revert
if [ "$MODE" = revert ]; then
  echo "Reverting fork in $S2R"
  if is_ours "$PREMIUM"; then
    rm -f "$PREMIUM"
    echo "  removed : $PREMIUM"
  elif [ -f "$PREMIUM" ]; then
    echo "  skipped : $PREMIUM is not this fork's file, left untouched"
  fi
  unharden_file "$ALERTPM"
  unharden_file "$MAINJS"
  unharden_file "$LIBJS"
  echo "Done. Restart the GUI / wait for the next collection cycle."
  exit 0
fi

# ----------------------------------------------------------------------- apply
if [ -f "$PREMIUM" ] && ! is_ours "$PREMIUM" && [ "$FORCE" -eq 0 ]; then
  echo "apply.sh: $PREMIUM already exists and was not created by this fork." >&2
  echo "          It may be a genuine XORUX Enterprise module. Refusing to" >&2
  echo "          overwrite. Re-run with --force if you are sure." >&2
  exit 1
fi

echo "Installing unlimited edition module into $S2R"
[ -f "$PREMIUM" ] && cp -p "$PREMIUM" "$PREMIUM.s2rfork-backup.$(date +%Y%m%d%H%M%S)"
cp "$SELF_DIR/premium.pl" "$PREMIUM"

# match ownership and permissions of the module it replaces in the load path
REF="$S2R/bin/standard.pl"
chmod --reference="$REF" "$PREMIUM" 2>/dev/null || chmod 644 "$PREMIUM"
chown --reference="$REF" "$PREMIUM" 2>/dev/null || true
echo "  installed: $PREMIUM"

if ! perl -c "$PREMIUM" >/dev/null 2>&1; then
  echo "apply.sh: installed premium.pl fails perl -c, reverting" >&2
  rm -f "$PREMIUM"
  exit 1
fi

if [ "$HARDEN" -eq 1 ]; then
  echo "Raising residual hardcoded limits to $LIMIT"
  harden_file "$ALERTPM"
  harden_file "$MAINJS"
  harden_file "$LIBJS"
fi

# force the GUI to rebuild menu.txt so the O: edition flag flips to full
rm -f "$S2R/tmp/menu.txt" "$S2R/tmp/menu.txt-tmp" 2>/dev/null || true

echo
report_status
