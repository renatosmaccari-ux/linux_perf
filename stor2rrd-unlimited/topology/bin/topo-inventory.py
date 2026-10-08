#!/usr/bin/env python
# -*- coding: utf-8 -*-
#
# inventario_lpar2rrd.py
#
# Extrai inventario (servidor fisico, LPARs, CPU, memoria, storage,
# filesystems, LAN/SAN/SAS) da base de dados do LPAR2RRD e gera um CSV
# para enriquecer o grafo de topologia.
#
# Compativel com Python 2.7 e Python 3.x
#

from __future__ import print_function

import os
import re
import glob
import json
import csv
import sys
from collections import defaultdict

#
# Caminhos vinham fixos em /home/lpar2rrd. Agora sao parametros, para o
# script rodar como item de coleta em qualquer instalacao:
#   topo-inventory.py [<dir de dados>] [<csv de saida>]
# ou via ambiente (INPUTDIR e o que o proprio LPAR2RRD ja exporta).
#
_HOME = os.environ.get("INPUTDIR") or "/home/lpar2rrd/lpar2rrd"

BASE = (sys.argv[1] if len(sys.argv) > 1
        else os.environ.get("TOPO_DATA") or os.path.join(_HOME, "data"))

OUTPUT = (sys.argv[2] if len(sys.argv) > 2
          else os.environ.get("TOPO_OUT")
          or os.path.join(_HOME, "topology", "facts", "inventory.csv"))

PY3 = sys.version_info[0] >= 3


def open_text(path):
    #
    # No Python 3, arquivos da coleta do LPAR2RRD com encoding misto
    # interrompem a leitura com UnicodeDecodeError; errors="replace"
    # evita perder o LPAR inteiro por um caractere invalido.
    #
    # encoding explicito: sem ele o codec vem do locale, e sob o cron (sem
    # LANG) isso e ASCII - cada acentuado virava um caractere de substituicao
    # e o nome do host chegava corrompido ao grafo, sem erro nenhum.
    if PY3:
        return open(path, "r", encoding="utf-8", errors="replace")
    return open(path, "r")


def read_file(path):
    try:
        f = open_text(path)
        data = f.read()
        f.close()
        return data.strip()
    except:
        return ""


def first_line(path):
    data = read_file(path)
    if not data:
        return ""
    return data.splitlines()[0].strip()


def read_json(path):
    try:
        f = open_text(path)
        data = json.load(f)
        f.close()
        return data
    except:
        return {}


def cfg_val(value):
    #
    # O REST da HMC empacota valores no formato {"content": "x"}.
    # Normaliza para o valor puro, aceitando tambem strings simples.
    #
    if isinstance(value, dict):
        return value.get("content", "")
    return value


def normalize_row(row):
    #
    # Ultima linha de defesa antes de gravar o CSV: nenhum campo
    # pode sair como dict/None (repr de dict estragaria o join).
    #
    for key in row:
        if isinstance(row[key], dict):
            row[key] = row[key].get("content", "")
        elif row[key] is None:
            row[key] = ""
    return row


def parse_kv_line(line):
    result = {}

    #
    # cpu.cfg pode vir separado por virgula (saida do lssparcfg) ou
    # por dois pontos; escolhe o separador que render mais pares.
    #
    for sep in (",", ":"):
        attempt = {}

        for item in line.strip().split(sep):
            if "=" in item:
                key, value = item.split("=", 1)
                attempt[key.strip()] = value.strip()

        if len(attempt) > len(result):
            result = attempt

    return result


def read_cpu_cfg(path):
    result = {}

    if not os.path.isfile(path):
        return result

    try:
        f = open_text(path)

        for line in f:
            line = line.strip()

            if not line:
                continue

            item = parse_kv_line(line)

            name = item.get("lpar_name")

            #
            # Formato alternativo: nome da LPAR como primeiro campo
            # sem "=" (ex.: "lpar2:lpar_id=2:curr_procs=4").
            #
            if not name and ":" in line:
                head = line.split(":")[0].strip()
                if head and "=" not in head:
                    name = head

            if name:
                result[name] = item

        f.close()

    except:
        pass

    return result


