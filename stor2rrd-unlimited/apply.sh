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
#   ./apply.sh [--harden] [--fix-vendor-bugs] [--fix-permissions]
#              [--add-topology] [--force]
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
#   --add-topology      install the dependency-map page as a GUI entry. Needs
#                       dash/build/topologia.{html,json}; build them first with
#                       dash/build-topology.py. Additive; --revert leaves the
#                       page in place but restores the files it patched.
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
ADDTOPO=0
FORCE=0
MODE=apply
HOME_ARG=""

for arg in "$@"; do
  case "$arg" in
    --harden) HARDEN=1 ;;
    --fix-vendor-bugs) VENDORFIX=1 ;;
    --fix-permissions) FIXPERMS=1 ;;
    --add-topology)    ADDTOPO=1 ;;
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
XORUXLIB="$S2R/bin/Xorux_lib.pm"
NUTANIXPM="$S2R/bin/Nutanix.pm"
NUTANIXTEST="$S2R/bin/nutanix-apitest.pl"
ODBLOAD="$S2R/bin/OracleDBLoadDataModule.pm"

# the GUI installer: it rebuilds tmp/menu.txt and copies html/ into the web
# directory on every run, so a new page has to be registered in both places
if [ -f "$S2R/bin/install-html.sh" ]; then
  INSTALLER="$S2R/bin/install-html.sh"       # LPAR2RRD
else
  INSTALLER="$S2R/bin/install-st.sh"         # STOR2RRD
fi
TOPO_SRC="$SELF_DIR/dash/build"
TOPO_KIT="$SELF_DIR/topology"
if [ -d "$S2R/lpar2rrd-cgi" ]; then
  CGIDIR="$S2R/lpar2rrd-cgi"
else
  CGIDIR="$S2R/stor2rrd-cgi"
fi
VENDORFIX_FILES="$HOSTCFGPL $RESTAPIPL $XORUXLIB $NUTANIXPM $NUTANIXTEST $ODBLOAD $MAINJS"

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
# Every html/.<letter> the product tests is a per-technology gate: .p Power,
# .v VMware, .x XenServer, .h Hyper-V, .l Linux, .s Solaris, .o oVirt,
# .n Nutanix, .t OpenShift, .m OracleVM, .a Proxmox, .f FusionCompute,
# .z Azure, .r Docker, .b OracleDB, .g PostgreSQL, .i Db2, .q MS SQL.
# They gate more than the device count: custom.pl graphs only the first 4
# items of a custom group when the matching marker is missing.
#
# Deriving them from HostCfg.pm alone found five. They are referenced in two
# forms and across many files, so scan the whole tree for both.
marker_list() {
  [ -d "$S2R/bin" ] || return 0
  {
    # plain:  -f "$basedir/html/.p"   /  [ -f "$INPUTDIR/html/.p" ]
    grep -rhoE 'html/\.[a-z]\b' "$S2R/bin" "$S2R/lpar2rrd-cgi" "$S2R/stor2rrd-cgi" \
      2>/dev/null | sed 's|^html|/html|'
    # hex-escaped, the way HostCfg.pm hides them
    grep -rhoE 'basedir(\\x[0-9A-Fa-f]{2})+' "$S2R/bin" 2>/dev/null | perl -ne '
      s/^basedir//;
      s/\\x([0-9A-Fa-f]{2})/chr(hex($1))/ge;
      print if m{^/html/\.[a-z]$};
      print "\n";
    '
  } | grep -E '^/html/\.[a-z]$' | sort -u
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
    host_cfg.pl)     vendorfix_hostcfg "$1"; vendorfix_hostsjson "$1" ;;
    hmc_rest_api.pl) vendorfix_restapi "$1" ;;
    Xorux_lib.pm)    vendorfix_xoruxlib "$1" ;;
    Nutanix.pm)      vendorfix_nutanix "$1" ;;
    nutanix-apitest.pl) vendorfix_nutanixtest "$1" ;;
    OracleDBLoadDataModule.pm) vendorfix_oracledb "$1" ;;
    main.js)         vendorfix_mainjs  "$1" ;;
  esac
}

