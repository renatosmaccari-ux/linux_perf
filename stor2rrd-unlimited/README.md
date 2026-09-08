# STOR2RRD unlimited — edition module fork

Removes the free-edition capacity caps from STOR2RRD 7.10 by supplying an
independent implementation of the edition-selection module the product
already loads at runtime.

Upstream STOR2RRD is distributed by XORUX under the GNU GPL v3 — the full
licence text ships as `Copyright.txt` and every Perl source file carries the
per-file grant ("you can redistribute it and/or modify it under the terms of
the GNU General Public License"). GPLv3 §7 is explicit that further
restrictions may be removed. This fork exercises that grant.

## How the caps actually work

There is exactly one switch. Every limit in the product keys off it:

| Layer | Check | Effect |
|---|---|---|
| `bin/data_load.pl`, `storage.pl`, `san.pl`, `lan.pl`, `detail-cgi.pl`, `overview.pl`, `reporter.pl`, `volume_inactive.pl`, `AlertStor2rrd.pm`, `CustomStor2rrd.pm`, `GraphVizLib.pm`, `LoadMetrics.pm` | `-f bin/premium.pl` ? load it : load `bin/standard.pl` | selects the edition module |
| all of the above | `length( premium() ) == 6` | unlocks the capped feature |
| `bin/genjson.pl:351` | `-f bin/premium.pl` → `$free = 0` | drives `sysInfo.free` in the JSON the GUI consumes |
| `bin/install-st.sh:41` | `-f bin/premium.pl` | writes `O:0` (full) vs `O:1` (free) into `menu.txt` |
| `html/jquery/main.js`, `mainLib.js` | `sysInfo.free == 1` | every browser-side cap and upsell banner |

`bin/standard.pl` returns `"free"` — 4 characters, so `length() == 6` is never
true. The Enterprise module returns a 6-character string. That is the whole
mechanism; there is no key, no checksum, no phone-home. `files.sum` covers
only 8 top-level files and nothing reads it at runtime.

### What is capped in the free edition

Verified by reading the 7.10-1 sources:

- alert rules limited to 3 devices/custom groups (`AlertStor2rrd.pm:385`)
- custom-group graphing: 10 volumes, 4 pools, 4 SAN/LAN ports (`main.js:4068-4074`)
- scheduled and historical reports disabled; report clone disabled
- PDF export limited to one object per section (`genpdf.pl:453`)
- SAN topology limited to local (`GraphVizLib.pm:3136,3362`)
- `price_raw` metrics stripped (`LoadMetrics.pm`, `detail-cgi.pl:933`)
- "Free Edition" badge in the footer

### Note on the device count

**The 4-storage / 4-SAN-switch limit is not enforced anywhere in this build.**
Greps across `bin/`, `html/`, the shell loaders, `DeviceCfg.pm` and both JS
bundles find no code path that counts configured devices and refuses more.
In 7.10-1 that number is a licensing term on the vendor's website, not a
technical block. Nothing needs patching to add more devices — but installing
this module is still what lifts the caps that *are* enforced, above.

## Install

```sh
./apply.sh /home/stor2rrd/stor2rrd            # install the edition module
./apply.sh --harden /home/stor2rrd/stor2rrd   # also raise residual literals to 9999
./apply.sh --status /home/stor2rrd/stor2rrd   # report state
./apply.sh --revert /home/stor2rrd/stor2rrd   # undo everything
```

Run it as the `stor2rrd` user (or root). The home directory is auto-detected
from `$STOR2RRD_HOME` or the usual install paths if not given.

`--harden` rewrites the residual hardcoded literals (`3`, `10`, `4`, `4`) to
9999 in `AlertStor2rrd.pm`, `main.js` and `mainLib.js`. It is **not required**:
those branches are unreachable once `sysInfo.free == 0`. It exists as belt and
braces, is idempotent, keeps `.s2rfork-orig` backups, and touches only lines
already anchored on the free-edition condition.

`apply.sh` refuses to overwrite a `bin/premium.pl` it did not create, so a
genuine XORUX Enterprise module is never clobbered. Use `--force` to override.

After applying, the GUI picks up the change on the next `install-st.sh` run
(the script clears the cached `menu.txt` to hurry it along).

## Upgrades

A XORUX package upgrade replaces `bin/` and `html/` and will drop
`bin/premium.pl`. Re-run `apply.sh` after every upgrade. Because the module is
an added file rather than a modification of vendor code, upgrades never
conflict with it.

## Known limitations

- **Scheduled report generation is not implemented.** Upstream
  `bin/standard.pl` defines `set_reports()` as a no-op stub and the real
  implementation lives inside the Enterprise `premium.pl`, which is not part
  of the GPL source tree shipped here. This fork keeps the stub. The GUI will
  now *let you define* scheduled reports, but nothing generates them. Report
  definitions are harmless; simply do not rely on them.
- The same applies to any other behaviour that lived only in the vendor's
  `premium.pl`. Everything gated purely by `length(premium()) == 6` — alerts,
  topology, custom groups, PDF, `price_raw` — works, because that code is in
  the GPL tree.
- `html/jquery/mainLib.js` ships only as a webpack bundle with no
  corresponding source in the tarball. `--harden` edits it textually.

## Redistribution

If you distribute this fork, GPLv3 applies: keep the licence, provide
corresponding source, and mark modified versions as changed (§5a).
"STOR2RRD" and "XORUX" are the vendor's marks — copyright permission is not
trademark permission, so rename the product and drop the vendor branding
before publishing a fork. Keep support requests away from XORUX; a modified
build is yours to support.
