#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""topologia-embutida.py - conter a pagina do grafo dentro do #content.

O LPAR2RRD carrega as paginas do menu com jQuery $('#content').load(url): o
HTML e injetado na MESMA pagina, sem iframe. Toda a pagina do grafo usava
position:fixed, que se ancora na janela e nao no elemento pai, de modo que o
mapa cobria o cabecalho, o logo e o conteudo do produto.

Este patch:
  - envolve o corpo num #topo-raiz com position:relative;
  - troca position:fixed por absolute, e 100vh por 100% nas alturas internas,
    de modo que tudo passa a se ancorar nesse contentor;
  - mede a altura disponivel por JS quando embutido, e usa a janela inteira
    quando a pagina e aberta sozinha;
  - acrescenta o botao de voltar.

Uso: topologia-embutida.py <topologia.html>   (edita no lugar)
"""

import io
import re
import sys

MARCA = "xoruxfork: pagina contida"

CSS_NOVO = """
/* xoruxfork: pagina contida -------------------------------------------------
   O produto injeta esta pagina dentro de #content com jQuery .load(), na
   mesma janela. position:fixed se ancora na janela, nao no pai, entao o mapa
   cobria o cabecalho e o menu do LPAR2RRD. Tudo abaixo passa a se ancorar em
   #topo-raiz. */
#topo-raiz{position:relative;width:100%;height:100vh;overflow:hidden;
  background:var(--fundo);color:var(--texto);
  font-family:var(--sans);font-size:14px}
#topo-raiz.embutido{height:600px}      /* o JS mede a altura real ao abrir */
/* o cabecalho vai ate a borda; abre espaco para o botao nao cobrir o resumo */
#topo-raiz .cabecalho{padding-right:150px}
.voltar{position:absolute;top:12px;right:16px;z-index:7;pointer-events:auto;
  background:var(--painel);border:1px solid var(--linha);color:var(--texto);
  border-radius:6px;padding:6px 12px;cursor:pointer;font-size:12.5px;
  text-decoration:none;display:inline-flex;align-items:center;gap:6px}
.voltar:hover{border-color:var(--suave)}
/* -------------------------------------------------------------------------- */
"""

JS_NOVO = """
<script>
/* xoruxfork: pagina contida - altura e botao de voltar.
   Embutida, a pagina ocupa o que sobra da janela abaixo do seu topo; sozinha,
   a janela inteira. */
(function () {
  var raiz = document.getElementById("topo-raiz");
  if (!raiz) { return; }
  var pai = raiz.parentElement;
  var embutido = pai && pai.tagName !== "BODY";

  if (embutido) {
    raiz.className += " embutido";
    var ajusta = function () {
      var topo = raiz.getBoundingClientRect().top;
      var h = window.innerHeight - topo - 8;
      raiz.style.height = (h > 420 ? h : 420) + "px";
    };
    var remede = function () {
      ajusta();
      // o desenho se dimensiona no resize; a altura so e conhecida agora
      try { window.dispatchEvent(new Event("resize")); }
      catch (e) {
        var ev = document.createEvent("Event");
        ev.initEvent("resize", true, true);
        window.dispatchEvent(ev);
      }
    };
    ajusta();
    window.addEventListener("resize", ajusta);
    // o produto troca o conteudo sem recarregar: remede quando reaparecer
    if (window.setTimeout) { window.setTimeout(remede, 60); window.setTimeout(remede, 400); }
  } else {
    document.documentElement.style.height = "100%";
    document.body.style.height = "100%";
    document.body.style.margin = "0";
  }

  var btn = document.getElementById("topo-voltar");
  if (btn) {
    btn.addEventListener("click", function (e) {
      e.preventDefault();
      if (embutido && window.history.length > 1) { window.history.back(); }
      else { window.location.href = btn.getAttribute("data-inicio"); }
    });
  }
})();
</script>
"""

BOTAO = ('<a class="voltar" id="topo-voltar" href="../" data-inicio="../"'
         ' title="Voltar ao LPAR2RRD">&#8592; LPAR2RRD</a>\n')


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    caminho = sys.argv[1]
    html = io.open(caminho, encoding="utf-8").read()

    if MARCA in html:
        print("ja aplicado")
        return 0

    trocas = {}

    # 1. o CSS novo, logo antes do fecho do <style> que define o layout
    alvo = "#tela{position:fixed;inset:0;display:block;cursor:grab}"
    if alvo not in html:
        sys.exit("topologia-embutida: ancora #tela nao encontrada")
    html = html.replace(alvo, CSS_NOVO.strip() + "\n\n" + alvo, 1)
    trocas["css"] = 1

    # 2. o body do produto nao pode levar os estilos de pagina inteira
    velho = "html,body{height:100%;margin:0}\nbody{background:var(--fundo);"
    if velho in html:
        html = html.replace(
            velho,
            "html,body{margin:0}\n"
            "/* xoruxfork: o fundo e a fonte agora vivem em #topo-raiz, para\n"
            "   nao vazarem para a pagina que hospeda esta */\n"
            "#topo-raiz{background:var(--fundo);", 1)
        trocas["body"] = 1

    # 3. fixed -> absolute, em regra e em style= inline
    html, n = re.subn(r"position:\s*fixed", "position:absolute", html)
    trocas["fixed"] = n

    # 4. alturas relativas a janela passam a ser relativas ao contentor
    html, n = re.subn(r"calc\(100vh\s*-\s*(\d+)px\)", r"calc(100% - \1px)", html)
    trocas["vh"] = n

    # 5. o aviso "nenhum dado" era inserido em document.body, portanto fora do
    #    contentor: ficava absoluto sobre a janela inteira, cobrindo o produto
    velho = "const alvo = document.body;"
    if velho in html:
        html = html.replace(
            velho,
            'const alvo = document.getElementById("topo-raiz")'
            ' || document.body;   // xoruxfork: dentro do contentor', 1)
        trocas["alvo"] = 1

    # 6. o canvas se media pela janela; passa a medir o contentor, que e a
    #    janela inteira quando a pagina abre sozinha
    velho = "  L = innerWidth; A = innerHeight;"
    if velho in html:
        html = html.replace(
            velho,
            "  // xoruxfork: medir o contentor, nao a janela\n"
            "  { const _r = document.getElementById(\"topo-raiz\");\n"
            "    L = _r ? _r.clientWidth  : innerWidth;\n"
            "    A = _r ? _r.clientHeight : innerHeight; }", 1)
        trocas["canvas"] = 1

    # 7. embrulha o corpo e poe o botao
    m = re.search(r"<body[^>]*>\n", html)
    if not m:
        sys.exit("topologia-embutida: <body> nao encontrado")
    fim = html.rfind("</body>")
    if fim < 0:
        sys.exit("topologia-embutida: </body> nao encontrado")
    html = (html[:m.end()]
            + '<div id="topo-raiz">\n' + BOTAO
            + html[m.end():fim]
            + "</div>\n" + JS_NOVO.strip() + "\n"
            + html[fim:])
    trocas["raiz"] = 1

    io.open(caminho, "w", encoding="utf-8").write(html)
    print("topologia-embutida: %s" % ", ".join(
        "%s=%d" % (k, v) for k, v in sorted(trocas.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
