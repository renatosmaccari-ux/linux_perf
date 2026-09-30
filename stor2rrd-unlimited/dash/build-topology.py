#!/usr/bin/env python3
"""Turn a self-contained topology export into a page the products can serve.

The export ships its data inline and pulls d3 and IBM Plex from the public
internet. A monitoring host has no reason to reach either, and often cannot,
so this:

  - splits the inline JSON out to topologia.json, fetched at load time, so the
    map can be refreshed without touching the page or rebuilding a package
  - inlines d3 from a local copy and drops the CDN tag
  - drops the Google Fonts links; the stylesheet already falls back to
    system-ui / ui-monospace

Usage: build-topology.py <export.html> <d3.min.js> <outdir>
"""

import re, sys, os, json

DATA_TAG = re.compile(
    r'<script id="dados" type="application/json">(.*?)</script>\n?', re.S)
CDN_D3 = re.compile(r'[ \t]*<script src="https://cdnjs\.cloudflare\.com[^"]*"></script>\n')
FONT_LINKS = re.compile(
    r'[ \t]*<link rel="preconnect" href="https://fonts\.(?:googleapis|gstatic)\.com"[^>]*>\n'
    r'|[ \t]*<link href="https://fonts\.googleapis\.com[^"]*" rel="stylesheet">\n')

VAZIO = (
  '<div style="position:fixed;inset:0;display:grid;place-items:center;padding:24px;'
  'pointer-events:none"><div style="max-width:520px;background:var(--painel,#1C232C);'
  'border:1px solid var(--linha,#2B3542);border-radius:10px;padding:20px 22px;'
  'pointer-events:auto;font:14px/1.6 system-ui,sans-serif">'
  '<div style="font-weight:600;margin-bottom:8px">Nenhum dado ainda</div>'
  '<div style="color:var(--suave,#8A97A6)">O mapa e montado a cada ciclo de coleta a partir de tres fontes:'
  '<ul style="margin:10px 0 0;padding-left:20px">'
  '<li>o inventario que o LPAR2RRD/STOR2RRD ja coleta (frames, LPARs, VIOS);</li>'
  '<li>a planilha ou CSV de inventario que voce importar;</li>'
  '<li>as conexoes TCP observadas pelos coletores Unix e Windows.</li></ul>'
  '<p style="margin:12px 0 0">Para comecar, use <b>Inventario &rsaquo; Importar '
  'planilha ou CSV</b> no painel a direita.</p></div></div></div>'
)

# ---------------------------------------------------------------- importacao
# O painel do mapa ganha a importacao: quem esta olhando o grafo enriquece os
# dados sem sair dele. __TOPO_CGI__ e trocado pelo apply.sh, que sabe se o
# produto e lpar2rrd ou stor2rrd.
IMPORT_CSS = """
.modal{position:fixed;inset:0;background:rgba(0,0,0,.55);display:grid;
  place-items:center;z-index:9}
/* display:grid sobrepoe o hidden do navegador: sem isto o modal invisivel
   continua capturando os cliques do painel */
.modal[hidden]{display:none}
.modal-caixa{width:min(440px,92vw);background:var(--painel);
  border:1px solid var(--linha);border-radius:10px;padding:18px 20px}
.modal-caixa h3{margin:0 0 6px;font-size:14px}
.modal-caixa p{margin:0 0 14px;font-size:12.5px;color:var(--suave);line-height:1.5}
.modal-caixa input[type=file]{width:100%;padding:9px;background:var(--fundo);
  border:1px dashed var(--linha);border-radius:6px;margin-bottom:12px}
.modal-acoes{display:flex;gap:8px;justify-content:flex-end}
.modal-acoes button{width:auto;padding:7px 14px}
.imp-msg{margin-top:12px;font-size:12.5px;line-height:1.5}
.imp-msg.ok{color:var(--linux)} .imp-msg.erro{color:var(--off)}
.imp-estado{font-size:12px;color:var(--suave);margin-top:7px;line-height:1.45}
"""

IMPORT_PAINEL = """
  <div class="divisor"></div>
  <h2>Inventario</h2>
  <div class="campo">
    <button class="acao" id="imp-abrir" type="button">Importar planilha ou CSV…</button>
    <div class="imp-estado" id="imp-estado"></div>
  </div>
"""

