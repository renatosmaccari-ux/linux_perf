# XORUX unlimited — edition module fork

Removes the free-edition caps from **STOR2RRD** and **LPAR2RRD** by rewriting
the edition-selection module the product already loads at runtime.

Verified against STOR2RRD **7.10-1** and **8.08** and LPAR2RRD **8.08**.
`apply.sh` detects the product and layout and does the right thing for each.

The module is **derived from the one installed**, not copied from a fixed
file: only the return value of `premium()` changes, so every other subroutine
it exports survives. That matters — STOR2RRD's module exports `premium` alone,
LPAR2RRD's also exports `get_rperf_all`, `rperf_check`, `lpm`, `get_lpar_num`
and `lpm_find_files`, and a future version may export more.

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

### LPAR2RRD: a second gate

LPAR2RRD 8.08 caps hosts per platform in `HostCfg::getHostConnections`
(`HostCfg.pm:363-399`), and the platform names and paths there are
hex-escaped in the source. A host is dropped when

```perl
( length($prem) != 6 || !-f "$basedir/html/.<marker>" ) && $cntr > <limit>
```

so lifting the cap needs `premium()` at 6 characters **and** the marker file:

| Platform | Cap | Marker | Ships in free |
|---|---|---|---|
| IBM Power Systems (HMC) | 1 | `html/.p` | yes |
| IBM Power CMC | 1 | `html/.p` | yes |
| VMware (vCenter) | 1 | `html/.v` | yes |
| RHV (oVirt) | 4 | `html/.o` | **no** |
| Nutanix | 4 | `html/.n` | **no** |
| Openshift | 8 | `html/.t` | **no** |

Stock ships `.p` and `.v` only, so a fork that just flips `premium()` still
leaves RHV, Nutanix and Openshift capped. Measured with 3 HMC, 3 CMC, 3
vCenter, 6 RHV, 6 Nutanix and 10 Openshift hosts configured, calling the
product's own `getHostConnections`:

| | Power | CMC | VMware | RHV | Nutanix | Openshift |
|---|---|---|---|---|---|---|
| stock | 1 | 1 | 1 | 4 | 4 | 8 |
| `premium()` rewritten only | 3 | 3 | 3 | **4** | **4** | **8** |
| plus the markers | 3 | 3 | 3 | 6 | 6 | 10 |

`apply.sh` decodes the marker paths out of `HostCfg.pm` rather than hardcoding
them, so a version that adds a platform is picked up automatically, and it
records the ones it creates in `.xoruxfork-created` so `--revert` removes
exactly those and leaves the vendor's own `.p` and `.v` alone.

`getHostConnections` is what every collector calls — `power-json2db.pl`,
`nutanix-api2json.pl`, `ovirt-db2json.pl`, `kubernetes-json2db.pl`,
`proxmox-api2json.pl` and the rest — so a capped host is configurable in the
GUI and never collected.

### 8.x: same switch, different module

8.x replaced the `standard.pl` / `premium.pl` pair with a single module,
`bin/XoruxEdition.pm`, whose stock `premium()` also returns `"free"`. Every
gate is unchanged (`length( premium() ) == 6`); `bin/install-st.sh` now tests
it as `perl -MXoruxEdition -e 'print premium();' | wc -m -eq 6`. So on 8.x the
fork replaces that module instead of adding a file. The original is kept as
`XoruxEdition.pm.xoruxfork-orig` and restored by `--revert`.

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

## Vendor bugs (`--fix-vendor-bugs`, opt-in)

Defects in the stock product that have nothing to do with the free/Enterprise
split. Kept behind their own flag so the fork's scope stays legible; the
pre-patched packages include them.

**LPAR2RRD 8.08 — the admin menu's "IBM Power Systems" page is dead.**
`html/index.html` links to `hosts.sh?cmd=form&platform=ibm`, but `ibm` is not a
key of `%platforms` in `bin/host_cfg.pl`, so line 144 —

```perl
my $platform = exists $platforms{ $PAR{platform} } ? $PAR{platform} : "";  # drop unknown platforms
```

— rewrites it to `""`, and the `elsif ( $platform eq "ibm" )` that renders the
HMC/CMC tabs is unreachable. The request returns `cfgpage("")`: an empty host
table with `data-platform=""`, an empty cron hint, and a New button that does
nothing. Confirmed against a browser HAR from a live system: the call returns
200 with exactly that body. The fix adds `ibm` as a key, with no `pid` and no
`croncmd` — that branch only prints the tabs and returns, so giving it a `pid`
would produce a spurious second cron error.

The workaround is skipped on products without `bin/host_cfg.pl`, is idempotent,
and rolls itself back if the file compiled before the edit and not after.

## Pre-patched package

`build-package.sh` turns an original XORUX tarball into one with the fork
already applied, so the vendor's own `install.sh` / `update.sh` install it
directly — nothing to run afterwards:

```sh
./build-package.sh stor2rrd8.08.tar ./dist   # -> dist/stor2rrd-8.08-unlimited.tar
./build-package.sh lpar2rrd8.08.tar ./dist   # -> dist/lpar2rrd-8.08-unlimited.tar
tar xf stor2rrd-8.08-unlimited.tar && cd stor2rrd-8.08 && ./install.sh
```

The payload directory differs by product (`dist_storage` for STOR2RRD, `dist`
for LPAR2RRD) and so does the inner archive name; both are detected.

It detects the product and layout, patches the payload tree, drops the
`.xoruxfork-orig` backups and the revert manifest (the package *is* the fork),
adds `FORK-NOTICE.txt` marking the build as modified per GPLv3 §5(a), and
regenerates `files.sum`.

On 8.x the payload is an inner `stor2rrd.tar.Z` in classic LZW format. The
installer decompresses it with `uncompress(1)` and only falls back to
`gunzip(1)`, so a gzip stream named `.tar.Z` would break on any host with a
real `uncompress` — and `compress(1)` is missing from most build hosts.
`tools/lzw_compress.py` therefore writes the genuine format, including the
8-code padding on width changes and compress(1)'s dictionary-reset heuristic
(without it a 50 MB payload nearly triples). `build-package.sh` decompresses
what it just wrote and fails the build unless it matches byte for byte.

## Install in place

```sh
./apply.sh /home/stor2rrd/stor2rrd            # rewrite the edition module
./apply.sh --fix-vendor-bugs /home/lpar2rrd/lpar2rrd   # + vendor bug workarounds
./apply.sh --harden /home/stor2rrd/stor2rrd   # also raise residual literals to 9999
./apply.sh --status /home/stor2rrd/stor2rrd   # report state
./apply.sh --revert /home/stor2rrd/stor2rrd   # undo everything
```

Run it as the `stor2rrd` / `lpar2rrd` user (or root). The home directory is
auto-detected from `$XORUX_HOME`, `$STOR2RRD_HOME`, `$LPAR2RRD_HOME` or the
usual install paths if not given.

`--harden` rewrites the residual hardcoded literals to 9999 — the 8.x device
cap `$counter <= 4` in `DeviceCfg.pm`, the alert cap `$index < 4` in
`AlertStor2rrd.pm`, and the browser-side `3`, `3`, `10`, `4`, `4`, `4`, `4` in
`main.js` / `mainLib.js`. It is **not required**: every one of those branches
is unreachable once `premium()` returns 6 characters. It exists as belt and
braces, is idempotent, keeps `.xoruxfork-orig` backups, and rewrites only lines
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

The upgrade also replaces the `.xoruxfork-orig` baselines, so run `--revert`
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
