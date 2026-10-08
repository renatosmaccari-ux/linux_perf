# topology — the dependency map's data pipeline

Installed at `$INPUTDIR/topology`. Four independent sources feed one graph;
whatever is missing is skipped, so a fresh install draws an empty map and says
so rather than failing.

```
data/data.db (both products) --bin/topo-db.py--------------------------------+
data/Server-*/ (Power)       --bin/topo-inventory.py--> facts/inventory.csv -+
collectors/ (unix,windows)   -------------------------> facts/**/*.csv ------+--> bin/topo-build.py --> topologia.json
GUI upload (csv, xlsx)       -------------------------> uploads/* -----------+
```

## What the products already collected

`data/data.db` is the normalised inventory both products keep, and it already
is a graph. Reading it covers every platform they support at once — VMware,
oVirt, Nutanix, XenServer, Hyper-V, Linux, OracleVM, Proxmox, Kubernetes, AWS,
Azure, GCloud, plus STOR2RRD's storages and SAN/LAN switches — and stays
correct when a collector changes its directory layout.

| table | what it gives the map |
|---|---|
| `object_items` / `objects` | one row per monitored item, with `hw_type` and `subsystem` |
| `item_relations` | parent → child: vCenter › datacenter › cluster › ESXi › VM |
| `item_properties` | whatever the collector recorded: IP, OS, state, model |
| `agent_relations` | **which items have an agent inside them** |
| `hw_types` | the platform catalogue |

Subsystems are classified before anything is drawn:

- **machines** (`VM`, `SERVER`, `ESXI`, `HOST`, `NODE`, `CMCSERVER`…) → nodes
- **groupers** (`VCENTER`, `CLUSTER`, `DATACENTER`, `DOMAIN`, `STORAGE`, `SAN`…)
  → nodes, drawn as the parent
- **artefacts** (`DATASTORE`, `VOLUME`, `DISK`, `*_NIC`, `POD`, `S2D_*`…) →
  skipped, and relations through them go with them

Without that split, one datastore and every virtual disk would outnumber the
hosts and bury the dependencies.

**Agent enrichment.** A VM seen only from its hypervisor and the same VM with an
agent inside are two rows in the database — one under `VMWARE/VM`, one under
`LINUX/SERVER`. They fuse into a single node (same label, same IP), and
`agent_relations` sets `ag: true` on it, so the map distinguishes a host that is
merely visible from one that is actually instrumented.

Both databases are read when the products sit side by side: `$INPUTDIR/data`
first, then a sibling `lpar2rrd/` or `stor2rrd/` installation. Edges carry
`lpar2rrd` or `stor2rrd` as their origin. The file is opened **read-only with a
short timeout** — the collectors write to it while this runs, and a locked or
half-written database returns an empty result rather than failing the cycle.

The two products differ in two places, both handled: LPAR2RRD keeps items in
`object_items` and STOR2RRD in `objects`; LPAR2RRD names the platform label
column `label` and STOR2RRD `hw_label`.

| directory | what it holds |
|---|---|
| `bin/` | the database reader, the Power extractor, the matcher, the builder, and the collection item |
| `cgi/` | the upload page served as `…-cgi/topology.sh` |
| `collectors/unix`, `collectors/windows` | the inventory kits, run from this host |
| `facts/` | what the pipeline produced; safe to delete, rebuilt next cycle |
| `uploads/` | the baseline a person maintains, dropped in from the GUI |

## When it runs

LPAR2RRD executes every `bin/user_script*.sh` at the end of `load.sh`, so
`bin/user_script_topology.sh` needs no patching of the product. STOR2RRD has no
such hook and gets one call inserted at the end of its `load.sh`.

Each cycle re-reads the inventory, rebuilds the graph, and publishes it to
`html/` and `www/` — but only if the result parses as JSON, so a failed run
leaves the previous map in place.

## The three sources