def read_id(path):
    result = []

    if not os.path.isfile(path):
        return result

    try:
        f = open_text(path)

        for line in f:
            line = line.strip()

            if not line:
                continue

            parts = line.split(":")

            if len(parts) >= 2:
                result.append({
                    "disk": parts[0],
                    "wwid": parts[1]
                })

        f.close()

    except:
        pass

    return result


def read_fs(path):
    result = []

    if not os.path.isfile(path):
        return result

    try:
        f = open_text(path)

        for line in f:
            line = line.strip()

            if not line:
                continue

            #
            # FS.csv pode estar separado por virgula (formato CSV do
            # agente) ou com espacos (saida do df -P).
            #
            parts = line.split(",")

            if len(parts) < 6:
                parts = line.split()

            if len(parts) < 6:
                continue

            #
            # Ignora cabecalho do df
            #
            if parts[0].strip() == "Filesystem":
                continue

            result.append({
                "device": parts[0],
                "size": parts[1],
                "used": parts[2],
                "free": parts[3],
                "used_pct": parts[4],
                "mount": " ".join(parts[5:])
            })

        f.close()

    except:
        pass

    return result


def read_aliases(path):
    result = []

    data = read_json(path)

    if not isinstance(data, dict):
        return result

    for location in data:

        item = data[location]

        #
        # Aceita tanto {"loc": {...}} quanto {"loc": [ {...}, ... ]}
        #
        if isinstance(item, list):
            candidates = item
        elif isinstance(item, dict):
            candidates = [item]
        else:
            continue

        for entry in candidates:

            if not isinstance(entry, dict):
                continue

            result.append({
                "location": location,
                "alias": cfg_val(entry.get("alias", "")),
                "uuid": cfg_val(entry.get("UUID", "")),
                "partition": cfg_val(entry.get("partition", "")),
                "wwpn": cfg_val(entry.get("wwpn", ""))
            })

    return result


def read_phyp(path):
    result = {}

    data = read_json(path)

    try:
        lpars = data["systemUtil"]["utilSample"]["lparsUtil"]
    except:
        return result

    if not isinstance(lpars, list):
        return result

    for item in lpars:

        name = item.get("name")

        if name:
            result[name] = item

    return result


def get_physical_info(config):

    result = {
        "name": "",
        "machine_type": "",
        "model": "",
        "serial": "",
        "uuid": ""
    }

    info = config.get("info", {})

    if not isinstance(info, dict):
        return result

    for key in info:

        item = info[key]

        if not isinstance(item, dict):
            continue

        result["name"] = cfg_val(item.get("name", ""))

        result["machine_type"] = cfg_val(item.get("MachineType", ""))

        result["model"] = cfg_val(item.get("Model", ""))

        result["serial"] = cfg_val(item.get("SerialNumber", ""))

        result["uuid"] = cfg_val(item.get("UUID", ""))

        #
        # Preferimos o servidor 8408/P8 quando existir
        #
        if str(result["machine_type"]).startswith("8408"):
            break

    return result


def get_lpar_config(config):

    data = config.get("lpar", {})

    if isinstance(data, dict):
        return data

    return {}


