#!/usr/bin/env python3
"""
lpar2rrd.py - Le o inventario exportado do LPAR2RRD e casa cada LPAR com os hosts
do grafo.

O export traz ate 2 linhas por (frame, LPAR): configuracao do HMC e dados do
agente/SO. As linhas sao fundidas. Um mesmo lpar_name pode aparecer em mais de um
frame (historico de LPM): vale o registro Running; sem Running, o mais completo.

Casamento LPAR -> host, do mais forte para o mais fraco:
  1. serial do frame + lpar_id, contra o que a propria coleta AIX informou
  2. hostname do agente LPAR2RRD
  3. IP
  4. lpar_name normalizado (sem sufixo de frame _E0BX e sem _new/_old)
"""
import csv
import re
from collections import defaultdict

NULOS = ("", "null", "none", "n/a")
SUF_FRAME = re.compile(r"_[0-9A-Z]{4}$")          # _E0BX, _C2AY: fim do serial
SUF_VER = re.compile(r"[_-](new|old|novo|antigo|bkp)$", re.I)


def v(x):
    x = (x or "").strip()
    return "" if x.lower() in NULOS else x


def norm_lpar(nome):
    n = SUF_FRAME.sub("", nome.strip())
    n = SUF_VER.sub("", n)
    return n.split(".")[0].lower()


def serial_de(server_id):
    m = re.search(r"SN([0-9A-Z]+)$", server_id or "")
    return m.group(1) if m else ""


def modelo_de(server_id):
    m = re.match(r"Server-(\d{4})-([0-9A-Z]{3})-SN", server_id or "")
    return f"{m.group(1)}-{m.group(2)}" if m else ""


def carregar(caminho):
    fundidas = {}
    for r in csv.DictReader(open(caminho, encoding="utf-8", errors="replace")):
        # CSV v4: so LPAR/VIOS de Power entram aqui (frames e virtualizacao a parte)
        if r.get("platform") and r["platform"] != "power":
            continue
        if r.get("entity_type") in ("frame",):
            continue
        k = (r["server_id"], r["lpar_name"])
        if not r["lpar_name"]:
            continue
        a = fundidas.setdefault(k, {})
        for c, val in r.items():
            if v(val) and not a.get(c):
                a[c] = v(val)
    por_nome = defaultdict(list)
    for (sid, nome), r in fundidas.items():
        r["serial"] = serial_de(sid)
        r["modelo_frame"] = modelo_de(sid)
        r["vios"] = bool(re.search(r"vios|vio\d", nome + " " + r.get("hostname", ""), re.I))
        por_nome[nome.lower()].append(r)     # SRV635_CBQ e srv635_CBQ sao o mesmo registro

    lpars = []
    for nome, regs in por_nome.items():
        def peso(r):
            return (r.get("lpar_state") == "Running", bool(r.get("lpar_state")),
                    bool(r.get("hostname")), len(r))
        regs.sort(key=peso, reverse=True)
        esc = regs[0]
        esc["frames_historico"] = sorted({r["server_id"] for r in regs if r["server_id"] != esc["server_id"]})
        lpars.append(esc)
    return lpars


FORCA = {"serial+lpar_id": 4, "hostname": 3, "ip": 2, "lpar_name": 1}


def candidatos_nome(nome):
    """srv839_NTP -> srv839_ntp, srv839 ; srv202_new_E0BX -> srv202_new, srv202"""
    n = nome.strip().split(".")[0]
    out = []
    atual = n
    for _ in range(3):
        for c in (atual, SUF_VER.sub("", SUF_FRAME.sub("", atual))):
            c = c.lower()
            if c and c not in out:
                out.append(c)
        if "_" not in atual:
            break
        atual = atual.rsplit("_", 1)[0]
    return out


def casar(lpars, nos_ids, ip_para_no, serial_lparid):
    """nos_ids: {id_normalizado: id}; ip_para_no: {ip: id};
    serial_lparid: {(serial, lpar_id): id} vindo da coleta.
    Um no recebe no maximo UMA LPAR: vence o casamento mais forte e, empatando,
    a LPAR Running. As perdedoras ficam sem casamento (registro antigo/homonimo)."""
    for r in lpars:
        r["no"], r["casamento"] = "", ""
        k = (r["serial"], r.get("lpar_id", ""))
        if r.get("lpar_id") and k in serial_lparid:
            r["no"], r["casamento"] = serial_lparid[k], "serial+lpar_id"
            continue
        h = (r.get("hostname") or "").split(".")[0].lower()
        if h and h in nos_ids:
            r["no"], r["casamento"] = nos_ids[h], "hostname"
            continue
        for ip in re.split(r"[;, ]+", r.get("ip", "")):
            if ip in ip_para_no:
                r["no"], r["casamento"] = ip_para_no[ip], "ip"
                break
        if r["no"]:
            continue
        for c in candidatos_nome(r["lpar_name"]):
            if c in nos_ids:
                r["no"], r["casamento"] = nos_ids[c], "lpar_name"
                break

    por_no = defaultdict(list)
    for r in lpars:
        if r["no"]:
            por_no[r["no"]].append(r)
    for no, rs in por_no.items():
        if len(rs) == 1:
            continue
        rs.sort(key=lambda r: (FORCA[r["casamento"]], r.get("lpar_state") == "Running"), reverse=True)
        for perdedor in rs[1:]:
            perdedor["descartado_por"] = rs[0]["lpar_name"]
            perdedor["no"], perdedor["casamento"] = "", ""
    return lpars


def carregar_frames(caminho):
    """Linhas entity_type=frame do CSV v4: capacidade e firmware por serial."""
    out = {}
    for r in csv.DictReader(open(caminho, encoding="utf-8", errors="replace")):
        if r.get("entity_type") != "frame":
            continue
        sn = v(r.get("serial")) or serial_de(r.get("server_id", ""))
        if not sn:
            continue
        a = out.setdefault(sn, {})
        for c in ("machine_type", "model", "total_cpu_units", "total_memory_mb", "firmware", "hmc_ip"):
            if v(r.get(c)) and not a.get(c):
                a[c] = v(r.get(c))
    return out


def carregar_virtualizacao(caminho):
    """Linhas nao-Power do CSV v4 (VMware, Hyper-V, Nutanix, RHV, agente)."""
    out = []
    for r in csv.DictReader(open(caminho, encoding="utf-8", errors="replace")):
        if not r.get("entity_type") or r.get("platform") == "power":
            continue
        out.append({k: v(x) for k, x in r.items()})
    return out
