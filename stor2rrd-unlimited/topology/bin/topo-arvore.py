#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""topo-arvore.py - inventario das plataformas lido direto da arvore data/.

Por que existe: o leitor de data.db cobre o inventario normalizado, mas esse
banco so e populado quando a integracao com o Xormon esta ativa. Numa
instalacao comum ele nao existe, e o grafo ficava so com o Power, que vem dos
CONFIG.json.

Treze coletores do LPAR2RRD gravam o proprio inventario num JSON com a mesma
forma - labels e architecture - sob data/<Plataforma>/. Este modulo le esses
arquivos, de modo que oVirt, Nutanix, Proxmox, Kubernetes, OpenShift,
FusionCompute, Cloudstack e OracleVM entram no mapa sem depender de banco
nenhum.

Duas formas de architecture convivem:
  oVirt    architecture[tipo][uuid][subtipo] = [uuid, ...]
  Nutanix  architecture["host_vm"][uuid_pai] = [uuid_filho, ...]
"""

import json
import os
import sys

# onde cada coletor guarda o inventario, relativo a data/
FONTES = [
    ("ovirt",   "oVirt/metadata.json"),
    ("nutanix", "NUTANIX/conf.json"),
    ("proxmox", "Proxmox/conf.json"),
    ("k8s",     "Kubernetes/conf.json"),
    ("k8s",     "Openshift/conf.json"),
    ("fusion",  "FusionCompute/conf.json"),
    ("cloud",   "Cloudstack/conf.json"),
    ("oraclevm", "OracleVM/conf.json"),
    ("docker",  "Docker/conf.json"),
    ("cloud",   "AWS/conf.json"),
    ("cloud",   "Azure/conf.json"),
    ("cloud",   "GCloud/conf.json"),
]

MAQUINAS = {"vm", "host", "node", "instance", "server", "esxi", "guest",
            "virtualmachine", "lpar"}
AGRUPADORES = {"cluster", "datacenter", "pool", "region", "zone", "project",
               "subscription", "domain", "namespace"}
# artefatos nao entram: enterrariam o mapa sem acrescentar dependencia
ARTEFATOS = {"storage_domain", "storagedomain", "datastore", "disk", "volume",
             "pod", "container", "storage_container", "virtual_disk",
             "physical_disk", "nic", "host_nic", "vm_nic", "storage_pool"}


def _tipos_da_chave(chave):
    """'host_vm' -> ('host','vm'). Sem underscore, nao e chave composta."""
    if "_" not in chave:
        return None
    pai, _, filho = chave.partition("_")
    if pai in MAQUINAS | AGRUPADORES and filho in MAQUINAS | AGRUPADORES:
        return pai, filho
    return None


def ler(caminho, plataforma):
    """-> {"itens": {uuid: {...}}, "relacoes": [(pai_uuid, filho_uuid)],
            "erro": str or None}. Nunca levanta."""
    vazio = {"itens": {}, "relacoes": [], "erro": None}
    if not os.path.isfile(caminho):
        return vazio
    try:
        with open(caminho, encoding="utf-8", errors="replace") as f:
            d = json.load(f)
    except (ValueError, OSError) as e:
        vazio["erro"] = str(e)
        return vazio
    if not isinstance(d, dict):
        vazio["erro"] = "raiz nao e objeto"
        return vazio

    itens = {}
    for tipo, mapa in (d.get("labels") or {}).items():
        t = str(tipo).lower()
        if t in ARTEFATOS or not isinstance(mapa, dict):
            continue
        for uuid, nome in mapa.items():
            if not nome:
                continue
            itens[uuid] = {
                "id": uuid,
                "label": str(nome),
                "tipo": t,
                "plataforma": plataforma,
                "classe": "agrupador" if t in AGRUPADORES else "maquina",
            }

    relacoes = []
    for chave, mapa in (d.get("architecture") or {}).items():
        if not isinstance(mapa, dict):
            continue
        composta = _tipos_da_chave(str(chave).lower())
        for uuid, valor in mapa.items():
            if isinstance(valor, dict):
                # forma oVirt: architecture[tipo][uuid][subtipo] = [...]
                for sub, filhos in valor.items():
                    if str(sub).lower() in ARTEFATOS:
                        continue
                    for f in filhos or []:
                        relacoes.append((uuid, f))
            elif isinstance(valor, list) and composta:
                # forma Nutanix: architecture["host_vm"][pai] = [filhos]
                for f in valor:
                    relacoes.append((uuid, f))

    # so relacoes entre itens que existem
    relacoes = [(a, b) for a, b in relacoes if a in itens and b in itens]
    return {"itens": itens, "relacoes": relacoes, "erro": None}


def ler_tudo(dir_data):
    """Varre data/ e devolve o agregado das plataformas encontradas."""
    itens, relacoes, erros, achadas = {}, [], [], []
    for plataforma, rel in FONTES:
        caminho = os.path.join(dir_data, rel)
        r = ler(caminho, plataforma)
        if r["erro"]:
            erros.append((caminho, r["erro"]))
            continue
        if not r["itens"]:
            continue
        achadas.append((rel.split("/")[0], len(r["itens"])))
        itens.update(r["itens"])
        relacoes.extend(r["relacoes"])
    return {"itens": itens, "relacoes": relacoes,
            "erros": erros, "plataformas": achadas}


def main():
    base = sys.argv[1] if len(sys.argv) > 1 else "data"
    r = ler_tudo(base)
    for caminho, e in r["erros"]:
        sys.stderr.write("topo-arvore: %s: %s\n" % (caminho, e))
    for nome, n in r["plataformas"]:
        print("%-16s %d item(ns)" % (nome, n))
    print("total: %d itens, %d relacoes" % (len(r["itens"]), len(r["relacoes"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