IMPORT_MODAL = """
<div class="modal" id="imp-modal" hidden>
  <div class="modal-caixa" role="dialog" aria-modal="true" aria-labelledby="imp-titulo">
    <h3 id="imp-titulo">Importar inventario</h3>
    <p>Aceita <b>.xls</b>, <b>.xlsx</b>, <b>.csv</b> e <b>.txt</b>. Cada aba da
       planilha e lida. Colunas reconhecidas, em portugues ou ingles:
       Hostname, IP Address, Environment, Location, Function,
       Operation Systems, Cluster/Physical Host. As demais sao ignoradas.</p>
    <input type="file" id="imp-arquivo" accept=".csv,.txt,.xls,.xlsx">
    <div class="modal-acoes">
      <button class="acao" id="imp-fechar" type="button">Cancelar</button>
      <button class="acao" id="imp-enviar" type="button">Enviar</button>
    </div>
    <div class="imp-msg" id="imp-msg"></div>
  </div>
</div>
"""

IMPORT_JS = """
(function(){
  "use strict";
  var CGI = "__TOPO_CGI__";
  var modal = document.getElementById("imp-modal");
  var abrir = document.getElementById("imp-abrir");
  var fechar = document.getElementById("imp-fechar");
  var enviar = document.getElementById("imp-enviar");
  var arquivo = document.getElementById("imp-arquivo");
  var msg = document.getElementById("imp-msg");
  var estado = document.getElementById("imp-estado");
  if (!modal || !abrir) return;

  function diz(elem, texto, classe) {
    elem.textContent = texto;
    elem.className = (elem === msg ? "imp-msg " : "imp-estado ") + (classe || "");
  }
  function mostrar(v) {
    modal.hidden = !v;
    if (v) { diz(msg, "", ""); arquivo.value = ""; arquivo.focus(); }
  }

  abrir.addEventListener("click", function(){ mostrar(true); });
  fechar.addEventListener("click", function(){ mostrar(false); });
  modal.addEventListener("click", function(e){ if (e.target === modal) mostrar(false); });
  document.addEventListener("keydown", function(e){
    if (e.key === "Escape" && !modal.hidden) mostrar(false);
  });

  enviar.addEventListener("click", function(){
    if (!arquivo.files || !arquivo.files.length) {
      diz(msg, "Escolha um arquivo.", "erro");
      return;
    }
    var dados = new FormData();
    dados.append("arquivo", arquivo.files[0]);
    enviar.disabled = true;
    diz(msg, "Enviando e reconstruindo o mapa…", "");

    fetch(CGI + "?fmt=json", { method: "POST", body: dados, credentials: "same-origin" })
      .then(function(r){
        // um CGI que falhou devolve HTML de erro, nao JSON
        return r.text().then(function(t){
          try { return JSON.parse(t); }
          catch (e) { throw new Error("HTTP " + r.status + " — resposta inesperada"); }
        });
      })
      .then(function(j){
        enviar.disabled = false;
        if (!j.ok) { diz(msg, j.msg, "erro"); return; }
        diz(msg, j.msg + " " + j.nos + " nos, " + j.ligacoes +
                 " ligacoes. Recarregando…", "ok");
        setTimeout(function(){ location.reload(); }, 900);
      })
      .catch(function(e){
        enviar.disabled = false;
        diz(msg, "Falha ao enviar: " + e.message, "erro");
      });
  });

  // O mapa carrega os dados num IIFE assincrono, entao o total so existe
  // depois do fetch: ler uma vez aqui pegaria sempre "nenhum dado".
  var tentativas = 0;
  (function aguarda() {
    var n = window.__TOPO_TOTAL__;
    if (typeof n === "number") {
      diz(estado, n ? (n + " nos no mapa atual.")
                    : "Nenhum dado ainda — importe um inventario.", "");
      return;
    }
    if (++tentativas < 60) setTimeout(aguarda, 200);
    else diz(estado, "", "");
  })();
})();
"""

BOOTSTRAP = '''<script>
(async function(){
"use strict";
const D = await (async function(){
  const alvo = document.body;
  try {
    // sem o parametro variavel o navegador serve o mapa anterior depois de
    // uma importacao: "no-cache" so revalida, e nem todo servidor manda
    // validadores
    const r = await fetch("topologia.json?t=" + Date.now(), { cache: "no-store" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    const d = await r.json();
    if (!d || !d.nodes || d.nodes.length === 0) {
      alvo.insertAdjacentHTML("beforeend", __VAZIO__);
    }
    return d;
  } catch (e) {
    alvo.insertAdjacentHTML("beforeend",
      '<div style="position:fixed;inset:0;display:grid;place-items:center;'
      + 'padding:24px;text-align:center;font:14px system-ui">'
      + 'Nao foi possivel carregar <code>topologia.json</code>: '
      + String(e).replace(/[<&]/g, c => c === "<" ? "&lt;" : "&amp;")
      + '<br><br>O arquivo deve estar no mesmo diretorio desta pagina.</div>');
    throw e;
  }
})();
'''