def extract_server():

    rows = []

    pattern = os.path.join(
        BASE,
        "Server-*",
        "*",
        "CONFIG.json"
    )

    configs = glob.glob(pattern)

    print("CONFIG.json encontrados: %d" % len(configs))

    if not configs:
        print("AVISO: nenhum arquivo no padrao %s" % pattern)
        print("AVISO: confira a variavel BASE (%s)" % BASE)

    for config_file in configs:

        hmc_dir = os.path.dirname(config_file)
        server_dir = os.path.dirname(hmc_dir)

        server_id = os.path.basename(server_dir)
        hmc_ip = os.path.basename(hmc_dir)

        config = read_json(config_file)

        physical = get_physical_info(config)
        lpar_config = get_lpar_config(config)

        cpu_cfg = read_cpu_cfg(
            os.path.join(hmc_dir, "cpu.cfg")
        )

        phyp = read_phyp(
            os.path.join(
                hmc_dir,
                "iostat",
                "ltm_phyp.json"
            )
        )

        cpu_mhz = first_line(
            os.path.join(hmc_dir, "cpu_mhz.txt")
        )

        agent = first_line(
            os.path.join(hmc_dir, "agent.cfg")
        )

        cpu_pool = first_line(
            os.path.join(
                hmc_dir,
                "cpu-pools-mapping.txt"
            )
        )

        #
        # LAN
        #
        lan = read_aliases(
            os.path.join(
                hmc_dir,
                "LAN_aliases.json"
            )
        )

        #
        # SAN
        #
        san = read_aliases(
            os.path.join(
                hmc_dir,
                "SAN_aliases.json"
            )
        )

        #
        # SAS
        #
        sas = read_aliases(
            os.path.join(
                hmc_dir,
                "SAS_aliases.json"
            )
        )

        lan_by_lpar = defaultdict(list)
        san_by_lpar = defaultdict(list)
        sas_by_lpar = defaultdict(list)

        for item in lan:
            lan_by_lpar[item["partition"]].append(item)

        for item in san:
            san_by_lpar[item["partition"]].append(item)

        for item in sas:
            sas_by_lpar[item["partition"]].append(item)

        #
        # Diretórios das LPARs
        #
        children = glob.glob(
            os.path.join(hmc_dir, "*")
        )

        found = {}

        for lpar_dir in children:

            if not os.path.isdir(lpar_dir):
                continue

            lpar_name = os.path.basename(lpar_dir)

            if lpar_name == "iostat":
                continue

            files = [
                "hostname.txt",
                "IP.txt",
                "cpu.txt",
                "FS.csv",
                "id.txt"
            ]

            has_data = False

            for filename in files:

                if os.path.isfile(
                    os.path.join(lpar_dir, filename)
                ):
                    has_data = True
                    break

            if not has_data:
                continue

            found[lpar_name] = True

            cfg = cpu_cfg.get(lpar_name, {})
            cfg_json = lpar_config.get(lpar_name, {})
            runtime = phyp.get(lpar_name, {})

            processor = runtime.get(
                "processor", {}
            )

            memory = runtime.get(
                "memory", {}
            )

            hostname = first_line(
                os.path.join(
                    lpar_dir,
                    "hostname.txt"
                )
            )

            ip = first_line(
                os.path.join(
                    lpar_dir,
                    "IP.txt"
                )
            )

            #
            # Storage
            #
            disks = read_id(
                os.path.join(
                    lpar_dir,
                    "id.txt"
                )
            )

            disk_names = ";".join(
                [x["disk"] for x in disks]
            )

            disk_wwids = ";".join(
                [x["wwid"] for x in disks]
            )

            #
            # Filesystems
            #
            filesystems = read_fs(
                os.path.join(
                    lpar_dir,
                    "FS.csv"
                )
            )

            fs_mounts = ";".join(
                [x["mount"] for x in filesystems]
            )

            #
            # LAN
            #
            lan_items = lan_by_lpar.get(
                lpar_name,
                []
            )

            lan_aliases = ";".join(
                [x["alias"] for x in lan_items]
            )

            #
            # SAN
            #
            san_items = san_by_lpar.get(
                lpar_name,
                []
            )

            san_aliases = ";".join(
                [x["alias"] for x in san_items]
            )

            san_wwpns = ";".join(
                [x["wwpn"] for x in san_items
                 if x["wwpn"]]
            )

            #
            # SAS
            #
            sas_items = sas_by_lpar.get(
                lpar_name,
                []
            )

            sas_aliases = ";".join(
                [x["alias"] for x in sas_items]
            )

            row = {}

            row["entity_type"] = "lpar"
            row["platform"] = "power"
            row["physical_server"] = physical["name"]
            row["machine_type"] = physical["machine_type"]
            row["model"] = physical["model"]
            row["serial"] = physical["serial"]

            row["server_id"] = server_id
            row["hmc_ip"] = hmc_ip

            row["lpar_name"] = lpar_name

            row["lpar_id"] = cfg.get(
                "lpar_id", ""
            )

            row["hostname"] = hostname
            row["ip"] = ip

            row["lpar_state"] = runtime.get(
                "state", ""
            )

            row["cpu_mhz"] = cpu_mhz

            row["cpu_units"] = cfg.get(
                "curr_proc_units",
                cfg_json.get(
                    "DesiredProcessingUnits",
                    ""
                )
            )

            row["virtual_processors"] = cfg.get(
                "curr_procs",
                cfg_json.get(
                    "CurrentVirtualProcessors",
                    ""
                )
            )

            row["max_cpu_units"] = cfg.get(
                "curr_max_proc_units",
                cfg_json.get(
                    "CurrentMaximumProcessingUnits",
                    ""
                )
            )

            row["max_virtual_processors"] = cfg.get(
                "curr_max_procs",
                cfg_json.get(
                    "CurrentMaximumVirtualProcessors",
                    ""
                )
            )

            row["proc_mode"] = cfg.get(
                "curr_proc_mode", ""
            )

            row["sharing_mode"] = cfg.get(
                "curr_sharing_mode",
                cfg_json.get(
                    "SharingMode",
                    ""
                )
            )

            row["uncapped_weight"] = cfg.get(
                "curr_uncap_weight",
                cfg_json.get(
                    "CurrentUncappedWeight",
                    ""
                )
            )

            row["memory_current_mb"] = cfg_json.get(
                "CurrentMemory",
                memory.get(
                    "logicalMem",
                    ""
                )
            )

            row["memory_min_mb"] = cfg_json.get(
                "MinimumMemory",
                ""
            )

            row["memory_max_mb"] = cfg_json.get(
                "MaximumMemory",
                ""
            )

            row["cpu_pool"] = cpu_pool
            row["agent"] = agent

            row["disk_count"] = str(len(disks))
            row["disks"] = disk_names
            row["disk_wwids"] = disk_wwids

            row["filesystem_count"] = str(
                len(filesystems)
            )

            row["filesystems"] = fs_mounts

            row["lan"] = lan_aliases
            row["san"] = san_aliases
            row["san_wwpn"] = san_wwpns
            row["sas"] = sas_aliases

            row["processor_compatibility"] = cfg_json.get(
                "CurrentProcessorCompatibilityMode",
                ""
            )

            row["uuid"] = cfg_json.get(
                "UUID",
                runtime.get(
                    "uuid",
                    ""
                )
            )

            row["phyp_id"] = runtime.get(
                "id",
                ""
            )

            rows.append(normalize_row(row))

        #
        # Uma linha para o proprio frame. O grafo precisa dele como no, e a
        # capacidade total nao aparece em nenhuma linha de LPAR.
        #
        if physical["name"]:
            rows.append(normalize_row({
                "entity_type": "frame",
                "platform": "power",
                "physical_server": physical["name"],
                "machine_type": physical["machine_type"],
                "model": physical["model"],
                "serial": physical["serial"],
                "server_id": server_id,
                "hmc_ip": hmc_ip,
                "lpar_name": physical["name"],
                "hostname": physical["name"],
                "uuid": physical["uuid"],
                "cpu_mhz": cpu_mhz,
                "cpu_pool": cpu_pool,
            }))

        #
        # LPAR existente no CONFIG mas sem diretório
        #
        for lpar_name in lpar_config:

            if lpar_name in found:
                continue

            cfg = cpu_cfg.get(
                lpar_name,
                {}
            )

            cfg_json = lpar_config[lpar_name]

            runtime = phyp.get(
                lpar_name,
                {}
            )

            row = {}

            row["entity_type"] = "lpar"
            row["platform"] = "power"
            row["physical_server"] = physical["name"]
            row["machine_type"] = physical["machine_type"]
            row["model"] = physical["model"]
            row["serial"] = physical["serial"]

            row["server_id"] = server_id
            row["hmc_ip"] = hmc_ip

            row["lpar_name"] = lpar_name
            row["lpar_id"] = cfg.get(
                "lpar_id",
                ""
            )

            row["hostname"] = ""
            row["ip"] = ""

            row["lpar_state"] = runtime.get(
                "state",
                ""
            )

            row["cpu_mhz"] = cpu_mhz

            row["cpu_units"] = cfg.get(
                "curr_proc_units",
                cfg_json.get(
                    "DesiredProcessingUnits",
                    ""
                )
            )

            row["virtual_processors"] = cfg.get(
                "curr_procs",
                cfg_json.get(
                    "CurrentVirtualProcessors",
                    ""
                )
            )

            row["max_cpu_units"] = cfg.get(
                "curr_max_proc_units",
                cfg_json.get(
                    "CurrentMaximumProcessingUnits",
                    ""
                )
            )

            row["max_virtual_processors"] = cfg.get(
                "curr_max_procs",
                cfg_json.get(
                    "CurrentMaximumVirtualProcessors",
                    ""
                )
            )

            row["proc_mode"] = cfg.get(
                "curr_proc_mode",
                ""
            )

            row["sharing_mode"] = cfg.get(
                "curr_sharing_mode",
                cfg_json.get(
                    "SharingMode",
                    ""
                )
            )

            row["uncapped_weight"] = cfg.get(
                "curr_uncap_weight",
                cfg_json.get(
                    "CurrentUncappedWeight",
                    ""
                )
            )

            row["memory_current_mb"] = cfg_json.get(
                "CurrentMemory",
                ""
            )

            row["memory_min_mb"] = cfg_json.get(
                "MinimumMemory",
                ""
            )

            row["memory_max_mb"] = cfg_json.get(
                "MaximumMemory",
                ""
            )

            row["cpu_pool"] = cpu_pool
            row["agent"] = agent

            row["disk_count"] = "0"
            row["disks"] = ""
            row["disk_wwids"] = ""

            row["filesystem_count"] = "0"
            row["filesystems"] = ""

            row["lan"] = ""
            row["san"] = ""
            row["san_wwpn"] = ""
            row["sas"] = ""

            row["processor_compatibility"] = cfg_json.get(
                "CurrentProcessorCompatibilityMode",
                ""
            )

            row["uuid"] = cfg_json.get(
                "UUID",
                runtime.get(
                    "uuid",
                    ""
                )
            )

            row["phyp_id"] = runtime.get(
                "id",
                ""
            )

            rows.append(normalize_row(row))

    return rows


