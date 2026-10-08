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

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import lpar2rrd as casador
import importlib.util as _u

# topo-db.py has a hyphen, so it cannot be imported by name
_spec = _u.spec_from_file_location(
    "topo_db", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "topo-db.py"))
leitor_db = _u.module_from_spec(_spec)
_spec.loader.exec_module(leitor_db)

_spec_a = _u.spec_from_file_location(
    "topo_arvore", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "topo-arvore.py"))
leitor_arvore = _u.module_from_spec(_spec_a)
_spec_a.loader.exec_module(leitor_arvore)


def bancos(base):
    """Where the products keep their normalised inventory. base is
    $INPUTDIR/topology.

    The two products are not always siblings: a common layout is
    /home/lpar2rrd/lpar2rrd beside /home/stor2rrd/stor2rrd, where neither is
    under the other's parent. Looking only next to ourselves found the local
    product and silently missed the other one. TOPO_DB overrides the search
    with an explicit colon-separated list."""
    raiz = os.path.dirname(os.path.abspath(base))
    pai = os.path.dirname(raiz)
    candidatos = []

    for caminho in filter(None, os.environ.get("TOPO_DB", "").split(":")):
        candidatos.append((caminho, caminho))

    candidatos.append((os.path.join(raiz, "data", "data.db"), raiz))
    for prod in ("lpar2rrd", "stor2rrd"):
        # irmao: /home/x/lpar2rrd e /home/x/stor2rrd
        candidatos.append((os.path.join(pai, prod, "data", "data.db"),
                           os.path.join(pai, prod)))
        # cada produto na propria home: /home/stor2rrd/stor2rrd
        for lar in ("/home", os.path.dirname(pai) or "/home"):
            candidatos.append(
                (os.path.join(lar, prod, prod, "data", "data.db"),
                 os.path.join(lar, prod, prod)))

    vistos = []
    for caminho, home in candidatos:
        real = os.path.realpath(caminho)
        if os.path.isfile(real) and real not in [v[0] for v in vistos]:
            rotulo = "stor2rrd" if "stor2rrd" in home.lower() else "lpar2rrd"
            vistos.append((real, rotulo))

    # os caminhos tentados ficam guardados: so viram mensagem se nada mais
    # alimentar o grafo, senao seriam ruido a cada coleta
    global TENTADOS
    TENTADOS = [c for c, _ in candidatos]
    return vistos


TENTADOS = []

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


