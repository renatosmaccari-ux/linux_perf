# premium.pl - edition module for the unlimited STOR2RRD fork
#
# Copyright (C) 2026 STOR2RRD unlimited fork contributors
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# This is an independent reimplementation of the edition-selection
# interface that STOR2RRD loads from bin/premium.pl when present and
# from bin/standard.pl otherwise. No upstream code is copied here.
#
# Interface expected by the callers (data_load.pl, detail-cgi.pl,
# genjson.pl, lan.pl, overview.pl, reporter.pl, san.pl, storage.pl,
# volume_inactive.pl, AlertStor2rrd.pm, CustomStor2rrd.pm,
# GraphVizLib.pm, LoadMetrics.pm, install-st.sh):
#
#   premium()     - callers gate every capacity limit on
#                   length( premium() ) == 6, so this must return a
#                   string of exactly 6 characters.
#   set_reports() - scheduled-report hook. Upstream bin/standard.pl
#                   returns 1 without doing any work; this fork keeps
#                   that behaviour, so scheduled report *generation* is
#                   not implemented here (see README).

sub premium { return "forked"; }    # exactly 6 chars - unlocks all caps

sub set_reports { return 1; }

return 1;
