  # xoruxfork: VIOS collection fallback
  # The HMC answers 500 for the whole .../VirtualIOServer collection when a
  # single VIOS cannot serve its PhysicalVolume inventory. callAPI then returns
  # -1, is_vios stays empty, and every healthy VIOS on that managed system
  # loses its SEA, NPIV and VSCSI data along with the broken one. Rebuild the
  # same structure from ?group=None plus one call per VIOS, keeping whichever
  # answer. No-op once the collection works again.
  if ( ref($conf) ne "HASH" ) {
    my $xf_list;
    eval { $xf_list = callAPI("rest/api/uom/ManagedSystem/$uid/VirtualIOServer?group=None"); };
    if ( ref($xf_list) eq "HASH" ) {
      my @xf_uuids;
      my $xf_single = $xf_list->{'entry'}{'content'}{'VirtualIOServer:VirtualIOServer'};
      if ( ref($xf_single) eq "HASH" && defined $xf_single->{'PartitionUUID'}{'content'} ) {
        push( @xf_uuids, $xf_single->{'PartitionUUID'}{'content'} );
      }
      else {
        foreach my $xf_id ( keys %{ $xf_list->{'entry'} } ) {
          next if ( $xf_id eq "content" );
          my $xf_entry = $xf_list->{'entry'}{$xf_id}{'content'}{'VirtualIOServer:VirtualIOServer'};
          next if ( ref($xf_entry) ne "HASH" );
          push( @xf_uuids, $xf_entry->{'PartitionUUID'}{'content'} )
            if ( defined $xf_entry->{'PartitionUUID'}{'content'} );
        }
      }
      my $xf_rebuilt = { 'entry' => {} };
      my $xf_ok = 0;
      foreach my $xf_uuid (@xf_uuids) {
        my $xf_vios;
        eval { $xf_vios = callAPI("rest/api/uom/ManagedSystem/$uid/VirtualIOServer/$xf_uuid"); };
        my $xf_lp = ( ref($xf_vios) eq "HASH" ) ? $xf_vios->{'content'}{'VirtualIOServer:VirtualIOServer'} : undef;
        if ( ref($xf_lp) eq "HASH" ) {
          $xf_rebuilt->{'entry'}{$xf_uuid}{'content'}{'VirtualIOServer:VirtualIOServer'} = $xf_lp;
          $xf_ok++;
        }
        else {
          error("xoruxfork: VIOS collection failed for $uid and VIOS $xf_uuid also failed on its own, skipped");
        }
      }
      if ( $xf_ok > 0 ) {
        rest_api_log("xoruxfork: VIOS collection failed for $uid, recovered $xf_ok VIOS individually");
        $conf = $xf_rebuilt;
      }
    }
  }

