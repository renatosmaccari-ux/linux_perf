#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""topologia-ponteiro.py - corrigir a coordenada do ponteiro na pagina contida.

A pagina foi escrita para ocupar a janela inteira: o canvas era
position:fixed;inset:0, portanto o canto dele coincidia com o canto da janela e
ev.clientX/clientY podiam ser usados como coordenada do canvas sem mais nada.

Dentro do LPAR2RRD a pagina e injetada em #content, e topologia-embutida.py
troca fixed por absolute para ela nao cobrir o produto. O canvas passa a comecar
depois do menu lateral e abaixo do cabecalho, mas as tres leituras de clientX
continuavam a trata-lo como se comecasse em zero: o no escolhido pelo clique
ficava deslocado para a direita pela largura do menu, e a dica junto com ele.

Este patch faz as tres lerem a coordenada relativa ao canvas. Aberta sozinha, o
retangulo do canvas e (0,0) e a conta nao muda nada.

Uso: topologia-ponteiro.py <topologia.html>   (edita no lugar; idempotente)
"""

import io
import sys

MARCA = "xoruxfork: ponteiro no contentor"

AJUDA = """
// xoruxfork: ponteiro no contentor
// Dentro do produto o canvas nao comeca no canto da janela. Tudo o que vem de
// um evento do rato tem de descontar o retangulo dele - para o teste de acerto
// e para posicionar a dica, que e absoluta dentro do mesmo contentor.
function _pontoTela(ev){
  const r = tela.getBoundingClientRect();
  return [ev.clientX - r.left, ev.clientY - r.top];
}
"""

TROCAS = [
    # o teste de acerto do clique e do hover
    ("  const [mx, my] = transformacao.invert([ev.clientX, ev.clientY]);",
     "  const [mx, my] = transformacao.invert(_pontoTela(ev));"),
    # a dica e position:absolute dentro de #topo-raiz, nao da janela
    ('    dica.style.left = Math.min(ev.clientX + 14, L - 240) + "px";\n'
     '    dica.style.top = (ev.clientY + 16) + "px";',
     '    const [dx, dy] = _pontoTela(ev);\n'
     '    dica.style.left = Math.min(dx + 14, L - 240) + "px";\n'
     '    dica.style.top = (dy + 16) + "px";'),
]

ANCORA = "// ---- interacao ----\nfunction noEm(ev){"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    caminho = sys.argv[1]
    html = io.open(caminho, encoding="utf-8").read()

    if MARCA in html:
        print("ja aplicado")
        return 0

    if ANCORA not in html:
        sys.exit("topologia-ponteiro: nao achei o bloco de interacao")
    html = html.replace(ANCORA, AJUDA.strip() + "\n\n" + ANCORA, 1)

    feitas = 0
    for velho, novo in TROCAS:
        if velho not in html:
            sys.exit("topologia-ponteiro: trecho nao encontrado:\n%s" % velho)
        html = html.replace(velho, novo, 1)
        feitas += 1

    # as duas unicas leituras cruas que devem sobrar sao as de dentro do
    # proprio _pontoTela; mais do que isso e um trecho que escapou
    if html.count("ev.clientX") != 1 or html.count("ev.clientY") != 1:
        sys.exit("topologia-ponteiro: sobrou leitura crua de clientX/clientY "
                 "(clientX=%d, clientY=%d, esperado 1 de cada)"
                 % (html.count("ev.clientX"), html.count("ev.clientY")))

    io.open(caminho, "w", encoding="utf-8").write(html)
    print("topologia-ponteiro: %d trecho(s) corrigido(s)" % feitas)
    return 0


if __name__ == "__main__":
    sys.exit(main())
