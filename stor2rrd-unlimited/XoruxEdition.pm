package XoruxEdition;

# XoruxEdition.pm - edition module for the unlimited STOR2RRD fork (8.x)
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
# STOR2RRD 8.x replaced the 7.x bin/standard.pl + bin/premium.pl pair with
# this single module. Every capacity gate in the product tests
# length( premium() ) == 6, and bin/install-st.sh tests
#   perl -MXoruxEdition -e 'print premium();' | wc -m -eq 6
# so premium() must return a string of exactly 6 characters to select the
# unrestricted edition.
#
# The stock module returns "free" (4 characters). This drop-in replacement
# returns a 6-character string. Nothing else in the interface changes.

use Exporter;
@ISA = qw(Exporter);

@EXPORT = qw(premium);

sub premium { return "forked"; }    # exactly 6 chars - unlocks all caps

1;
