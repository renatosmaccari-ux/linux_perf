#!/bin/sh
#
# topology.sh - CGI wrapper for the topology data page.
# Mirrors the product's own wrappers: load the environment, then exec the perl.

CGID=`dirname $0`
if [ "$CGID" = "." ]; then
  CGID=`pwd`
fi
INPUTDIR_NEW=`dirname $CGID`

if [ -f "$INPUTDIR_NEW/etc/lpar2rrd.cfg" ]; then
  . $INPUTDIR_NEW/etc/lpar2rrd.cfg
elif [ -f "$INPUTDIR_NEW/etc/stor2rrd.cfg" ]; then
  . $INPUTDIR_NEW/etc/stor2rrd.cfg
fi

INPUTDIR=${INPUTDIR:-$INPUTDIR_NEW}
export INPUTDIR

BINDIR=${BINDIR:-$INPUTDIR/bin}
PERL=${PERL:-perl}
TMPDIR_LPAR="$INPUTDIR/tmp"
export TMPDIR_LPAR BINDIR PERL

umask 002
ERRLOG=${ERRLOG:-$INPUTDIR/logs/error.log}
export ERRLOG

exec $PERL $INPUTDIR/topology/cgi/topology_cgi.pl 2>>$ERRLOG