# "Desativado", "Decommissioned", "Desligado": a coluna de status das planilhas
# nao tem vocabulario fixo. "off" sozinho nao entra - "ON" conteria "on", nao
# "off", mas "Power Off" e "OFF" sim.
DESATIVADO_RE = re.compile(r"desativ|desligad|decommission|retired|\boff\b", re.I)
CLOUD_RE = re.compile(r"\b(aws|azure|gcp|google cloud|oracle cloud|oci|cloud)\b", re.I)


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
    def aresta(self, origem, destino, portas, evidencia, confianca, sessoes=0,
               tipo=None):
        s, t = self.resolve(origem), self.resolve(destino)
        if not s or not t:
            return "sem_no"
        if s == t:
            # os dois lados resolveram para o mesmo no: ou o host falou consigo
            # proprio, ou dois IPs dele foram registados como do mesmo no
            return "mesmo_no"
        for lado in (s, t):
            if lado not in self.nos:
                self.nos[lado] = no_vazio(lado)
        chave = (s, t)
        a = self.arestas.get(chave)
        nova = "nova" if a is None else "fundida"
        if a is None:
            a = {"s": s, "t": t, "p": [], "sv": [], "n": 0,
                 "ev": evidencia, "cf": confianca}
            # A pagina separa ligacao estrutural de conexao TCP por este campo:
            # muda a distancia e a forca no layout, desenha a hierarquia e tira
            # a ligacao da contagem de conexoes. Sem ele, frame->LPAR era mais
            # uma linha solta no meio do grafo.
            if tipo:
                a["tipo"] = tipo
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
        return nova

    # -------------------------------------------------------------- saida
    # A pagina inteira e dirigida por "classe": e ela que da a cor, o raio, a
    # entrada na legenda, cada filtro e cada contador do cabecalho. Sem ela o
    # mapa saia monocromatico e o resumo dizia "0 cloud - 0 Windows - 0 hosts
    # fisicos - 0 desativados" com milhares de nos na tela. O campo nunca era
    # escrito: os dados para deduzi-lo ja estavam todos aqui.
    #
    # A ordem e a mesma da precedencia de cor da pagina: o que e estrutura
    # (frame, chassi, cluster, hipervisor, VIOS) vence, e so depois o estado
    # (desativado, DR), a hospedagem (cloud) e por fim a plataforma.
    def _classifica(self):
        hospeda = defaultdict(int)
        for a in self.arestas.values():
            if a.get("tipo") == "hospeda":
                hospeda[a["s"]] += 1

        for chave, n in self.nos.items():
            plat = (n.get("plat") or "").lower()
            st = (n.get("st") or "").lower()
            amb = (n.get("amb") or "").lower()
            loc = (n.get("loc") or "").lower()
            so = (n.get("os") or "").lower()
            ident = (n.get("id") or "").lower()
            filhos = hospeda.get(chave, 0)

            if plat == "frame" or ident.startswith("frame:"):
                n["classe"] = "frame"
                # raio() le fr.lpars sem protecao: a classe sem o objeto
                # derrubava o desenho inteiro no primeiro quadro
                n["fr"] = {"lpars": filhos, "modelo": n.get("mod", ""),
                           "serial": n.get("chs", "")}
            elif plat == "chassi" or ident.startswith("chassi:"):
                n["classe"] = "chassi"
                n["ch"] = {"globais": filhos, "modelo": n.get("mod", "")}
            elif plat == "cluster" or ident.startswith("cluster:"):
                n["classe"] = "cluster_virt"
                n["cv"] = {"vms": filhos, "plataforma": n.get("os", "")}
            elif plat == "vios":
                n["classe"] = "vios"
            elif filhos:
                n["classe"] = "hipervisor"
                n["hv"] = {"vms": filhos, "plataforma": n.get("plat", "")}
            elif DESATIVADO_RE.search(st):
                n["classe"] = "desativado"
                n["grupo"] = "desat"
            elif amb == "dr" or st == "dr" or ident.endswith("_dr"):
                n["classe"] = "dr"
            elif CLOUD_RE.search(loc) or plat == "cloud":
                n["classe"] = "cloud"
                n["grupo"] = "cloud"
            elif plat == "windows" or "windows" in so:
                n["classe"] = "windows"
            elif n.get("col") or n.get("os") or n.get("loc") or n.get("fn"):
                # tem inventario ou linha de planilha: e um host conhecido
                n["classe"] = "normal"
            # sem nenhum dos dois: so apareceu numa conexao TCP. Fica sem
            # classe, como na topologia de referencia, e a pagina o desenha
            # com a cor neutra.

    def json(self):
        for a in self.arestas.values():
            self.nos[a["s"]]["go"] += 1
            self.nos[a["t"]]["gi"] += 1
        self._classifica()
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
# Delegado a lpar2rrd.py, que faz o que este arquivo nao fazia: funde as ate
# duas linhas por (frame, LPAR) - configuracao do HMC e dados do agente -,
# resolve a mesma LPAR aparecendo em varios frames por historico de LPM
# (vence Running, depois o registro mais completo), e casa cada LPAR com um no
# ja existente pelo criterio mais forte disponivel:
#
#   serial do frame + lpar_id  (4)   o que a propria coleta AIX informou
#   hostname do agente         (3)
#   IP                         (2)
#   lpar_name normalizado      (1)   sem sufixo de frame e sem _new/_old
#
# Um no recebe no maximo uma LPAR; as perdedoras ficam com descartado_por.
# Por isso o inventario e a ULTIMA fonte a rodar: precisa dos nos que os
# coletores e o baseline ja criaram.
def carrega_inventario(g, caminho, serial_lparid):
    if not os.path.isfile(caminho):
        return 0

    try:
        lpars = casador.carregar(caminho)
        frames = casador.carregar_frames(caminho)
    except Exception as e:
        sys.stderr.write("topo-build: inventory.csv ilegivel (%s)\n" % e)
        return 0

    # carregar_frames indexa por serial e nao devolve o nome do frame, entao
    # nao cria nos aqui - isso duplicaria o frame com o serial por rotulo. Vira
    # uma consulta: o tipo-modelo por serial, aplicado depois que o laco das
    # LPARs criou o no do frame com o nome certo.
    def modelo_do_serial(sn):
        f = frames.get(sn or "", {})
        return "-".join(x for x in (f.get("machine_type"), f.get("model")) if x)

    # os indices que casar() consulta, montados sobre o grafo atual
    nos_ids = {}
    for chave, n in g.nos.items():
        nos_ids[chave] = chave
        for c in casador.candidatos_nome(n["id"]):
            nos_ids.setdefault(c, chave)
    ip_para_no = dict(g.por_ip)

    casador.casar(lpars, nos_ids, ip_para_no, serial_lparid)

    for r in lpars:
        alvo = r.get("no") or r["lpar_name"]
        n = g.no(alvo, alvo if not r.get("no") else None)
        if n is None:
            continue
        n["col"] = True
        if r.get("vios"):
            g.define(n, "plat", "vios")
            g.define(n, "os", "VIOS")
        g.define(n, "mod", r.get("modelo_frame") or modelo_do_serial(r.get("serial"))
                           or r.get("machine_type"))
        g.define(n, "chs", r.get("serial"))
        g.define(n, "st", "ON" if r.get("lpar_state") == "Running" else "")
        g.registra_ips(n, re.split(r"[;, ]+", r.get("ip") or ""))

        # frame -> LPAR: a relacao que so o produto conhece
        frame = (r.get("physical_server") or r.get("server_id") or "").strip()
        if frame and norm_host(frame) != norm_host(n["id"]):
            fn_ = g.no(frame, frame)
            fn_["col"] = True
            g.define(fn_, "plat", "frame")
            g.define(fn_, "os", "IBM Power")
            g.define(fn_, "mod", r.get("modelo_frame") or modelo_do_serial(r.get("serial")))
            g.define(fn_, "chs", r.get("serial"))
            g.aresta(frame, n["id"], [], "lpar2rrd", "lpar2rrd",
                     tipo="hospeda")

    # quantas casaram, e por qual criterio - vai para o log da coleta
    porforca = defaultdict(int)
    for r in lpars:
        porforca[r.get("casamento") or "sem casamento"] += 1
    if porforca:
        sys.stdout.write("topo-build: casamento de LPARs: %s\n" % ", ".join(
            "%s=%d" % (k, porforca[k]) for k in sorted(porforca)))

    return len(lpars)


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

    if caminho.lower().endswith(".xls"):
        # o formato antigo do Excel nao e lido pelo openpyxl; xlrd < 2.0 le,
        # e sem ele o caminho util e salvar como .xlsx ou CSV
        try:
            import xlrd
        except ImportError:
            sys.stderr.write(
                "topo-build: %s e Excel antigo (.xls) e o modulo xlrd nao esta "
                "instalado; salve como .xlsx ou CSV e importe de novo\n"
                % os.path.basename(caminho))
            return
        livro = xlrd.open_workbook(caminho)
        for aba in livro.sheets():
            cabecalho = None
            for i in range(aba.nrows):
                linha = [c.value for c in aba.row(i)]
                if cabecalho is None:
                    textos = [c for c in linha
                              if isinstance(c, str) and c.strip()]
                    if len(textos) >= 3:
                        cabecalho = [norm_col(c) for c in linha]
                    continue
                yield dict((cabecalho[j], linha[j])
                           for j in range(min(len(cabecalho), len(linha)))
                           if cabecalho[j])
        return

    try:
        import openpyxl
    except ImportError:
        # Sem openpyxl, le-se o .xlsx com a biblioteca padrao: e um zip de XML.
        # A alternativa era ignorar a planilha, que e exatamente o inventario
        # que o usuario quis importar.
        for reg in _xlsx_sem_openpyxl(caminho):
            yield reg
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