OLD_HEAD = '''<script>
(function(){
"use strict";
const D = JSON.parse(document.getElementById("dados").textContent);
'''


ANCORA_PAINEL = '\n  <div class="divisor"></div>\n  <h2>Exibição</h2>\n'


def injeta_importacao(html):
    """Put the import control in the map's own panel, so enriching the data
    does not mean leaving the graph."""
    if ANCORA_PAINEL not in html:
        sys.exit("build-topology.py: painel de filtros nao encontrado")
    html = html.replace(ANCORA_PAINEL, "\n" + IMPORT_PAINEL + ANCORA_PAINEL, 1)

    if "</style>\n" not in html:
        sys.exit("build-topology.py: bloco <style> nao encontrado")
    html = html.replace("</style>\n", IMPORT_CSS + "</style>\n", 1)

    # the modal and its script go last, after the map's own IIFE has run
    fim = "</body>\n</html>\n"
    if not html.endswith(fim):
        sys.exit("build-topology.py: fim do documento inesperado")
    html = html[: -len(fim)] + IMPORT_MODAL + "<script>\n" + IMPORT_JS + "</script>\n" + fim

    # the panel reports the current size; the map already computed it
    marcador = 'const NOS = new Map(D.nodes.map(n => [n.id, n]));'
    if marcador in html:
        html = html.replace(
            marcador,
            marcador + '\ntry { window.__TOPO_TOTAL__ = D.nodes.length; } catch (e) {}',
            1)
    return html


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, d3path, outdir = sys.argv[1:]
    html = open(src, encoding="utf-8").read()

    m = DATA_TAG.search(html)
    if not m:
        sys.exit("build-topology.py: no inline <script id=\"dados\"> block found")
    data = m.group(1)
    json.loads(data)                      # refuse to ship a broken payload
    html = DATA_TAG.sub("", html, count=1)

    if OLD_HEAD not in html:
        sys.exit("build-topology.py: the expected bootstrap block was not found")
    import json as _json
    bootstrap = BOOTSTRAP.replace("__VAZIO__", _json.dumps(VAZIO))
    html = html.replace(OLD_HEAD, bootstrap, 1)

    # an async IIFE returns a promise; the fetch failure is already reported
    # on the page, so keep it from surfacing again as an unhandled rejection
    tail = "})();\n</script>\n"
    if not html.endswith(tail + "</body>\n</html>\n"):
        sys.exit("build-topology.py: unexpected tail, refusing to patch blindly")
    html = html.replace(tail, "})().catch(function(){});\n</script>\n", 1)

    html = injeta_importacao(html)

    d3 = open(d3path, encoding="utf-8").read()
    if "d3.min.js" not in d3.split("\n")[0] and "d3js.org" not in d3.split("\n")[0]:
        sys.exit("build-topology.py: %s does not look like a d3 bundle" % d3path)
    if not CDN_D3.search(html):
        sys.exit("build-topology.py: no CDN d3 tag to replace")
    # a function replacement, so backslashes in the bundle are not read as
    # regex template escapes
    inline = "<script>\n" + d3.rstrip("\n") + "\n</script>\n"
    html = CDN_D3.sub(lambda _m: inline, html, count=1)

    html = FONT_LINKS.sub("", html)

    for bad in ("cdnjs.cloudflare.com", "fonts.googleapis.com", "fonts.gstatic.com"):
        if bad in html:
            sys.exit("build-topology.py: %s still referenced after rewrite" % bad)

    os.makedirs(outdir, exist_ok=True)
    open(os.path.join(outdir, "topologia.html"), "w", encoding="utf-8").write(html)
    open(os.path.join(outdir, "topologia.json"), "w", encoding="utf-8").write(data)
    print("  topologia.html : %.1f KB" % (len(html.encode()) / 1024))
    print("  topologia.json : %.1f MB" % (len(data.encode()) / 1048576))


if __name__ == "__main__":
    main()
