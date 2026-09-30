#!/usr/bin/env python3
"""topo-build.py - build topologia.json from everything the site collects.

Three independent sources, merged by host identity:

  facts/inventory.csv      what LPAR2RRD/STOR2RRD already know: frames, LPARs,
                           VIOS, models, serials, IPs. Written by
                           topo-inventory.py on every collection cycle.
  uploads/*.csv|*.xlsx     the baseline a person maintains: location,
                           environment, function, cluster. Dropped in by the
                           GUI upload page.
  facts/conexoes/*.csv     observed TCP endpoints from the unix/windows
                           collection kits, in the kit's own
                           categoria,escopo,chave,valor format.

Anything absent is simply skipped, so the map degrades to whatever exists: a
fresh install with no data at all still produces a valid, empty graph.

Every edge carries how it was learnt (ev) and how far to trust it (cf):

  ev  servidor | cliente | ambos | lpar2rrd | baseline
  cf  listen   | porta   | efemera | assumido | lpar2rrd | baseline

Usage: topo-build.py <topology-dir> <output.json>
"""

import csv
import glob
import json
import os
import re
import sys
from collections import defaultdict

PORTA_EFEMERA = 32768           # acima disso, origem quase sempre e cliente
IP_RE = re.compile(r"^\d{1,3}(?:\.\d{1,3}){3}$")

# Nomes de coluna aceitos no baseline, em varias grafias. A planilha real usa
# ingles; CSVs montados a mao costumam vir em portugues.
COLUNAS = {
    "id":  ("hostname", "host", "nome", "servidor", "name"),
    "ips": ("ip address", "ip", "ips", "endereco ip", "ip_address"),
    "amb": ("environment", "ambiente", "amb", "env"),
    "loc": ("location", "localidade", "local", "site", "loc"),
    "fn":  ("function", "funcao", "servico", "finalidade",
            "servico / finalidade", "fn"),
    "os":  ("operation systems", "operating system", "os", "sistema operacional"),
    "chs": ("cluster \nphysical host", "cluster physical host", "physical host",
            "cluster", "chassi", "chs", "hypervisor"),
    "mod": ("manufacturer", "modelo", "model", "mod", "arquitecture",
            "architecture"),
    "st":  ("status", "st", "estado"),
}


# "8408-44E", "IBM,9040-MR9", "SPARC T5-8": tipo de maquina, nao um host.
# A coluna de host fisico da planilha mistura as duas coisas, e um modelo
# viraria um no sem existencia propria.
TIPO_MAQUINA = re.compile(
    r"^\d{4}[-\s][0-9A-Za-z]{2,4}$"          # 8408-44E
    r"|,"                                     # IBM,9040-MR9
    r"|^(?:ibm|hp|hpe|dell|oracle|sun|sparc|lenovo|cisco|fujitsu)\b",
    re.I)

# A planilha nomeia o SO como o fabricante escreve ("W2K12 R2 STD",
# "RHEL 8.6"), nunca como "Windows" ou "Linux".
FAMILIA = (
    ("aix",     ("aix",)),
    ("solaris", ("solaris", "sunos", "sparc")),
    ("windows", ("windows", "w2k", "win20", "winserver", "microsoft")),
    ("linux",   ("linux", "rhel", "red hat", "centos", "suse", "sles",
                 "ubuntu", "debian", "oracle linux", "ol7", "ol8", "ol9",
                 "rocky", "alma")),
    ("vios",    ("vios",)),
)


def plataforma_de(texto):
    t = (texto or "").lower()
    for plat, chaves in FAMILIA:
        for c in chaves:
            if c in t:
                return plat
    return ""


def norm_col(nome):
    return re.sub(r"\s+", " ", str(nome or "").strip().lower())


def norm_host(valor):
    """Compara hosts sem dominio e sem diferenca de caixa. Um IP nunca perde
    os octetos: 10.0.0.1 nao pode colapsar para "10"."""
    v = str(valor or "").strip().lower()
    if IP_RE.match(v):
        return v
    return v.split(".")[0]


def no_vazio(ident):
    return {
        "id": ident, "col": False, "plat": "", "os": "", "amb": "", "loc": "",
        "fn": "", "st": "", "ips": "", "esc": "", "chs": "", "mod": "",
        "gi": 0, "go": 0, "lst": "", "zonas_decl": [],
    }