# LPAR2RRD - every button on a configuration page is bound inside the callback
#   of $.getJSON('/lpar2rrd-cgi/hosts.sh?cmd=json'). If that request fails, or
#   its JSON does not parse, the callback never runs: New, Edit, Clone, Delete
#   and Connection Test all render and do nothing, the host table stays empty,
#   and nothing on screen says why. The usual causes are local - the CGI
#   returning 500, or etc/web_config/hosts.json unreadable by the web server
#   user - but the page hides them.
#
#   Chain a .fail() so the reason is shown instead of swallowed. This does not
#   make a broken endpoint work; it stops the page from failing silently.
vendorfix_mainjs() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork: hosts.sh cmd=json' "$f" && return 0   # already fixed
  corpo="$SELF_DIR/patches/hostcfg-json-failure.js"
  if [ ! -f "$corpo" ]; then
    echo "apply.sh: patches/hostcfg-json-failure.js missing, skipping $f" >&2
    return 0
  fi

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"

  CORPO="$corpo" perl -0777 -i -pe '
    BEGIN { local $/; open my $fh, "<", $ENV{CORPO} or die; $novo = <$fh> }
    # fecho do callback do getJSON, seguido do teste de edicao: unico no arquivo
    my $anc = "\t\t\t}\n\t\t});\n\t\tif (sysInfo.free == 1) {\n";
    my $n = s/\Q$anc\E/$novo/;
    die "apply.sh: cmd=json callback not found in main.js\n" unless $n == 1;
  ' "$f" || { mv "$f.xoruxfork-orig" "$f"; return 1; }

  # Um registro OracleDB incompleto fazia val.hosts[0] lancar TypeError no
  # meio do $.each das aliases, abortando o mesmo callback - com o agravante
  # de ser excecao sincrona, que o .fail() acima nao pega.
  # So o main.js do LPAR2RRD tem o bloco OracleDB; no do STOR2RRD a ausencia
  # e normal e nao pode fazer o patch anterior ser revertido.
  corpo2="$SELF_DIR/patches/oracledb-host-undefined.js"
  if [ -f "$corpo2" ] \
     && grep -q 'val.host = val.hosts\[0\];' "$f" \
     && ! grep -q 'xoruxfork: val.hosts pode nao existir' "$f"; then
    CORPO2="$corpo2" perl -0777 -i -pe '
      BEGIN { local $/; open my $fh, "<", $ENV{CORPO2} or die; $novo = <$fh> }
      my $anc = "\t\t\t\t\tif (! val.host ) {\n"
              . "\t\t\t\t\t\tval.host = val.hosts[0];\n"
              . "\t\t\t\t\t}\n";
      my $n = s/\Q$anc\E/$novo/;
      die "apply.sh: val.hosts[0] guard point not found in main.js\n" unless $n == 1;
    ' "$f" || echo "apply.sh: nao foi possivel proteger val.hosts[0] em ${f#$S2R/}" >&2
    grep -q 'xoruxfork: val.hosts pode nao existir' "$f" \
      && echo "  fixed   : ${f#$S2R/} (um registro OracleDB incompleto nao derruba mais a pagina)"
  fi

  echo "  fixed   : ${f#$S2R/} (a failed cmd=json now says so instead of killing every button)"
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

# The atomic write_json above stops new corruption; it does not repair files
# that are already cut off. Ship the finder alongside the product's own scripts
# so there is something to run after the fix goes in.
instala_ferramenta() {
  origem="$SELF_DIR/tools/$1"
  descricao=${2:-}
  [ -f "$origem" ] || return 0
  destino="$S2R/bin/$1"
  if [ -f "$destino" ] && cmp -s "$origem" "$destino"; then return 0; fi
  cp -p "$origem" "$destino" || return 1
  chmod 755 "$destino"
  grep -qx "/bin/$1" "$MANIFEST" 2>/dev/null || echo "/bin/$1" >> "$MANIFEST"
  echo "  installed: bin/$1${descricao:+ ($descricao)}"
}