def _xlsx_sem_openpyxl(caminho):
    """Le um .xlsx sem dependencia externa.

    O formato e um zip: xl/worksheets/sheetN.xml traz as celulas e
    xl/sharedStrings.xml a tabela de textos. Celulas com t="s" guardam o
    indice nessa tabela; as demais trazem o valor direto em <v>. Celulas
    vazias sao omitidas, por isso a coluna vem da referencia (A1, B1, ...)
    e nao da ordem de aparicao."""
    import zipfile
    import xml.etree.ElementTree as ET

    NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"

    def col_para_indice(ref):
        letras = "".join(c for c in ref if c.isalpha())
        n = 0
        for c in letras:
            n = n * 26 + (ord(c.upper()) - 64)
        return n - 1

    try:
        z = zipfile.ZipFile(caminho)
    except (zipfile.BadZipFile, IOError) as e:
        sys.stderr.write("topo-build: %s nao abre como xlsx (%s)\n"
                         % (os.path.basename(caminho), e))
        return

    with z:
        textos = []
        if "xl/sharedStrings.xml" in z.namelist():
            raiz = ET.fromstring(z.read("xl/sharedStrings.xml"))
            for si in raiz.findall(NS + "si"):
                # o texto pode vir partido em varios <t> por formatacao
                textos.append("".join(t.text or "" for t in si.iter(NS + "t")))

        folhas = sorted(n for n in z.namelist()
                        if n.startswith("xl/worksheets/sheet") and n.endswith(".xml"))
        for folha in folhas:
            raiz = ET.fromstring(z.read(folha))
            cabecalho = None
            for linha in raiz.iter(NS + "row"):
                valores = {}
                largura = 0
                for c in linha.findall(NS + "c"):
                    i = col_para_indice(c.get("r") or "")
                    if i < 0:
                        continue
                    largura = max(largura, i + 1)
                    v = c.find(NS + "v")
                    if c.get("t") == "s":
                        if v is not None and v.text is not None:
                            try:
                                valores[i] = textos[int(v.text)]
                            except (ValueError, IndexError):
                                valores[i] = ""
                    elif c.get("t") == "inlineStr":
                        valores[i] = "".join(t.text or "" for t in c.iter(NS + "t"))
                    elif v is not None:
                        valores[i] = v.text or ""
                celulas = [valores.get(i, "") for i in range(largura)]

                if cabecalho is None:
                    textos_linha = [x for x in celulas if str(x).strip()]
                    if len(textos_linha) >= 3:
                        cabecalho = [norm_col(str(x)) for x in celulas]
                    continue
                yield {cabecalho[i]: celulas[i]
                       for i in range(min(len(cabecalho), len(celulas)))
                       if cabecalho[i]}