class Grafo(object):
    def __init__(self):
        self.nos = {}           # id normalizado -> no
        self.rotulo = {}        # id normalizado -> id de exibicao
        self.por_ip = {}        # ip -> id normalizado
        self.arestas = {}       # (s,t) -> aresta

    # ---------------------------------------------------------------- nos
    def no(self, ident, exibicao=None):
        chave = norm_host(ident)
        if not chave:
            return None
        if chave not in self.nos:
            self.nos[chave] = no_vazio(exibicao or str(ident).strip())
            self.rotulo[chave] = exibicao or str(ident).strip()
        elif exibicao and IP_RE.match(self.nos[chave]["id"]) and not IP_RE.match(exibicao):
            # um nome sempre vale mais que o IP que o representava
            self.nos[chave]["id"] = exibicao
        return self.nos[chave]

    def define(self, no, campo, valor):
        """Primeiro valor nao vazio vence: inventario roda antes do baseline."""
        valor = "" if valor is None else str(valor).strip()
        if valor and not no.get(campo):
            no[campo] = valor

    def registra_ips(self, no, ips):
        atuais = no["ips"].split()
        for ip in ips:
            ip = ip.strip()
            if not IP_RE.match(ip):
                continue
            if ip not in atuais:
                atuais.append(ip)
            self.por_ip[ip] = norm_host(no["id"])
        no["ips"] = " ".join(atuais)

    def resolve(self, alvo):
        """Um endpoint pode chegar como hostname ou como IP."""
        chave = norm_host(alvo)
        if chave in self.nos:
            return chave
        if IP_RE.match(alvo.strip()) and alvo.strip() in self.por_ip:
            return self.por_ip[alvo.strip()]
        return chave

    # ------------------------------------------------------------ arestas
    def aresta(self, origem, destino, portas, evidencia, confianca, sessoes=0):
        s, t = self.resolve(origem), self.resolve(destino)
        if not s or not t or s == t:
            return
        for lado in (s, t):
            if lado not in self.nos:
                self.nos[lado] = no_vazio(lado)
        chave = (s, t)
        a = self.arestas.get(chave)
        if a is None:
            a = {"s": s, "t": t, "p": [], "sv": [], "n": 0,
                 "ev": evidencia, "cf": confianca}
            self.arestas[chave] = a
        for p in portas:
            p = str(p).strip()
            if p and p not in a["p"]:
                a["p"].append(p)
                if int(p) < PORTA_EFEMERA:
                    a["sv"].append(p)
        a["n"] += int(sessoes or 0)
        # dois lados relatando a mesma ligacao e a evidencia mais forte
        if a["ev"] != evidencia:
            a["ev"] = "ambos"
        if confianca == "listen":
            a["cf"] = "listen"

    # -------------------------------------------------------------- saida
    def json(self):
        for a in self.arestas.values():
            self.nos[a["s"]]["go"] += 1
            self.nos[a["t"]]["gi"] += 1
        nos = []
        for chave, n in self.nos.items():
            n["s"] = None
            n.pop("s", None)
            n["id"] = self.rotulo.get(chave, n["id"])
            nos.append(n)
        nos.sort(key=lambda x: x["id"])
        arestas = []
        for a in self.arestas.values():
            b = dict(a)
            b["s"] = self.rotulo.get(a["s"], a["s"])
            b["t"] = self.rotulo.get(a["t"], a["t"])
            arestas.append(b)
        arestas.sort(key=lambda x: (x["s"], x["t"]))
        return {"nodes": nos, "links": arestas}


