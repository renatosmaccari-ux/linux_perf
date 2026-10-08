#!/usr/bin/env python3
"""topo-db.py - read what LPAR2RRD and STOR2RRD actually collected.

Both products keep a normalised inventory in SQLite at data/data.db, and it
already is a graph: every monitored thing is a row, and parent/child rows say
what contains what. Reading it beats walking the file tree per platform,
because it covers all 21 platforms at once and stays correct when a collector
changes its directory layout.

  objects / object_items   one row per monitored item, with hw_type
                           (POWER, VMWARE, OVIRT, NUTANIX, XENSERVER, WINDOWS,
                           LINUX, AWS, AZURE, GCLOUD, STORAGE, SAN, LAN, ...)
                           and subsystem (VM, ESXI, HOST, SERVER, CLUSTER, ...)
  item_relations           parent -> child: datacenter > cluster > esxi > vm
  item_properties          whatever the collector recorded for that item
  agent_relations          which agent enriches which item - the difference
                           between a VM seen only from the hypervisor and one
                           with an agent inside it
  hw_types                 the platform catalogue, with display labels

The two products differ in one place: LPAR2RRD puts items in object_items and
keeps objects for the containers, while STOR2RRD puts everything in objects.
Both are handled.

Usage as a module:  import topo_db; dados = topo_db.ler("/path/data.db")
Standalone:         topo-db.py <data.db>   (prints a summary)
"""

import os
import sqlite3
import sys

# Subsystems that are an addressable system - these become nodes.
MAQUINAS = {
    "VM", "SERVER", "ESXI", "HOST", "NODE", "CMCSERVER", "LPAR", "INSTANCE",
    "VIRTUALMACHINE", "CLUSTER_VM", "GUEST",
}

# Subsystems that contain machines - also nodes, drawn as the parent.
AGRUPADORES = {
    "VCENTER", "CLUSTER", "DATACENTER", "POOL", "DOMAIN", "WINDOWS_CLUSTER",
    "HMC", "CMC", "CMCCONSOLE", "CMCPOOL", "STORAGE", "SAN", "LAN", "REGION",
    "SUBSCRIPTION", "PROJECT", "ZONE",
}

# Everything else is an artefact of a machine (a disk, a port, a datastore,
# a pod) and would bury the map without adding a dependency.
ARTEFATOS_SUFIXO = ("_FOLDER", "_NIC", "_PD", "_DISK", "_GROUP",
                    "_CONTAINER", "_VOLUME")
ARTEFATOS = {
    "DATASTORE", "VOLUME", "DISK", "POD", "PODS", "CONTAINER", "SRI", "HEA",
    "SAS", "RESOURCEPOOL", "STORAGE_POOL", "VIRTUAL_DISK", "PHYSICAL_DISK",
    "VOLUME_GROUP", "S2D_VOLUME", "S2D_PD", "STORAGE_DOMAIN",
    "STORAGE_CONTAINER", "HOST_NIC", "VM_NIC",
}

# hw_type -> the platform name the map uses. POWER is left empty on purpose:
# the Power tree is read in far more detail by topo-inventory.py, and a
# coarser value here would win by arriving first.
PLATAFORMA = {
    "POWER": "", "VMWARE": "vmware", "XENSERVER": "xen", "OVIRT": "ovirt",
    "NUTANIX": "nutanix", "WINDOWS": "windows", "LINUX": "linux",
    "AWS": "cloud", "AZURE": "cloud", "GCLOUD": "cloud", "CLOUDSTACK": "cloud",
    "ORACLEVM": "oraclevm", "PROXMOX": "proxmox", "FUSIONCOMPUTE": "fusion",
    "KUBERNETES": "k8s", "OPENSHIFT": "k8s", "DOCKER": "docker",
    "SOLARIS": "solaris", "STORAGE": "storage", "SAN": "san", "LAN": "lan",
}

# Property names differ per collector; these are the ones seen for each
# graph field, best first. Unknown properties are carried through untouched
# so nothing collected is silently dropped.
PROPRIEDADES = {
    "ips": ("ip", "ipaddress", "ip_address", "address", "management_ip",
            "mgmt_ip", "guest_ip"),
    "os":  ("os", "operating_system", "guest_os", "guestos", "os_version",
            "guest_full_name", "product"),
    "st":  ("state", "status", "power_state", "powerstate", "runtime_state"),
    "mod": ("model", "machine_type", "hw_model", "product_name"),
    "chs": ("serial", "serial_number", "physical_host", "host"),
    "fn":  ("annotation", "description", "note", "notes", "comment"),
}


def classe(subsystem):
    s = (subsystem or "").upper()
    if s in MAQUINAS:
        return "maquina"
    if s in AGRUPADORES:
        return "agrupador"
    if s in ARTEFATOS or s.endswith(ARTEFATOS_SUFIXO):
        return "artefato"
    return "artefato"


def _tabelas(cur):
    cur.execute("SELECT name FROM sqlite_master WHERE type='table'")
    return set(r[0] for r in cur.fetchall())


def _colunas(cur, tabela):
    try:
        cur.execute("PRAGMA table_info(%s)" % tabela)
    except sqlite3.Error:
        return set()
    return set(r[1] for r in cur.fetchall())