**Product inventory.** `topo-inventory.py` walks `data/Server-*/…/CONFIG.json`
and writes one row per LPAR plus one per frame: model, serial, IP, state,
processors, memory, disks, filesystems, LAN/SAN/SAS aliases. It supplies the
frame → LPAR relationships nothing else knows.

**Baseline.** Spreadsheets and CSVs imported from the map's own panel
(*Inventário › Importar planilha ou CSV*) or from the *Topologia: dados* page.
Column names are matched in Portuguese or English; every sheet of a workbook is
read. Recognised: `Hostname`, `IP Address`, `Environment`, `Location`,
`Function`, `Operation Systems`, `Cluster/Physical Host`, `Manufacturer`,
`Status`.

`.xlsx` needs `openpyxl` and `.xls` needs `xlrd`; without the module the file
is skipped with a message naming it and saying to save as `.xlsx` or CSV — the
other files in the same run still import. Nothing raises.

The import lives **inside the map**: the panel has an Inventário section whose
button opens a dialog, posts the file to the CGI, and reloads once the rebuild
answers, so enriching the data never means leaving the graph. The page fetches
`topologia.json` with a changing query parameter, because after an import a
cached copy would show the previous map.

**Observed connections.** The collector kits emit
`categoria,escopo,chave,valor` rows; the builder reads the `conexao` and `meta`
categories from `facts/conexoes/*.csv`, named `<host>_conexoes.csv`.

## Merge rules

Hosts are matched case-insensitively, without the domain, and by IP — so the
same machine seen as `srv01`, `SRV01.corp` and `10.0.0.5` stays one node. The
first non-empty value wins, and the sources run **collectors → baseline →
inventory**, so an observed fact beats a hand-maintained sheet. The inventory
runs last because it matches against nodes the other two already created.

`lpar2rrd.py` does that matching. It fuses the up-to-two rows per
(frame, LPAR) — HMC config and agent data — resolves the same LPAR appearing on
several frames from LPM history (Running wins, then the most complete record),
and binds each LPAR to a node by the strongest criterion available:

| strength | criterion |
|---|---|
| 4 | frame serial + `lpar_id`, as the AIX collection itself reported them |
| 3 | hostname from the agent |
| 2 | IP |
| 1 | `lpar_name` without the frame suffix (`_E0BX`) or `_new`/`_old` |

A node takes at most one LPAR: the strongest match wins, ties go to Running,
and the losers are left unbound with `descartado_por` rather than silently
overwriting a live host. Each run logs the tally, e.g.
`casamento de LPARs: serial+lpar_id=1, hostname=1, lpar_name=1`.

Frame serial and `lpar_id` come from the collectors' `01_sistema`
(`frame,serial,frame_serial` and `lpar,id,lpar_id`), which is why every file
under `facts/` is read, not only the connection ones.

Every edge records how it was learnt:

| `ev` | | `cf` | |
|---|---|---|---|
| `servidor` | someone connected to our port | `listen` | the port is in LISTEN |
| `cliente` | we connected to their port | `porta` | a service port |
| `ambos` | both sides reported it | `efemera` | high-numbered, likely a source port |
| `lpar2rrd` | frame → LPAR from the product | `lpar2rrd` | |
| `baseline` | cluster/physical host from a sheet | `baseline` | |

## Uploads are data, never code

The CGI reduces the filename to a basename, keeps only `[A-Za-z0-9._-]`,
requires a `.csv`, `.txt` or `.xlsx` extension, and caps the size at 64 MB.
Rebuild runs through `system()` in list form, so no shell parses anything.
Contents are only ever read by the builder.

## Running the collectors

The kits under `collectors/` are unchanged apart from removing the target
lists and default HMC addresses of the environment they were written in. Copy
`servidores_unix.txt.exemplo` to `servidores_unix.txt`, fill it in, then:

```sh
cd topology/collectors/unix && ./run_all.sh -l servidores_unix.txt -j 6
cp coleta_*/06_conexoes/*.csv ../../facts/conexoes/
```