# Both products - "$obj->method" inside a double-quoted string does not call the
#   method. Perl interpolates $obj, which stamps HTTP::Response=HASH(0x...),
#   and leaves "->status_line" as text. The products do this in 19 places, every
#   one of them on an error path, so the status code that would say whether a
#   request was 401, 403, 500 or a timeout is the one thing the message loses.
#   Seen in a live log as
#     ERROR naperf.pl: Request error: HTTP::Response=HASH(0x2aaab0d8)->status_line
#   @{[ ... ]} evaluates the expression inside the string. Only ->method is
#   touched: ->{key} and ->[index] interpolate correctly and are left alone, as
#   is ->method(args), which needs a human to look at it.
vendorfix_interpolacao() {
  [ -d "$S2R/bin" ] || return 0
  prog="$SELF_DIR/patches/interpolacao-metodo.pl"
  if [ ! -f "$prog" ]; then
    echo "apply.sh: patches/interpolacao-metodo.pl missing, skipping" >&2
    return 0
  fi

  total=0
  arquivos=0
  for f in "$S2R"/bin/*.pl "$S2R"/bin/*.pm; do
    [ -f "$f" ] || continue
    grep -q '@{\[' "$f" 2>/dev/null && continue        # already fixed

    compiled_before=0
    perl_ok "$f" && compiled_before=1

    n=$(perl "$prog" "$f" 2>/dev/null) || continue
    [ "${n:-0}" -gt 0 ] || continue

    if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
      echo "apply.sh: ${f#$S2R/} compiled before the interpolation fix and not after" >&2
      [ -f "$f.xoruxfork-novo" ] && rm -f "$f.xoruxfork-novo"
      continue
    fi
    total=$((total + n))
    arquivos=$((arquivos + 1))
  done

  [ "$total" -gt 0 ] && \
    echo "  fixed   : $total error message(s) in $arquivos file(s) now print the status, not HASH(0x...)->method"
  return 0
}

# LPAR2RRD - an OracleDB datasource with no value becomes "U" and disappears.
#   OracleDBLoadDataModule::update_rrd substitutes "U" for every missing metric
#   and says nothing. The graph then draws -nan and no part of the interface
#   explains it. On a live system all four instances wrote
#     Capacity  <ts>:4391.78:490.48:U          (log_capacity missing)
#     Cpct      <ts>:U:142.20:U:U              (3 of 4 missing)
#   because the monitoring user had no SELECT on V$LOG, V$CONTROLFILE and
#   V$RECOVERY_FILE_DEST - ORA-00942 in the collection log, 180 lines away from
#   the graph that went blank. Naming the view turns an unexplained -nan into a
#   GRANT to ask the DBA for.
vendorfix_oracledb() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork: dizer o que ficou sem dado' "$f" && return 0   # already fixed
  grep -q 'sub update_rrd' "$f" || return 0
  corpo="$SELF_DIR/patches/oracledb-missing-ds.pl"
  decl="$SELF_DIR/patches/oracledb-missing-ds-decl.pl"
  if [ ! -f "$corpo" ] || [ ! -f "$decl" ]; then
    echo "apply.sh: patches/oracledb-missing-ds*.pl missing, skipping ${f#$S2R/}" >&2
    return 0
  fi

  compiled_before=0
  perl_ok "$f" && compiled_before=1

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"

  CORPO="$corpo" DECL="$decl" perl -0777 -i -pe '
    BEGIN {
      local $/;
      open my $c, "<", $ENV{CORPO} or die; $corpo = <$c>;
      open my $d, "<", $ENV{DECL}  or die; $decl  = <$d>;
    }
    # a declaracao do acumulador, junto da $update_string
    s/^  my \$update_string = "\$act_time:";\n/$decl/m
      or die "apply.sh: update_string declaration not found\n";

    # o corpo do laco mais o print, montado com aspas duplas porque a ancora
    # tem apostrofos e o programa esta entre aspas simples do shell
    my $anc = "    if ( !defined \$hash{\$item} || \$hash{\$item} eq \x27\x27 ) {    #|| ! isdigit( \$hash{\$item} )\n"
            . "      \$value = \x27U\x27;\n    }\n    else {\n      \$value = \$hash{\$item};\n    }\n"
            . "    \$update_string .= \"\$value:\";\n  }\n"
            . "  \$update_string = substr( \$update_string, 0, -1 );\n  print \"\\n\$update_string\\n\";\n";
    s/\Q$anc\E/$corpo/
      or die "apply.sh: update_rrd value loop not found\n";
  ' "$f" || { mv "$f.xoruxfork-orig" "$f"; return 1; }

  if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
    echo "apply.sh: ${f#$S2R/} compiled before the vendor fix and not after, restoring" >&2
    mv "$f.xoruxfork-orig" "$f"
    return 1
  fi
  echo "  fixed   : ${f#$S2R/} (a missing datasource now names itself and its view)"
}

# LPAR2RRD - a Nutanix 401 is logged as a wall of HTML and shown as nothing.
#   The three restCall subs in bin/Nutanix.pm log
#   `Dumper( $response->content )` with no status code, so a Prism that answers
#   401 fills logs/error.log-nutanix with the Tomcat error page once per
#   endpoint - about 180 lines to convey one number - while the GUI's
#   connection test (bin/nutanix-apitest.pl) only ever says "No clusters
#   reached", whatever went wrong. 401 (wrong password, no role, locked
#   account), 403 (authenticated, no role), 404 (that address is a Prism
#   Central) and a timeout are indistinguishable on screen.
#
#   Log the status code, the reason and WWW-Authenticate, reduce an HTML error
#   page to its <title>, and let the connection test name the cause. Also fixes
#   the "uninitialized value in numeric ge" that the test emits on every
#   failure, because $clusters is undef on the error path.
vendorfix_nutanix() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork: dizer o codigo HTTP' "$f" && return 0     # already fixed
  grep -q 'ERROR: Can.t handle request' "$f" || return 0
  corpo="$SELF_DIR/patches/nutanix-http-status.pl"
  if [ ! -f "$corpo" ]; then
    echo "apply.sh: patches/nutanix-http-status.pl missing, skipping ${f#$S2R/}" >&2
    return 0
  fi

  compiled_before=0
  perl_ok "$f" && compiled_before=1

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"

  CORPO="$corpo" perl -0777 -i -pe '
    BEGIN { local $/; open my $fh, "<", $ENV{CORPO} or die; $novo = <$fh> }
    # o helper entra antes de sub error, que fecha o modulo
    s/^sub error \{/$novo . "sub error {"/me
      or die "apply.sh: no sub error in Nutanix.pm to anchor on\n";
    # as tres chamadas identicas, uma por versao da API. A ancora e montada
    # como string entre aspas duplas porque \Q...\E nao interpreta \x27, e o
    # programa esta entre aspas simples do shell: nao cabe um apostrofo literal.
    my $velho = "error( \"ERROR: Can\x27t handle request (\".\$url.\"): \" "
              . ". Dumper( \$response->content ) );";
    my $n = s/\Q$velho\E/error( resumo_http( \$url, \$response ) );/g;
    die "apply.sh: expected 3 Nutanix error calls, rewrote $n\n" unless $n == 3;
  ' "$f" || { mv "$f.xoruxfork-orig" "$f"; return 1; }

  if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
    echo "apply.sh: ${f#$S2R/} compiled before the vendor fix and not after, restoring" >&2
    mv "$f.xoruxfork-orig" "$f"
    return 1
  fi
  echo "  fixed   : ${f#$S2R/} (a Nutanix error now logs its HTTP status, not a page of HTML)"
}

vendorfix_nutanixtest() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork: dizer por que a conexao falhou' "$f" && return 0   # already fixed
  grep -q 'No clusters reached' "$f" || return 0
  corpo="$SELF_DIR/patches/nutanix-apitest-status.pl"
  if [ ! -f "$corpo" ]; then
    echo "apply.sh: patches/nutanix-apitest-status.pl missing, skipping ${f#$S2R/}" >&2
    return 0
  fi

  compiled_before=0
  perl_ok "$f" && compiled_before=1

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"

  CORPO="$corpo" perl -0777 -i -pe '
    BEGIN { local $/; open my $fh, "<", $ENV{CORPO} or die; $novo = <$fh> }
    my $anc = "if ( \$clusters->{metadata}{totalEntities} >= 1 ) {\n"
            . "  Xorux_lib::status_json( 1, \"Reached \" . \$clusters->{metadata}{totalEntities} . \" clusters\" );\n"
            . "}\n"
            . "else {\n"
            . "  Xorux_lib::status_json( 0, \"No clusters reached\" );\n"
            . "}\n";
    s/\Q$anc\E/$novo/
      or die "apply.sh: nutanix-apitest.pl verdict block not found\n";
  ' "$f" || { mv "$f.xoruxfork-orig" "$f"; return 1; }

  if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
    echo "apply.sh: ${f#$S2R/} compiled before the vendor fix and not after, restoring" >&2
    mv "$f.xoruxfork-orig" "$f"
    return 1
  fi
  echo "  fixed   : ${f#$S2R/} (the connection test names the cause instead of \"No clusters reached\")"
}

# LPAR2RRD - Xorux_lib::write_json() is the write path for every JSON file the
#   product produces (225 call sites). It writes to a File::Temp file in /tmp
#   and then File::Copy::copy()s it over the destination. copy() truncates the
#   destination and streams into it, so it is not atomic: any reader that opens
#   the file mid-copy sees cut-off JSON, and a failed write (a full disk) leaves
#   the destination truncated for good. The return of copy() was never checked,
#   so write_json reported success either way.
#
#   Seen in the field as data/OracleDB/<alias>/configuration/conf.json failing
#   to parse at "character offset 303104" - 74 x 4096, a block boundary - which
#   dropped the whole database instance out of the collection.
#
#   Replace the sub with a version that writes a sibling temp file in the
#   destination directory and rename()s it into place: atomic within one
#   filesystem, with print, close, length and rename all checked.
#   STOR2RRD's Xorux_lib.pm has no write_json, so its absence is normal there.
vendorfix_xoruxlib() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork: gravacao atomica' "$f" && return 0        # already fixed
  grep -q '^sub write_json {' "$f" || return 0                  # STOR2RRD
  corpo="$SELF_DIR/patches/write-json-atomic.pl"
  if [ ! -f "$corpo" ]; then
    echo "apply.sh: patches/write-json-atomic.pl missing, skipping ${f#$S2R/}" >&2
    return 0
  fi

  compiled_before=0
  perl_ok "$f" && compiled_before=1

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"

  CORPO="$corpo" perl -0777 -i -pe '
    BEGIN { local $/; open my $fh, "<", $ENV{CORPO} or die; $novo = <$fh> }
    # da assinatura ate o fecho da sub, na coluna 0: write_json e a unica sub
    # do arquivo que termina assim logo antes de "sub read_json"
    my $n = s/^sub write_json \{\n.*?\n\}\n(?=\nsub read_json \{)/$novo/ms;
    die "apply.sh: write_json() body not found in Xorux_lib.pm\n" unless $n == 1;
  ' "$f" || { mv "$f.xoruxfork-orig" "$f"; return 1; }

  if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
    echo "apply.sh: ${f#$S2R/} compiled before the vendor fix and not after, restoring" >&2
    mv "$f.xoruxfork-orig" "$f"
    return 1
  fi
  echo "  fixed   : ${f#$S2R/} (write_json is atomic now, no more half-written conf.json)"
}

# LPAR2RRD - saving the host configuration did open(">", hosts.json) first and
#   decode_json($PAR{acl}) second. The open truncates immediately, so a bad
#   payload killed the decode with the file already at zero bytes and every
#   configured device gone - the hosts.json.CORROMPIDO backups these installs
#   accumulate. The write itself was unchecked too (print, close), so a full
#   disk produced a cut-off file under a "successfully saved" message, and
#   flock() came after the truncation, which is too late to protect anything.
#
#   Validate the payload before touching the file, write to a sibling temp and
#   rename() it into place, and report a failed write instead of claiming
#   success. The previous configuration survives every failure path.
vendorfix_hostsjson() {
  f=$1
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork: validar o payload ANTES' "$f" && return 0   # already fixed
  grep -q 'if ( open( my \$CFG, ">", "\$cfgdir/hosts.json" ) ) {' "$f" || return 0
  abre="$SELF_DIR/patches/hostsjson-atomic-open.pl"
  grava="$SELF_DIR/patches/hostsjson-atomic-write.pl"
  if [ ! -f "$abre" ] || [ ! -f "$grava" ]; then
    echo "apply.sh: patches/hostsjson-atomic-*.pl missing, skipping ${f#$S2R/}" >&2
    return 0
  fi

  compiled_before=0
  perl_ok "$f" && compiled_before=1

  # suffix proprio: vendorfix_hostcfg ja usa .xoruxfork-orig e um rollback
  # nosso nao deve desfazer o patch dele
  cp -p "$f" "$f.xoruxfork-prejson"

  ABRE="$abre" GRAVA="$grava" perl -0777 -i -pe '
    BEGIN {
      local $/;
      open my $a, "<", $ENV{ABRE}  or die; $abre  = <$a>;
      open my $g, "<", $ENV{GRAVA} or die; $grava = <$g>;
    }
    # aspas duplas, nao qq{}: as ancoras tem chaves desbalanceadas
    my $anc1 = "    if ( open( my \$CFG, \">\", \"\$cfgdir/hosts.json\" ) ) {\n"
             . "      my \$cfg = decode_json( \$PAR{acl} );\n";
    s/\Q$anc1\E/$abre/
      or die "apply.sh: hosts.json open/decode pair not found\n";

    my $anc2 = "      flock( \$CFG, LOCK_EX );\n"
             . "      print \$CFG \$json->encode(\$cfg);\n"
             . "      close \$CFG;\n";
    s/\Q$anc2\E/$grava/
      or die "apply.sh: hosts.json write block not found\n";
  ' "$f" || { mv "$f.xoruxfork-prejson" "$f"; return 1; }

  if [ "$compiled_before" -eq 1 ] && ! perl_ok "$f"; then
    echo "apply.sh: ${f#$S2R/} compiled before the hosts.json fix and not after, restoring" >&2
    mv "$f.xoruxfork-prejson" "$f"
    return 1
  fi
  rm -f "$f.xoruxfork-prejson"
  echo "  fixed   : ${f#$S2R/} (a bad save no longer empties hosts.json)"
}

# O painel de ferramentas da direita (Platform, Database, ... Utilities) e
# estatico dentro de html/index.html: nao vem de tmp/menu.txt. Registrar so no
# menu.txt deixava a pagina publicada e alcancavel pela URL, mas sem nenhum
# lugar na interface por onde chegar nela - que foi exatamente o que aconteceu.
registra_index() {
  f="$S2R/html/index.html"
  [ -f "$f" ] || return 0
  grep -q 'xoruxfork topology' "$f" && return 0          # already registered
  corpo="$SELF_DIR/patches/topologia-index-menu.html"
  [ -f "$corpo" ] || { echo "apply.sh: patches/topologia-index-menu.html missing" >&2; return 0; }
  grep -q 'data-abbr="logs"' "$f" || {
    echo "apply.sh: Utilities block not found in html/index.html, skipping" >&2
    return 0; }

  [ -f "$f.xoruxfork-orig" ] || cp -p "$f" "$f.xoruxfork-orig"
  cgi=$(basename "$CGIDIR")
  # A classe do <li> difere entre os produtos ("nobfu msublevel" no LPAR2RRD,
  # so "nobfu" no STOR2RRD), entao a ancora e o link do Log e as entradas novas
  # herdam a classe e a indentacao que estiverem la.
  CORPO="$corpo" CGI="$cgi" perl -0777 -i -pe '
    BEGIN { local $/; open my $h, "<", $ENV{CORPO} or die; $modelo = <$h>;
            $modelo =~ s{/CGIDIR/}{/$ENV{CGI}/}g }
    s{(^([ \t]*)<li\s+class="([^"]*)"[^>]*>(?:(?!</li>).)*?href="gui-log\.html".*?</li>\n)}{
        my ($linha, $indent, $classe) = ($1, $2, $3);
        my $novo = $modelo;
        $novo =~ s/^\t/$indent/mg;
        $novo =~ s/class="nobfu msublevel"/class="$classe"/g;
        $linha . $novo;
    }mse
      or die "apply.sh: Log entry not found in html/index.html\n";
  ' "$f" || { mv "$f.xoruxfork-orig" "$f"; return 1; }
  echo "  registered: html/index.html (Topologia em Utilities)"
}

# -------------------------------------------------------------- topology page
# A static page is not enough on its own: the installer copies a fixed list of
# files from html/ into the web directory and regenerates tmp/menu.txt from
# scratch, so an unregistered page is both unreachable and unlinked after the
# next collection run.
add_topology() {
  for f in topologia.html topologia.json; do
    [ -f "$TOPO_SRC/$f" ] || {
      echo "apply.sh: $TOPO_SRC/$f missing - build it first:" >&2
      echo "          dash/build-topology.py <export.html> dash/assets/d3.min.js dash/build" >&2
      return 1
    }
  done

  # ---------------------------------------------------------------- the page
  # the page uploads from its own panel, so it needs this product's CGI path
  cgiweb=$(basename "$CGIDIR")
  sed "s|__TOPO_CGI__|/$cgiweb/topology.sh|g" \
    "$TOPO_SRC/topologia.html" > "$S2R/html/topologia.html"
  if grep -q '__TOPO_CGI__' "$S2R/html/topologia.html"; then
    echo "apply.sh: could not set the CGI path in topologia.html" >&2
    return 1
  fi
  # O produto carrega as paginas do menu com $('#content').load(url): o HTML
  # entra na MESMA janela, sem iframe. A pagina usava position:fixed, que se
  # ancora na janela e nao no elemento pai, entao o mapa cobria o logo, o menu
  # e o conteudo do LPAR2RRD. Este passo a prende num contentor e acrescenta o
  # botao de voltar.
  if [ -f "$SELF_DIR/patches/topologia-embutida.py" ]; then
    saida=$(python3 "$SELF_DIR/patches/topologia-embutida.py" \
              "$S2R/html/topologia.html" 2>&1) \
      && echo "  contained: html/topologia.html ($saida)" \
      || { echo "apply.sh: nao consegui conter a pagina: $saida" >&2; return 1; }
  fi

  # never overwrite a map the site has already built
  [ -f "$S2R/html/topologia.json" ] || cp -p "$TOPO_SRC/topologia.json" "$S2R/html/"
  echo "  installed: html/topologia.html, html/topologia.json"
  if [ -d "$S2R/www" ]; then
    cp -p "$S2R/html/topologia.html" "$S2R/www/"
    [ -f "$S2R/www/topologia.json" ] || cp -p "$TOPO_SRC/topologia.json" "$S2R/www/"
  fi

  # ------------------------------------------------- the pipeline that feeds it
  if [ -d "$TOPO_KIT" ]; then
    mkdir -p "$S2R/topology/facts/conexoes" "$S2R/topology/uploads"
    cp -Rp "$TOPO_KIT/bin" "$TOPO_KIT/cgi" "$S2R/topology/" 2>/dev/null
    [ -d "$TOPO_KIT/collectors" ] && cp -Rp "$TOPO_KIT/collectors" "$S2R/topology/"
    chmod +x "$S2R/topology/bin/"*.sh "$S2R/topology/bin/"*.py "$S2R/topology/cgi/"*.sh 2>/dev/null
    [ -f "$S2R/topology/topologia.json" ] || cp -p "$TOPO_SRC/topologia.json" "$S2R/topology/"
    echo "  installed: topology/ (builder, collectors, uploads)"

    # the CGI that takes spreadsheets
    if [ -d "$CGIDIR" ]; then
      cp -p "$TOPO_KIT/cgi/topology.sh" "$CGIDIR/topology.sh"
      chmod +x "$CGIDIR/topology.sh"
      echo "  installed: ${CGIDIR#$S2R/}/topology.sh"
    fi

    # LPAR2RRD runs every bin/user_script*.sh at the end of load.sh - an
    # official hook, so nothing needs patching there.
    if [ -f "$S2R/load.sh" ] && grep -q 'user_script\*\.sh' "$S2R/load.sh"; then
      cat > "$S2R/bin/user_script_topology.sh" <<'SHIM'
#!/bin/sh
# Picked up by load.sh (bin/user_script*.sh); the work is in topology/bin.
exec "${INPUTDIR:-$(cd "$(dirname "$0")/.." && pwd)}/topology/bin/user_script_topology.sh"
SHIM
      chmod +x "$S2R/bin/user_script_topology.sh"
      echo "  collect  : bin/user_script_topology.sh (load.sh user-script hook)"
    elif [ -f "$S2R/load.sh" ]; then
      # STOR2RRD has no such hook: insert one call before load.sh ends
      if grep -q 'xoruxfork topology' "$S2R/load.sh"; then
        echo "  collect  : load.sh already calls the builder"
      else
        [ -f "$S2R/load.sh.xoruxfork-orig" ] || cp -p "$S2R/load.sh" "$S2R/load.sh.xoruxfork-orig"
        perl -0777 -i -pe '
          s{(\n)(date\nexit 0\n?)\z}
           {$1 . qq(# xoruxfork topology\n)
              . qq([ -f "\$INPUTDIR/topology/bin/user_script_topology.sh" ] &&\n)
              . qq(  sh "\$INPUTDIR/topology/bin/user_script_topology.sh"\n\n) . $2}e
            or die "apply.sh: could not find the tail of load.sh\n";
        ' "$S2R/load.sh" || { mv "$S2R/load.sh.xoruxfork-orig" "$S2R/load.sh"; return 1; }
        echo "  collect  : load.sh (builder called at the end of each cycle)"
      fi
    fi
  fi

  # ------------------------------------------------------------------- menus
  md="$S2R/html/menu_default.txt"
  if [ -f "$md" ]; then
    [ -f "$md.xoruxfork-orig" ] || cp -p "$md" "$md.xoruxfork-orig"
    doc=$(grep '^T:doc:' "$md" | head -1)
    if [ -n "$doc" ]; then
      grep -q '^T:topo:' "$md" || printf '%s\n' "$doc" \
        | sed 's|^T:doc:[^:]*:[^:]*:|T:topo:Topologia:topologia.html:|' >> "$md"
      # ":" is the field separator; genjson.pl decodes ===double-col=== back
      # to a colon (sub collons). A raw colon here would split the label.
      grep -q '^T:topodata:' "$md" || printf '%s\n' "$doc" \
        | sed "s|^T:doc:[^:]*:[^:]*:|T:topodata:Topologia===double-col=== dados:/$cgiweb/topology.sh:|" >> "$md"
      echo "  menu     : html/menu_default.txt"
    fi
  fi

  [ -f "$INSTALLER" ] || { echo "apply.sh: no GUI installer found, menu not registered" >&2; return 1; }
  if grep -q 'xoruxfork topology' "$INSTALLER"; then
    echo "  menu     : ${INSTALLER#$S2R/} already registered"
    return 0
  fi
  [ -f "$INSTALLER.xoruxfork-orig" ] || cp -p "$INSTALLER" "$INSTALLER.xoruxfork-orig"

  CGIWEB=$(basename "$CGIDIR") perl -0777 -i -pe '
    my $cgi = $ENV{CGIWEB};
    # 1. have the installer copy the page into the web directory
    my $copied = 0;
    $copied = 1 if s{(\n\s*cp [^\n]*not.implemented[^\n]*WEBDIR[^\n]*\n)}
                    {$1 . qq(cp "\$INPUTDIR/html/topologia.html" "\$WEBDIR/"   # xoruxfork topology\n)
                        . qq([ -f "\$WEBDIR/topologia.json" ] || cp "\$INPUTDIR/html/topologia.json" "\$WEBDIR/"   # xoruxfork topology\n)}e;
    # 2. register both pages in the tools menu
    my $linked = 0;
    $linked = 1 if s{(\n([ \t]*)menu "\$type_tmenu" "(?:logs|errcgi)"([^\n]*)\n)}{
                      my ( $all, $indent, $rest ) = ( $1, $2, $3 );
                      my $redir = $rest =~ /MENU_OUT/ ? qq( >> "\$MENU_OUT") : "";
                      $all . $indent
                        . qq(menu "\$type_tmenu" "topo" "Topologia" "topologia.html")
                        . $redir . qq(   # xoruxfork topology\n)
                        . $indent
                        . qq(menu "\$type_tmenu" "topodata" "Topologia: importar dados" "/$cgi/topology.sh")
                        . $redir . qq(   # xoruxfork topology\n);
                    }e;
    die "apply.sh: could not register the pages (copy=$copied menu=$linked)\n"
      unless $copied && $linked;
  ' "$INSTALLER" || { mv "$INSTALLER.xoruxfork-orig" "$INSTALLER"; return 1; }

  echo "  menu     : ${INSTALLER#$S2R/} (copy to WEBDIR + two tools-menu entries)"
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

# Derive the fork's module from the stock one. The module holds more than one
# edition switch:
#
#   premium()        "free" (4 chars); every cap tests length() == 6
#   get_lpar_num()   0; custom.pl gates 25 item counts on !get_lpar_num()
#
#   get_rperf_all(), rperf_check(), lpm(), lpm_find_files() take arguments and
#   return data, not booleans - they are Enterprise implementations that are
#   absent from the GPL tree, not caps. Forcing a value there would feed
#   callers a number where they expect rPerf cores or a list of RRD files, so
#   they are carried over untouched.
SRC="$STOCK"
[ -f "$EDITION.xoruxfork-orig" ] && SRC="$EDITION.xoruxfork-orig"
perl -0777 -pe '
  my $s = "'"$EDITION_STRING"'";
  s/(sub\s+premium\s*\{\s*return\s+)"[^"]*"/$1"$s"/
    or die "apply.sh: no premium() definition to rewrite\n";
  # 0 means "free" here; custom.pl truncates a group at 4-5 items without it
  # the STOR2RRD module has premium() only, so absence is normal; complain
  # only when the sub is there and the rewrite failed to take
  if ( /sub\s+get_lpar_num/ ) {
    s/(sub\s+get_lpar_num\s*\{\s*return\s+)0\b/${1}1/
      or warn "apply.sh: get_lpar_num() present but not rewritten, "
            . "custom groups may stay capped\n";
  }
  s{\A}{"# Modified by the '"$MARKER"': premium() returns a 6-character\n"
       . "# string and get_lpar_num() returns true - between them every\n"
       . "# free-edition cap in this product is lifted.\n"
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
  vendorfix_interpolacao
  instala_ferramenta "acha-json-corrompido.pl" \
    "lista e tira do caminho JSON truncado em data/"
  instala_ferramenta "escalona-cron.sh" \
    "espalha os coletores pelos minutos, para nao gravarem todos de uma vez"
  instala_ferramenta "verifica-topologia.sh" \
    "diz o que da pagina Topologia falta e por que o grafo pode estar vazio"
fi

if [ "$ADDTOPO" -eq 1 ]; then
  echo "Installing the dependency-map page"
  add_topology
  registra_index
fi

if [ "$FIXPERMS" -eq 1 ]; then
  echo "Opening group access so the web server user can read the tree"
  fix_permissions
fi

# force the GUI to rebuild menu.txt so the edition flag flips to full
rm -f "$S2R/tmp/menu.txt" "$S2R/tmp/menu.txt-tmp" 2>/dev/null || true

# The custom-group limit notice is sticky. custom.pl copies html/.li into
# tmp/.custom-group-<group>-n.cmd and www/custom/<group>/ll the first time a
# group exceeds four items, detail-cgi.pl prints it whenever that file exists -
# it never re-checks the edition - and nothing ever deletes it. Lifting the cap
# therefore leaves the warning on screen and the group still looking capped.
limpa_avisos() {
  n=0
  for f in "$S2R"/tmp/.custom-group-*-n.cmd; do
    [ -f "$f" ] && rm -f "$f" && n=$((n + 1))
  done
  for d in "$S2R"/www "$S2R"/html "$WEBDIR"; do
    [ -n "$d" ] && [ -d "$d/custom" ] || continue
    for f in "$d"/custom/*/ll; do
      [ -f "$f" ] && rm -f "$f" && n=$((n + 1))
    done
  done
  [ "$n" -gt 0 ] && echo "cleared       : $n stale custom-group limit notice(s)"
  return 0
}
limpa_avisos

echo
report_status