# ===================================================== 1. inventario do produto
def carrega_inventario(g, caminho):
    """facts/inventory.csv, escrito por topo-inventory.py."""
    if not os.path.isfile(caminho):
        return 0
    lidos = 0
    with open(caminho, encoding="utf-8", errors="replace") as f:
        for r in csv.DictReader(f):
            nome = (r.get("hostname") or r.get("lpar_name") or "").strip()
            if not nome:
                continue
            n = g.no(nome, nome)
            lidos += 1
            n["col"] = True
            tipo = (r.get("entity_type") or "lpar").strip()
            if tipo == "frame":
                g.define(n, "plat", "frame")
                g.define(n, "os", "IBM Power")
            elif re.search(r"vios|vio\d", nome, re.I):
                g.define(n, "plat", "vios")
                g.define(n, "os", "VIOS")
            tipo_modelo = "-".join(x for x in (r.get("machine_type"),
                                                r.get("model")) if x)
            g.define(n, "mod", tipo_modelo)
            g.define(n, "chs", r.get("serial"))
            g.define(n, "st", "ON" if r.get("lpar_state") == "Running" else "")
            g.registra_ips(n, re.split(r"[;, ]+", r.get("ip") or ""))

            # frame -> LPAR: uma relacao que so o produto conhece
            frame = (r.get("physical_server") or "").strip()
            if frame and norm_host(frame) != norm_host(nome):
                fn_ = g.no(frame, frame)
                fn_["col"] = True
                g.define(fn_, "plat", "frame")
                g.define(fn_, "os", "IBM Power")
                g.define(fn_, "mod", tipo_modelo)
                g.aresta(frame, nome, [], "lpar2rrd", "lpar2rrd")
    return lidos


# ============================================================ 2. baseline
def linhas_planilha(caminho):
    """Cada linha como dict de coluna normalizada -> valor. .xlsx precisa de
    openpyxl; sem ele o arquivo e ignorado com aviso, nunca com excecao."""
    if caminho.lower().endswith((".csv", ".txt")):
        with open(caminho, encoding="utf-8-sig", errors="replace") as f:
            amostra = f.read(8192)
            f.seek(0)
            try:
                dialeto = csv.Sniffer().sniff(amostra, delimiters=",;\t")
            except csv.Error:
                dialeto = csv.excel
            for r in csv.DictReader(f, dialect=dialeto):
                yield {norm_col(k): v for k, v in r.items() if k}
        return

    try:
        import openpyxl
    except ImportError:
        sys.stderr.write("topo-build: openpyxl ausente, %s ignorado\n"
                         % os.path.basename(caminho))
        return
    wb = openpyxl.load_workbook(caminho, read_only=True, data_only=True)
    for aba in wb.sheetnames:
        ws = wb[aba]
        cabecalho = None
        for linha in ws.iter_rows(values_only=True):
            if linha is None:
                continue
            if cabecalho is None:
                # a primeira linha com pelo menos 3 celulas de texto e o cabecalho
                textos = [c for c in linha if isinstance(c, str) and c.strip()]
                if len(textos) >= 3:
                    cabecalho = [norm_col(c) for c in linha]
                continue
            yield {cabecalho[i]: linha[i]
                   for i in range(min(len(cabecalho), len(linha)))
                   if cabecalho[i]}


def coluna(reg, campo):
    for nome in COLUNAS[campo]:
        if nome in reg and reg[nome] not in (None, ""):
            return str(reg[nome]).strip()
    return ""


def carrega_baseline(g, diretorio):
    arquivos = sorted(glob.glob(os.path.join(diretorio, "*")))
    lidos = 0
    for caminho in arquivos:
        if not caminho.lower().endswith((".csv", ".txt", ".xlsx")):
            continue
        try:
            registros = list(linhas_planilha(caminho))
        except Exception as e:                       # planilha malformada
            sys.stderr.write("topo-build: %s ilegivel (%s)\n"
                             % (os.path.basename(caminho), e))
            continue
        for reg in registros:
            ident = coluna(reg, "id")
            if not ident or ident.lower() in ("hostname", "host", "nome"):
                continue
            n = g.no(ident, ident)
            lidos += 1
            chassi_planilha = coluna(reg, "chs")
            for campo in ("amb", "loc", "fn", "os", "chs", "mod", "st"):
                g.define(n, campo, coluna(reg, campo))
            g.registra_ips(n, re.split(r"[;, /]+", coluna(reg, "ips")))
            if not n["plat"]:
                n["plat"] = plataforma_de(n["os"])
            # o host fisico declarado na planilha e uma ligacao real, mas a
            # coluna as vezes traz o tipo de maquina (8408-44E) em vez de um
            # host: isso viraria um no sem existencia propria
            if (chassi_planilha and norm_host(chassi_planilha) != norm_host(ident)
                    and not TIPO_MAQUINA.match(chassi_planilha.strip())):
                g.aresta(chassi_planilha, ident, [], "baseline", "baseline")
    return lidos