def coluna(reg, campo):
    for nome in COLUNAS[campo]:
        if nome in reg and reg[nome] not in (None, ""):
            return str(reg[nome]).strip()
    return ""


def separa_uploads(diretorio):
    """-> (inventarios, coletas). Um CSV de coleta subido pela tela de
    importacao ia inteiro para o baseline: cada linha virava um no, e os
    arquivos agregados do kit tem centenas de milhares de linhas. Agora cada
    um vai para o leitor que entende o seu formato."""
    inventarios, coletas, recusados = [], [], []
    for caminho in sorted(glob.glob(os.path.join(diretorio, "*"))):
        baixo = caminho.lower()
        if baixo.endswith((".xls", ".xlsx")):
            inventarios.append(caminho)      # planilha: so pode ser inventario
            continue
        if not baixo.endswith((".csv", ".txt")):
            continue
        tipo, _ = classifica_csv(caminho)
        if tipo == "fatos":
            coletas.append(caminho)
        elif tipo == "inventario":
            inventarios.append(caminho)
        else:
            recusados.append(caminho)
    for caminho in recusados:
        sys.stderr.write(
            "topo-build: %s ignorado: o cabecalho nao e de inventario "
            "(hostname/host/nome mais uma coluna como os, site, funcao) "
            "nem de coleta (termina em categoria,item,chave,valor)\n"
            % os.path.basename(caminho))
    return inventarios, coletas


def carrega_baseline(g, arquivos):
    lidos = 0
    for caminho in arquivos:
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
                g.aresta(chassi_planilha, ident, [], "baseline", "baseline",
                         tipo="hospeda")
    return lidos


# ====================================================== 3. fatos dos coletores
# O kit emite CSV de 4 colunas: categoria,escopo,chave,valor. Tudo em
# facts/ e lido, nao so as conexoes: 01_sistema traz o serial do frame e o
# lpar_id, que juntos sao o casamento mais forte com o inventario do produto.
# Tres formatos de coleta convivem, e so um traz o host no nome do arquivo:
#
#   <host>_categoria.csv   categoria,item,chave,valor                (4 colunas)
#   NN_categoria.csv       hostname,categoria,item,chave,valor       (5 colunas)
#   00_consolidado.csv     origem,hostname,categoria,item,chave,valor (6 colunas)
#
# O kit agrega varios hosts num arquivo so e prefixa a coluna hostname; ler
# apenas o formato de 4 colunas deixava esses arquivos sem host nenhum.
CAB_FATOS = ("categoria", "item", "chave", "valor")


