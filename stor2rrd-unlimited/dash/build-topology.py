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

BOOTSTRAP = '''<script>
(async function(){
"use strict";
const D = await (async function(){
  const alvo = document.body;
  try {
    const r = await fetch("topologia.json", { cache: "no-cache" });
    if (!r.ok) throw new Error("HTTP " + r.status);
    return await r.json();
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
    html = html.replace(OLD_HEAD, BOOTSTRAP, 1)

    # an async IIFE returns a promise; the fetch failure is already reported
    # on the page, so keep it from surfacing again as an unhandled rejection
    tail = "})();\n</script>\n"
    if not html.endswith(tail + "</body>\n</html>\n"):
        sys.exit("build-topology.py: unexpected tail, refusing to patch blindly")
    html = html.replace(tail, "})().catch(function(){});\n</script>\n", 1)

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
