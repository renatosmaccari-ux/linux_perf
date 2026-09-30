# topology — the dependency map's data pipeline

Installed at `$INPUTDIR/topology`. Three independent sources feed one graph;
whatever is missing is skipped, so a fresh install draws an empty map and says
so rather than failing.

```
data/ (LPAR2RRD/STOR2RRD)  --bin/topo-inventory.py-->  facts/inventory.csv  --+
collectors/ (unix,windows) ------------------------->  facts/conexoes/*.csv --+--> bin/topo-build.py --> topologia.json
GUI upload (csv, xlsx) ----------------------------->  uploads/*            --+
```

| directory | what it holds |
|---|---|
| `bin/` | the extractor, the builder, and the collection item |
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

**Baseline.** Spreadsheets and CSVs uploaded through *Topologia: dados*. Column
names are matched in Portuguese or English; every sheet of a workbook is read.
Recognised: `Hostname`, `IP Address`, `Environment`, `Location`, `Function`,
`Operation Systems`, `Cluster/Physical Host`, `Manufacturer`, `Status`.
`.xlsx` needs `openpyxl`; without it the file is skipped with a warning, never
an exception.

**Observed connections.** The collector kits emit
`categoria,escopo,chave,valor` rows; the builder reads the `conexao` and `meta`
categories from `facts/conexoes/*.csv`, named `<host>_conexoes.csv`.

## Merge rules

Hosts are matched case-insensitively, without the domain, and by IP — so the
same machine seen as `srv01`, `SRV01.corp` and `10.0.0.5` stays one node. The
first non-empty value wins, and the sources run inventory → connections →
baseline, so collected fact beats hand-maintained sheet.

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