def classifica_csv(caminho):
    """-> ("fatos", indice_da_coluna_host) | ("inventario", None) | (None, None)"""
    try:
        with open(caminho, encoding="utf-8", errors="replace") as fh:
            cab = next(csv.reader(fh), [])
    except (IOError, OSError, StopIteration):
        return (None, None)
    nomes = [c.strip().lower() for c in cab]

    # coleta: o cabecalho termina nas quatro colunas de fato
    if len(nomes) >= 4 and tuple(nomes[-4:]) == CAB_FATOS:
        if "hostname" in nomes[:-4]:
            return ("fatos", nomes.index("hostname"))
        return ("fatos", None)          # host vem do nome do arquivo

    # inventario: precisa de uma coluna de identificacao e de ao menos uma
    # outra coluna de inventario, senao qualquer CSV viraria nos soltos
    def tem(campo):
        return any(n in COLUNAS[campo] for n in nomes)

    if tem("id") and any(tem(c) for c in ("os", "loc", "amb", "fn", "chs", "mod", "ips")):
        return ("inventario", None)
    return (None, None)


def carrega_fatos(g, base, extras=None):
    raiz = os.path.join(base, "facts")
    arquivos = sorted(glob.glob(os.path.join(raiz, "*.csv"))
                      + glob.glob(os.path.join(raiz, "*", "*.csv")))
    arquivos += list(extras or [])

    # arquivos agregados trazem varios hosts; sao lidos a parte, porque o host
    # vem de dentro da linha e nao do nome
    agregados = []
    por_host = defaultdict(list)
    for caminho in arquivos:
        if os.path.basename(caminho) == "inventory.csv":
            continue
        tipo, idx = classifica_csv(caminho)
        if tipo == "fatos" and idx is not None:
            agregados.append((caminho, idx))
            continue
        por_host[nome_do_host(caminho)].append(caminho)
    por_host.pop("", None)

    # desdobra cada agregado em linhas por host, no mesmo formato de 4 campos
    linhas_por_host = defaultdict(list)
    for caminho, idx in agregados:
        try:
            fh = open(caminho, encoding="utf-8", errors="replace")
        except IOError as e:
            sys.stderr.write("topo-build: %s ilegivel (%s)\n"
                             % (os.path.basename(caminho), e))
            continue
        with fh:
            leitor = csv.reader(fh)
            next(leitor, None)                      # cabecalho
            for campos in leitor:
                if len(campos) <= idx + 4:
                    continue
                host = campos[idx].strip()
                if not host:
                    continue
                linhas_por_host[host].append(campos[idx + 1:])
    for host in linhas_por_host:
        por_host.setdefault(host, [])

    # Contadores: sem eles, "o grafo tem menos ligacoes do que o CSV" nao tinha
    # como ser respondido sem reproduzir o ambiente inteiro. Dizem quantas
    # linhas de conexao entraram e o que aconteceu a cada uma.
    conta = defaultdict(int)

    serial_lparid = {}          # (serial, lpar_id) -> id normalizado, para casar()
    for host, caminhos in sorted(por_host.items()):
        n = g.no(host, host)
        n["col"] = True
        portas_listen = []
        fanin, fanin_rede = {}, {}
        serial = lpar_id = ""

        # cada arquivo por host, mais as linhas que vieram dos agregados
        fontes = []
        for caminho in caminhos:
            try:
                fh = open(caminho, encoding="utf-8", errors="replace")
            except IOError as e:
                sys.stderr.write("topo-build: %s ilegivel (%s)\n"
                                 % (os.path.basename(caminho), e))
                continue
            with fh:
                fontes.append(list(csv.reader(fh)))
        if linhas_por_host.get(host):
            fontes.append(linhas_por_host[host])

        for bloco in fontes:
            if bloco:
                for campos in bloco:
                    if len(campos) < 4:
                        continue
                    # lib.sh cita valores com virgula, mas um CSV montado a
                    # mao nao: junte o resto em vez de truncar no 4o campo
                    cat, esc, chave = (c.strip() for c in campos[:3])
                    valor = ",".join(campos[3:]).strip()
                    if not valor:
                        continue

                    if cat == "meta" and esc == "host":
                        if chave == "plataforma":
                            g.define(n, "plat", valor)
                        elif chave == "distro":
                            g.define(n, "os", valor)
                        elif chave == "zona_tipo":
                            g.define(n, "esc", valor)

                    elif cat == "frame":
                        if chave == "frame_serial":
                            serial = valor
                            g.define(n, "chs", valor)
                        elif chave in ("tipo_modelo", "tipo_modelo_curto"):
                            g.define(n, "mod", valor)

                    elif cat == "lpar":
                        if chave == "lpar_id":
                            lpar_id = valor
                        elif chave == "tipo" and esc == "zona":
                            g.define(n, "esc", valor)

                    elif cat == "conexao":
                        if esc == "ip_local":
                            g.registra_ips(n, [valor])
                        elif esc in ("listen", "porta_listen"):
                            porta = _porta_de(chave, valor)
                            if porta and porta not in portas_listen:
                                portas_listen.append(porta)
                        elif esc in ("entrada", "cliente"):
                            # alguem se conectou a uma porta nossa: ele -> nos
                            conta["linhas"] += 1
                            remoto, porta, ses, cf = _endpoint(chave, valor)
                            if not remoto:
                                conta["sem_remoto"] += 1
                            else:
                                conta[g.aresta(
                                    remoto, host, [porta] if porta else [],
                                    "servidor", cf or _confianca(porta, True),
                                    ses)] += 1
                        elif esc in ("saida", "servidor"):
                            # nos conectamos a uma porta de alguem: nos -> ele
                            conta["linhas"] += 1
                            remoto, porta, ses, cf = _endpoint(chave, valor)
                            if not remoto:
                                conta["sem_remoto"] += 1
                            else:
                                conta[g.aresta(
                                    host, remoto, [porta] if porta else [],
                                    "cliente", cf or _confianca(porta, False),
                                    ses)] += 1
                        elif esc in ("fanin", "fanin_rede"):
                            # Acima de LIMIAR_FANIN clientes numa porta, o kit
                            # para de emitir aresta a aresta e resume: "porta P
                            # teve N clientes distintos", e por rede /24. Nao ha
                            # identidade do outro lado, entao nao vira ligacao -
                            # mas era descartado sem deixar rasto, e justamente
                            # nos servidores mais procurados do ambiente.
                            alvo = fanin if esc == "fanin" else fanin_rede
                            campos = str(valor or "").split("|")
                            n_cli = campos[-1].strip() if campos else ""
                            if n_cli.isdigit() and chave:
                                alvo[chave.strip()] = int(n_cli)

        if portas_listen:
            n["lst"] = " ".join(sorted(portas_listen, key=lambda p: int(p)))
        if fanin:
            n["fanin"] = fanin
        if fanin_rede:
            n["fanin_rede"] = fanin_rede
        if serial and lpar_id:
            serial_lparid[(serial, lpar_id)] = norm_host(host)

    if conta["linhas"]:
        sys.stdout.write(
            "topo-build: conexoes: %d linha(s) -> %d aresta(s) nova(s), "
            "%d fundida(s) no mesmo par, %d no mesmo no, %d sem o outro lado\n"
            % (conta["linhas"], conta["nova"], conta["fundida"],
               conta["mesmo_no"], conta["sem_remoto"] + conta["sem_no"]))

    return len(por_host), serial_lparid