# ====================================================== 3. fatos de conexao
# O kit de coleta emite CSV de 4 colunas: categoria,escopo,chave,valor.
# Interessam as categorias "conexao" e "meta"; o resto (storage, seguranca)
# descreve o host e nao a topologia.
def carrega_conexoes(g, diretorio):
    arquivos = sorted(glob.glob(os.path.join(diretorio, "*.csv")))
    hosts = 0
    for caminho in arquivos:
        # o nome do arquivo identifica o host: <host>_conexoes.csv
        host = re.sub(r"[_-]?(conexoes|conexao|06.*)?\.csv$", "",
                      os.path.basename(caminho), flags=re.I)
        if not host:
            continue
        n = g.no(host, host)
        n["col"] = True
        hosts += 1
        portas_listen = []
        try:
            with open(caminho, encoding="utf-8", errors="replace") as f:
                for campos in csv.reader(f):
                    if len(campos) < 4:
                        continue
                    categoria, escopo, chave, valor = (
                        campos[0].strip(), campos[1].strip(),
                        campos[2].strip(), campos[3].strip())

                    if categoria == "meta" and escopo == "host":
                        if chave == "plataforma":
                            g.define(n, "plat", valor)
                        elif chave == "distro":
                            g.define(n, "os", valor)
                        elif chave == "zona_tipo":
                            g.define(n, "esc", valor)
                        continue

                    if categoria != "conexao":
                        continue

                    if escopo == "ip_local":
                        g.registra_ips(n, [valor])
                    elif escopo in ("listen", "porta_listen"):
                        porta = re.sub(r"\D", "", chave or valor)
                        if porta and porta not in portas_listen:
                            portas_listen.append(porta)
                    elif escopo in ("entrada", "cliente"):
                        # alguem se conectou a uma porta nossa: ele -> nos
                        remoto, porta, sessoes = _endpoint(chave, valor)
                        if remoto:
                            g.aresta(remoto, host, [porta] if porta else [],
                                     "servidor",
                                     "listen" if porta and int(porta) < PORTA_EFEMERA
                                     else "efemera", sessoes)
                    elif escopo in ("saida", "servidor"):
                        # nos conectamos a uma porta de alguem: nos -> ele
                        remoto, porta, sessoes = _endpoint(chave, valor)
                        if remoto:
                            g.aresta(host, remoto, [porta] if porta else [],
                                     "cliente",
                                     "porta" if porta and int(porta) < PORTA_EFEMERA
                                     else "efemera", sessoes)
        except Exception as e:
            sys.stderr.write("topo-build: %s ilegivel (%s)\n"
                             % (os.path.basename(caminho), e))
            continue
        if portas_listen:
            n["lst"] = " ".join(sorted(portas_listen, key=lambda p: int(p)))
    return hosts


def _endpoint(chave, valor):
    """O kit escreve o par remoto como "ip:porta" na chave e o numero de
    sessoes no valor; aceita tambem "ip porta" e so "ip"."""
    sessoes = 0
    m = re.search(r"\d+", valor or "")
    if m:
        sessoes = int(m.group())
    partes = re.split(r"[:\s]+", (chave or "").strip())
    remoto = partes[0] if partes else ""
    porta = ""
    if len(partes) > 1 and partes[1].isdigit():
        porta = partes[1]
    return remoto, porta, sessoes


# ==================================================================== main
def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    base, saida = sys.argv[1], sys.argv[2]

    g = Grafo()
    n_inv = carrega_inventario(g, os.path.join(base, "facts", "inventory.csv"))
    n_con = carrega_conexoes(g, os.path.join(base, "facts", "conexoes"))
    n_bas = carrega_baseline(g, os.path.join(base, "uploads"))

    dados = g.json()

    # grava por arquivo temporario: a pagina pode estar sendo lida agora
    tmp = saida + ".novo"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(dados, f, ensure_ascii=False, separators=(",", ":"))
    os.rename(tmp, saida)

    print("topo-build: %d LPAR/frame do produto, %d hosts coletados, "
          "%d linhas de baseline" % (n_inv, n_con, n_bas))
    print("topo-build: %d nos, %d ligacoes -> %s"
          % (len(dados["nodes"]), len(dados["links"]), saida))
    return 0


if __name__ == "__main__":
    sys.exit(main())