def ler(caminho):
    """-> {"itens": {item_id: {...}}, "relacoes": [(pai, filho)],
            "erro": str or None}. Never raises: a locked or half-written
    database must not take a collection cycle down with it."""
    vazio = {"itens": {}, "relacoes": [], "erro": None}
    if not caminho or not os.path.isfile(caminho):
        return vazio

    try:
        # read-only and non-blocking: the collectors write to this file while
        # we read, and we must never hold them up or alter anything
        uri = "file:%s?mode=ro&immutable=0" % caminho.replace("?", "%3f")
        con = sqlite3.connect(uri, uri=True, timeout=5)
    except sqlite3.Error as e:
        vazio["erro"] = str(e)
        return vazio

    try:
        con.row_factory = sqlite3.Row
        cur = con.cursor()
        tabelas = _tabelas(cur)

        # LPAR2RRD keeps items in object_items; STOR2RRD in objects
        tab_itens = "object_items" if "object_items" in tabelas else "objects"
        if tab_itens not in tabelas:
            vazio["erro"] = "sem tabela de itens"
            return vazio
        cols = _colunas(cur, tab_itens)
        if "item_id" not in cols:
            vazio["erro"] = "%s sem item_id" % tab_itens
            return vazio

        # LPAR2RRD names the column label, STOR2RRD hw_label
        rotulos_hw = {}
        if "hw_types" in tabelas:
            cols_hw = _colunas(cur, "hw_types")
            col = "label" if "label" in cols_hw else (
                "hw_label" if "hw_label" in cols_hw else "")
            if col:
                cur.execute("SELECT hw_type, %s FROM hw_types" % col)
                rotulos_hw = dict((r[0], r[1]) for r in cur.fetchall())

        # A coluna de rotulo tem nome diferente em cada produto: label no
        # LPAR2RRD, hw_label no STOR2RRD. Pedir "label" fixo fazia a leitura de
        # um banco do STOR2RRD morrer inteira com "no such column: label", de
        # modo que nenhum storage entrava no grafo.
        col_rot = "label" if "label" in cols else (
            "hw_label" if "hw_label" in cols else "")
        campos = ["item_id"]
        campos += [c for c in (col_rot, "hw_type", "subsystem") if c]
        campos += [c for c in ("object_id", "item_timestamp") if c in cols]
        cur.execute("SELECT %s FROM %s" % (", ".join(campos), tab_itens))

        def pega(linha, nome):
            try:
                return linha[nome]
            except (IndexError, KeyError):
                return None

        itens = {}
        for r in cur.fetchall():
            sub = pega(r, "subsystem") or ""
            itens[r["item_id"]] = {
                "id": r["item_id"],
                "label": (pega(r, col_rot) if col_rot else None) or r["item_id"],
                "hw_type": pega(r, "hw_type") or "",
                "hw_label": rotulos_hw.get(pega(r, "hw_type") or "", ""),
                "subsystem": sub,
                "classe": classe(sub),
                "object_id": r["object_id"] if "object_id" in campos else "",
                "visto_em": r["item_timestamp"] if "item_timestamp" in campos else "",
                "agente": False,
                "props": {},
            }

        if "item_properties" in tabelas:
            cur.execute("SELECT item_id, property_name, property_value "
                        "FROM item_properties")
            for r in cur.fetchall():
                it = itens.get(r["item_id"])
                if it is not None and r["property_value"] not in (None, ""):
                    it["props"][(r["property_name"] or "").lower()] = \
                        str(r["property_value"])

        # the agent is what turns a VM seen from outside into an enriched host
        if "agent_relations" in tabelas:
            cur.execute("SELECT item_id FROM agent_relations")
            for r in cur.fetchall():
                if r["item_id"] in itens:
                    itens[r["item_id"]]["agente"] = True

        relacoes = []
        if "item_relations" in tabelas:
            cur.execute("SELECT parent, child FROM item_relations")
            relacoes = [(r["parent"], r["child"]) for r in cur.fetchall()
                        if r["parent"] and r["child"]]

        return {"itens": itens, "relacoes": relacoes, "erro": None}

    except sqlite3.Error as e:
        vazio["erro"] = str(e)
        return vazio
    finally:
        try:
            con.close()
        except Exception:
            pass


def valor(item, campo):
    """First recognised property for a graph field."""
    for nome in PROPRIEDADES.get(campo, ()):
        v = item["props"].get(nome)
        if v:
            return v
    return ""


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = ler(sys.argv[1])
    if d["erro"]:
        sys.exit("topo-db: %s" % d["erro"])
    from collections import Counter
    por_classe = Counter(i["classe"] for i in d["itens"].values())
    por_hw = Counter("%s/%s" % (i["hw_type"], i["subsystem"])
                     for i in d["itens"].values())
    print("itens    : %d  (%s)" % (
        len(d["itens"]),
        ", ".join("%s=%d" % kv for kv in sorted(por_classe.items()))))
    print("com agente: %d" % sum(1 for i in d["itens"].values() if i["agente"]))
    print("relacoes : %d" % len(d["relacoes"]))
    for k, n in por_hw.most_common(25):
        print("   %-34s %d" % (k, n))
    return 0


if __name__ == "__main__":
    sys.exit(main())