def nome_do_host(caminho):
    """<host>_conexoes.csv, <host>_01_sistema.csv, <host>.csv -> <host>"""
    nome = os.path.basename(caminho)
    nome = re.sub(r"\.csv$", "", nome, flags=re.I)
    # Duas passagens, e nao um regex so. Um grupo de digitos opcional no meio
    # do padrao come o final do proprio hostname: srv047_conexoes virava
    # "srv0" e web-01_storage virava "web", partindo um host em varios nos.
    nome = re.sub(r"[_-](conexoes|conexao|sistema|rede|storage|seguranca|"
                  r"monitoracao|hyperv)$", "", nome, flags=re.I)
    nome = re.sub(r"_\d{2}$", "", nome)   # o indice NN do kit, sempre com "_"
    return nome.strip("_-")


def _confianca(porta, entrada):
    if not porta:
        return "efemera"
    if int(porta) >= PORTA_EFEMERA:
        return "efemera"
    return "listen" if entrada else "porta"


CONFIANCAS = ("listen", "porta", "efemera", "assumido")


def _endpoint(chave, valor):
    """Le o formato que o proprio kit escreve em 06_conexoes.

        chave  ip|porta
        valor  servico|ip_local|sessoes|amostras|estados|processo|confianca

    O separador e a barra vertical, nao os dois pontos. A versao anterior
    partia a chave em "[:\\s]+", portanto nunca a separava: o endpoint inteiro
    - "10.219.8.209|443" - ia para norm_host(), que nao o reconhece como IP e
    corta no primeiro ponto. Todas as conexoes de uma rede colapsavam num unico
    no chamado "10", e como as arestas sao indexadas por (origem, destino),
    milhares delas viravam uma so. A porta tambem se perdia, e sem porta
    _confianca() devolvia "efemera" para tudo.

    Aceita ainda "ip:porta" e "ip porta", de CSV montado a mao."""
    campos = [c.strip() for c in str(valor or "").split("|")]
    sessoes = 0
    if len(campos) >= 3 and campos[2].isdigit():
        sessoes = int(campos[2])            # formato do kit
    elif len(campos) == 1 and campos[0].isdigit():
        sessoes = int(campos[0])            # valor que e so a contagem
    # o coletor ja classificou a confianca olhando o socket; a conta refeita
    # aqui so adivinha pela porta
    confianca = ""
    if len(campos) >= 7 and campos[6] in CONFIANCAS:
        confianca = campos[6]

    partes = [x for x in re.split(r"[|:\s]+", (chave or "").strip()) if x]
    remoto = partes[0] if partes else ""
    porta = ""
    if len(partes) > 1 and partes[1].isdigit():
        porta = partes[1]
    return remoto, porta, sessoes, confianca