FIELDS = [
    "entity_type",
    "platform",
    "physical_server",
    "machine_type",
    "model",
    "serial",
    "server_id",
    "hmc_ip",

    "lpar_name",
    "lpar_id",
    "hostname",
    "ip",
    "lpar_state",

    "cpu_mhz",
    "cpu_units",
    "virtual_processors",
    "max_cpu_units",
    "max_virtual_processors",

    "proc_mode",
    "sharing_mode",
    "uncapped_weight",

    "memory_current_mb",
    "memory_min_mb",
    "memory_max_mb",

    "cpu_pool",
    "agent",

    "disk_count",
    "disks",
    "disk_wwids",

    "filesystem_count",
    "filesystems",

    "lan",
    "san",
    "san_wwpn",
    "sas",

    "processor_compatibility",
    "uuid",
    "phyp_id"
]


def main():

    print("")
    print("==============================================")
    print("LPAR2RRD INVENTORY EXTRACTOR")
    print("==============================================")
    print("Python : %s" % sys.version.split()[0])
    print("Base   : %s" % BASE)
    print("Output : %s" % OUTPUT)
    print("")

    rows = extract_server()

    if not rows:
        print("ERRO: nenhuma LPAR encontrada.")
        return 1

    try:
        outdir = os.path.dirname(OUTPUT)
        if outdir and not os.path.isdir(outdir):
            os.makedirs(outdir)

        if PY3:
            f = open(OUTPUT, "w", newline="", encoding="utf-8")
        else:
            f = open(OUTPUT, "wb")

        writer = csv.DictWriter(
            f,
            fieldnames=FIELDS,
            extrasaction="ignore"
        )

        writer.writeheader()

        for row in rows:
            writer.writerow(row)

        f.close()

    except Exception as e:

        print("ERRO gravando CSV:")
        print(str(e))

        return 1

    print("")
    print("LPARs extraidas: %d" % len(rows))
    print("CSV criado: %s" % OUTPUT)
    print("==============================================")

    return 0


if __name__ == "__main__":
    sys.exit(main())
