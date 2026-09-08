# STOR2RRD unlimited — edition module fork

Removes the free-edition capacity caps from STOR2RRD by supplying an
independent implementation of the edition-selection module the product
already loads at runtime.

Verified against **7.10-1** and **8.08**. `apply.sh` detects which layout is
installed and does the right thing for each.

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

### 8.x: same switch, different module

8.x replaced the `standard.pl` / `premium.pl` pair with a single module,
`bin/XoruxEdition.pm`, whose stock `premium()` also returns `"free"`. Every
gate is unchanged (`length( premium() ) == 6`); `bin/install-st.sh` now tests
it as `perl -MXoruxEdition -e 'print premium();' | wc -m -eq 6`. So on 8.x the
fork replaces that module instead of adding a file. The original is kept as
`XoruxEdition.pm.s2rfork-orig` and restored by `--revert`.

### What is capped in the free edition

Verified by reading the 7.10-1 sources:

- alert rules limited to 3 devices/custom groups (`AlertStor2rrd.pm:385`)
- custom-group graphing: 10 volumes, 4 pools, 4 SAN/LAN ports (`main.js:4068-4074`)
- scheduled and historical reports disabled; report clone disabled
- PDF export limited to one object per section (`genpdf.pl:453`)
- SAN topology limited to local (`GraphVizLib.pm:3136,3362`)
- `price_raw` metrics stripped (`LoadMetrics.pm`, `detail-cgi.pl:933`)
- "Free Edition" badge in the footer

### The device count cap — 8.x only

8.x added the cap that 7.x never implemented, and it sits on the **collection**
path rather than in the GUI. That is why a device can be added and saved but
never produces data:

- `DeviceCfg::getActiveDeviceList` (`DeviceCfg.pm:1264`) sorts the enabled
  devices of a class alphabetically and splits them with `if ( $counter <= 4 )`
  into `goon` and `byebye`. The cap is **per class**, so 4 STORAGE + 4 SAN +
  4 LAN. (`goon` is written but never read; only `byebye` is consumed.)
- `DeviceCfg::getLicencedDevices` (`:1375`) drops every `byebye` device when
  `length($prem) != 6`.
- `DeviceConnTest::json_to_line` (`:73`) and `json_to_line_san` (`:175`) do the
  same when building the device lines that drive collection. `configuration.pl:530`
  calls them, so a `byebye` device never reaches a `load_*perf.sh` run at all.
- `ping_test.pl:253` iterates `getLicencedDevices`, so capped devices are not
  even connection-tested.

The GUI text is inconsistent with the code: `main.js` warns that "a maximum of
8 active storage devices are allowed" while the backend enforces 4. The
backend is authoritative.

Measured on an 8.08 tree with 7 STORAGE, 6 SAN and 6 LAN devices configured,
calling the product's own `getLicencedDevices`:

| | STORAGE | SAN | LAN |
|---|---|---|---|
| stock (`premium()` = `"free"`) | 4 of 7 | 4 of 6 | 4 of 6 |
| fork (`premium()` = `"forked"`) | 7 of 7 | 6 of 6 | 6 of 6 |

**On 7.10-1 no such cap exists.** All 14 `length($prem)` sites (4 of them
commented out), all 28 `premium.pl` decision points, all 13 `sysInfo.free` and
7 `sysInfo.basename` uses in the bundles, `DeviceCfg::getConfiguredDevices`
and the 739 lines of `load.sh` were inspected: nothing counts devices. In the
7.x line that number is a licensing term, not a technical block.

## Install

```sh
./apply.sh /home/stor2rrd/stor2rrd            # install the edition module
./apply.sh --harden /home/stor2rrd/stor2rrd   # also raise residual literals to 9999
./apply.sh --status /home/stor2rrd/stor2rrd   # report state
./apply.sh --revert /home/stor2rrd/stor2rrd   # undo everything
```

Run it as the `stor2rrd` user (or root). The home directory is auto-detected
from `$STOR2RRD_HOME` or the usual install paths if not given.

`--harden` rewrites the residual hardcoded literals to 9999 — the 8.x device
cap `$counter <= 4` in `DeviceCfg.pm`, the alert cap `$index < 4` in
`AlertStor2rrd.pm`, and the browser-side `3`, `3`, `10`, `4`, `4`, `4`, `4` in
`main.js` / `mainLib.js`. It is **not required**: every one of those branches
is unreachable once `premium()` returns 6 characters. It exists as belt and
braces, is idempotent, keeps `.s2rfork-orig` backups, and rewrites only lines
anchored on the free-edition condition itself. Patterns that do not apply to
the installed version simply do not match.

On 7.x `apply.sh` refuses to overwrite a `bin/premium.pl` it did not create, so
a genuine XORUX Enterprise module is never clobbered; use `--force` to
override. On 8.x the stock `XoruxEdition.pm` is always backed up first.

After applying, the GUI picks up the change on the next `install-st.sh` run
(the script clears the cached `menu.txt` to hurry it along).

## Upgrades

A XORUX package upgrade replaces `bin/` and `html/`, dropping `bin/premium.pl`
(7.x) or restoring the stock `bin/XoruxEdition.pm` (8.x). Re-run `apply.sh`
after every upgrade; `--status` tells you whether it is still in place.

The upgrade also replaces the `.s2rfork-orig` baselines, so run `--revert`
*before* upgrading if you want the backups to stay meaningful.

## Known limitations

- **Scheduled report generation is not implemented.** On 7.x upstream
  `bin/standard.pl` defines `set_reports()` as a no-op stub and the real
  implementation lives inside the Enterprise `premium.pl`, which is not part
  of the GPL source tree shipped here; this fork keeps the stub. 8.x moved
  that code to a separate `bin/reporter-premium.pl` (`reporter.pl:274`) which
  is likewise absent. The GUI will now *let you define* scheduled reports, but
  nothing generates them. Report definitions are harmless; simply do not rely
  on them.
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