def _porta_de(chave, valor):
    """A chave de um LISTEN e "ip_de_bind|porta". Tirar os nao-digitos da chave
    inteira colava os octetos do bind na porta: 0.0.0.0|443 virava 0000443."""
    partes = [x for x in re.split(r"[|:\s]+", (chave or "").strip()) if x]
    if partes and partes[-1].isdigit():
        return partes[-1]
    return re.sub(r"\D", "", valor or "")


# ====================================== 4. o que os produtos ja colecionaram
# data/data.db e o inventario normalizado do LPAR2RRD e do STOR2RRD: uma
# linha por item monitorado, com a hierarquia em item_relations e o agente em
# agent_relations. Cobre as 21 plataformas de uma vez - VMware, oVirt,
# Nutanix, XenServer, Hyper-V, Linux, nuvem, storages e switches - sem
# depender do layout de diretorio de cada coletor.

# estados que os coletores usam para "ligado", cada um a sua maneira
LIGADO = {"poweredon", "powered_on", "up", "running", "on", "connected",
          "active", "ok", "available", "normal"}
DESLIGADO = {"poweredoff", "powered_off", "down", "off", "stopped",
             "shutoff", "notresponding", "disconnected", "maintenance"}


def estado_normalizado(bruto):
    b = (bruto or "").strip().lower().replace(" ", "")
    if b in LIGADO:
        return "ON"
    if b in DESLIGADO:
        return "Desativado"
    return ""


def carrega_banco(g, caminho, rotulo):
    """rotulo identifica a origem nas arestas: lpar2rrd ou stor2rrd."""
    dados = leitor_db.ler(caminho)
    if dados["erro"]:
        sys.stderr.write("topo-build: %s: %s\n"
                         % (os.path.basename(caminho), dados["erro"]))
        return 0, 0
    itens = dados["itens"]
    if not itens:
        return 0, 0

    guardados = {}          # item_id -> chave do no no grafo
    for iid, it in itens.items():
        if it["classe"] == "artefato":
            continue        # disco, porta, datastore, pod: nao e dependencia
        nome = it["label"] or iid
        n = g.no(nome, nome)
        if n is None:
            continue
        guardados[iid] = norm_host(n["id"])

        # tudo aqui foi efetivamente coletado por um dos produtos
        n["col"] = True
        if it["agente"]:
            n["ag"] = True          # ha agente dentro do host, nao so a visao
                                    # do hipervisor
        g.define(n, "plat", leitor_db.PLATAFORMA.get(it["hw_type"], ""))
        # o rotulo da plataforma ("VMware", "oVirt") descreve um agrupador,
        # mas seria um SO errado numa maquina: ali so vale a propriedade real
        so = leitor_db.valor(it, "os")
        if not so and it["classe"] == "agrupador":
            so = it["hw_label"]
        g.define(n, "os", so)
        g.define(n, "mod", leitor_db.valor(it, "mod"))
        g.define(n, "chs", leitor_db.valor(it, "chs"))
        g.define(n, "fn", leitor_db.valor(it, "fn"))
        g.define(n, "st", estado_normalizado(leitor_db.valor(it, "st")))
        g.registra_ips(n, re.split(r"[;,\s]+", leitor_db.valor(it, "ips")))

    # a hierarquia que o produto enxerga: datacenter > cluster > esxi > vm.
    # Relacoes que passam por um artefato sao descartadas junto com ele.
    arestas = 0
    for pai, filho in dados["relacoes"]:
        if pai in guardados and filho in guardados and pai != filho:
            g.aresta(itens[pai]["label"], itens[filho]["label"], [],
                     rotulo, rotulo, tipo="hospeda")
            arestas += 1

    return len(guardados), arestas


def carrega_arvore(g, dir_data):
    """O inventario que os coletores gravam em data/<Plataforma>/, sem banco.

    data.db so existe com a integracao Xormon ligada; estes arquivos existem em
    qualquer instalacao, e sao a unica fonte de oVirt, Nutanix, Proxmox,
    Kubernetes, OpenShift, FusionCompute, Cloudstack e OracleVM."""
    dados = leitor_arvore.ler_tudo(dir_data)
    for caminho, erro in dados["erros"]:
        sys.stderr.write("topo-build: %s: %s\n" % (caminho, erro))

    itens = dados["itens"]
    if not itens:
        return 0, 0, []

    guardados = {}
    for uuid, it in itens.items():
        n = g.no(it["label"], it["label"])
        if n is None:
            continue
        guardados[uuid] = norm_host(n["id"])
        n["col"] = True                 # veio de coleta, nao de planilha
        g.define(n, "plat", it["plataforma"])

    arestas = 0
    for pai, filho in dados["relacoes"]:
        if pai in guardados and filho in guardados and pai != filho:
            plat = itens[pai]["plataforma"]     # nao reaproveitar it: o laco
                                                 # anterior deixou o ultimo item
            g.aresta(itens[pai]["label"], itens[filho]["label"], [],
                     plat, plat, tipo="hospeda")
            arestas += 1

    return len(guardados), arestas, dados["plataformas"]


# ==================================================================== main
def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    base, saida = sys.argv[1], sys.argv[2]

    g = Grafo()

    # A ordem importa: o inventario casa contra nos que ja existem, entao vem
    # por ultimo. Como o primeiro valor nao vazio vence, os coletores mandam
    # em plataforma e SO, e o baseline preenche o que ninguem observou.
    # o que foi subido pela tela de importacao, cada um para o seu leitor
    inventarios, coletas = separa_uploads(os.path.join(base, "uploads"))

    n_con, serial_lparid = carrega_fatos(g, base, coletas)

    # o inventario normalizado dos dois produtos, se estiverem instalados lado
    # a lado ou se este for um deles
    n_db = a_db = 0
    for caminho, rotulo in bancos(base):
        i, a = carrega_banco(g, caminho, rotulo)
        n_db += i
        a_db += a

    # o inventario que os coletores gravam em data/, que nao depende de banco
    n_arv, a_arv, plats = carrega_arvore(
        g, os.path.join(os.path.dirname(os.path.abspath(base)), "data"))

    n_bas = carrega_baseline(g, inventarios)
    n_inv = carrega_inventario(g, os.path.join(base, "facts", "inventory.csv"),
                               serial_lparid)

    dados = g.json()

    # grava por arquivo temporario: a pagina pode estar sendo lida agora
    tmp = saida + ".novo"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(dados, f, ensure_ascii=False, separators=(",", ":"))
    os.rename(tmp, saida)

    if not (n_db or n_arv or n_inv or n_con or n_bas):
        sys.stderr.write("topo-build: nenhuma fonte de dados encontrada.\n")
        sys.stderr.write("topo-build: data.db procurado em:\n")
        for c in TENTADOS:
            sys.stderr.write("topo-build:   %s\n" % c)
        sys.stderr.write("topo-build: inventario das plataformas procurado em "
                         "data/<Plataforma>/conf.json e data/oVirt/"
                         "metadata.json\n")

    if plats:
        print("topo-build: plataformas em data/: "
              + ", ".join("%s=%d" % (p, n) for p, n in plats))
    print("topo-build: %d itens do inventario dos produtos (%d ligacoes), "
          "%d de data/ (%d ligacoes), "
          "%d LPAR do Power, %d hosts coletados, %d linhas de baseline"
          % (n_db, a_db, n_arv, a_arv, n_inv, n_con, n_bas))
    print("topo-build: %d nos, %d ligacoes -> %s"
          % (len(dados["nodes"]), len(dados["links"]), saida))
    return 0


if __name__ == "__main__":
    sys.exit(main())
