#!/usr/bin/env bash
# =============================================================================
# generate_html.sh — Builds a self-contained, management-oriented HTML report
# from the findings/stack data collected by bin/linux-perf-analyzer.sh.
#
# Usage: generate_html.sh OUTPUT_DIR HOST SCRIPT_VERSION OS_PRETTY OS_FAMILY
# =============================================================================
set -uo pipefail

OUTPUT_DIR="${1:?OUTPUT_DIR required}"
HOST_="${2:-unknown-host}"
SCRIPT_VERSION="${3:-0.0.0}"
OS_PRETTY="${4:-unknown OS}"
OS_FAMILY="${5:-unknown}"

FS_SEP=$'\x1f'
FINDINGS_DB="$OUTPUT_DIR/findings.dat"
STACK_DB="$OUTPUT_DIR/stack.dat"
OUT_HTML="$OUTPUT_DIR/report.html"
NOW_HUMAN=$(date "+%Y-%m-%d %H:%M:%S %Z")

[[ -f "$FINDINGS_DB" ]] || : > "$FINDINGS_DB"
[[ -f "$STACK_DB" ]]    || : > "$STACK_DB"

html_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  printf '%s' "$s"
}

sev_rank() {
  case "$1" in
    CRITICAL) echo 0 ;;
    HIGH)     echo 1 ;;
    MEDIUM)   echo 2 ;;
    LOW)      echo 3 ;;
    *)        echo 4 ;;
  esac
}

sev_color() {
  case "$1" in
    CRITICAL) echo "#dc2626" ;;
    HIGH)     echo "#ea580c" ;;
    MEDIUM)   echo "#ca8a04" ;;
    LOW)      echo "#2563eb" ;;
    *)        echo "#16a34a" ;;
  esac
}

# ── Counts ───────────────────────────────────────────────────────────────
CRIT=$(awk -F"$FS_SEP" '$1=="CRITICAL"' "$FINDINGS_DB" | wc -l | tr -d ' ')
HIGH=$(awk -F"$FS_SEP" '$1=="HIGH"'     "$FINDINGS_DB" | wc -l | tr -d ' ')
MED=$(awk -F"$FS_SEP"  '$1=="MEDIUM"'   "$FINDINGS_DB" | wc -l | tr -d ' ')
LOW=$(awk -F"$FS_SEP"  '$1=="LOW"'      "$FINDINGS_DB" | wc -l | tr -d ' ')
INFO=$(awk -F"$FS_SEP" '$1=="INFO"'     "$FINDINGS_DB" | wc -l | tr -d ' ')
TOTAL=$(( CRIT + HIGH + MED + LOW + INFO ))

SCORE=$(( 100 - (CRIT*20) - (HIGH*10) - (MED*5) - (LOW*2) ))
(( SCORE < 0 )) && SCORE=0
if   (( SCORE >= 90 )); then RISK_LABEL="Healthy";        RISK_COLOR="#16a34a"
elif (( SCORE >= 70 )); then RISK_LABEL="Needs Attention"; RISK_COLOR="#ca8a04"
elif (( SCORE >= 40 )); then RISK_LABEL="At Risk";         RISK_COLOR="#ea580c"
else                          RISK_LABEL="Critical Risk";   RISK_COLOR="#dc2626"
fi

# ── Detected stack chips ─────────────────────────────────────────────────
build_stack_chips() {
  if [[ ! -s "$STACK_DB" ]]; then
    echo '<span class="chip chip-muted">No dedicated stack plugin matched — see generic service listing in appendix</span>'
    return
  fi
  while IFS="$FS_SEP" read -r key label; do
    [[ -z "$key" ]] && continue
    printf '<span class="chip">%s</span>\n' "$(html_escape "$label")"
  done < "$STACK_DB"
}

# ── Findings table rows (sorted: severity rank, then category) ──────────
build_findings_rows() {
  local tmp; tmp=$(mktemp)
  while IFS="$FS_SEP" read -r sev cat mod title detail rec ref; do
    [[ -z "$sev" ]] && continue
    printf '%s%s%s\n' "$(sev_rank "$sev")" "$FS_SEP" \
      "${sev}${FS_SEP}${cat}${FS_SEP}${mod}${FS_SEP}${title}${FS_SEP}${detail}${FS_SEP}${rec}${FS_SEP}${ref}" >> "$tmp"
  done < "$FINDINGS_DB"

  sort -t "$FS_SEP" -k1,1n "$tmp" | cut -d "$FS_SEP" -f2- | \
  while IFS="$FS_SEP" read -r sev cat mod title detail rec ref; do
    [[ -z "$sev" ]] && continue
    local color; color=$(sev_color "$sev")
    cat <<ROW
<tr class="finding-row" data-sev="$(html_escape "$sev")">
  <td><span class="badge" style="background:${color}">$(html_escape "$sev")</span></td>
  <td>$(html_escape "$cat")</td>
  <td>$(html_escape "$mod")</td>
  <td class="title-cell">$(html_escape "$title")</td>
  <td>$(html_escape "$detail")</td>
  <td>$(html_escape "$rec")</td>
  <td class="ref-cell">$(html_escape "$ref")</td>
</tr>
ROW
  done
  rm -f "$tmp"
}

# ── Appendix: raw per-module output files ────────────────────────────────
build_appendix_rows() {
  find "$OUTPUT_DIR/modules" -maxdepth 1 -type f -name '*.txt' 2>/dev/null | sort | while read -r f; do
    local base rel size
    base=$(basename "$f")
    rel="modules/$base"
    size=$(du -h "$f" 2>/dev/null | cut -f1)
    printf '<li><a href="%s">%s</a> <span class="muted">(%s)</span></li>\n' \
      "$(html_escape "$rel")" "$(html_escape "$base")" "$(html_escape "$size")"
  done
}

# ── References (deduped, from findings actually raised) ─────────────────
build_reference_list() {
  awk -F"$FS_SEP" '{print $7}' "$FINDINGS_DB" | sort -u | while read -r ref; do
    [[ -z "$ref" || "$ref" == "N/A" ]] && continue
    printf '<li>%s</li>\n' "$(html_escape "$ref")"
  done
}

{
cat <<HTML_HEAD
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Linux Performance Analysis — $(html_escape "$HOST_")</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root{
    --bg:#f5f6f8; --surface:#ffffff; --text:#1a1d23; --muted:#5b6270;
    --border:#e3e5ea; --accent:#2563eb; --shadow:0 1px 3px rgba(0,0,0,.08);
  }
  @media (prefers-color-scheme: dark){
    :root{ --bg:#14161a; --surface:#1c1f26; --text:#e8eaed; --muted:#9aa1ac;
           --border:#2b2f38; --accent:#5b8def; --shadow:0 1px 3px rgba(0,0,0,.4); }
  }
  *{box-sizing:border-box}
  :root{color-scheme:light dark}
  a{color:var(--accent)}
  body{
    margin:0; background:var(--bg); color:var(--text);
    font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;
    line-height:1.5;
  }
  .wrap{max-width:1180px; margin:0 auto; padding:32px 20px 80px}
  header.top{
    background:var(--surface); border:1px solid var(--border); border-radius:12px;
    padding:24px 28px; box-shadow:var(--shadow); margin-bottom:24px;
    display:flex; flex-wrap:wrap; gap:24px; justify-content:space-between; align-items:center;
  }
  header.top h1{margin:0 0 6px; font-size:22px}
  header.top .meta{color:var(--muted); font-size:13.5px}
  header.top .meta div{margin:2px 0}
  .score-wrap{text-align:center; min-width:140px}
  .score{font-size:42px; font-weight:700}
  .score-label{
    display:inline-block; margin-top:4px; padding:4px 12px; border-radius:999px;
    font-size:12.5px; font-weight:600; color:#fff;
  }
  section{margin-bottom:28px}
  h2{font-size:16px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); margin:0 0 12px}
  .card-grid{display:grid; grid-template-columns:repeat(5,1fr); gap:12px}
  .stat-card{
    background:var(--surface); border:1px solid var(--border); border-radius:10px;
    padding:16px; text-align:center; box-shadow:var(--shadow);
  }
  .stat-card .n{font-size:26px; font-weight:700}
  .stat-card .l{font-size:12px; color:var(--muted); text-transform:uppercase; letter-spacing:.03em}
  .chips{display:flex; flex-wrap:wrap; gap:8px}
  .chip{
    background:var(--surface); border:1px solid var(--border); border-radius:999px;
    padding:6px 14px; font-size:13px; box-shadow:var(--shadow);
  }
  .chip-muted{color:var(--muted)}
  table{width:100%; border-collapse:collapse; background:var(--surface); border:1px solid var(--border); border-radius:10px; overflow:hidden}
  thead th{
    text-align:left; font-size:11.5px; text-transform:uppercase; letter-spacing:.03em;
    color:var(--muted); padding:10px 12px; border-bottom:1px solid var(--border); background:rgba(127,127,127,.06);
  }
  tbody td{padding:10px 12px; border-bottom:1px solid var(--border); font-size:13.5px; vertical-align:top}
  tbody tr:last-child td{border-bottom:none}
  .title-cell{font-weight:600; min-width:200px}
  .ref-cell{color:var(--muted); font-size:12px; min-width:220px}
  .badge{color:#fff; font-size:11px; font-weight:700; padding:3px 9px; border-radius:6px; white-space:nowrap}
  .filters{display:flex; gap:8px; margin-bottom:12px; flex-wrap:wrap}
  .filters button{
    border:1px solid var(--border); background:var(--surface); color:var(--text);
    padding:6px 14px; border-radius:999px; font-size:12.5px; cursor:pointer;
  }
  .filters button.active{background:var(--accent); color:#fff; border-color:var(--accent)}
  .empty-state{
    background:var(--surface); border:1px solid var(--border); border-radius:10px;
    padding:28px; text-align:center; color:var(--muted);
  }
  ul.plain{list-style:none; padding:0; margin:0; columns:2; gap:24px}
  ul.plain li{padding:6px 0; font-size:13.5px; border-bottom:1px dashed var(--border)}
  ul.refs{padding-left:18px; font-size:13px; color:var(--muted)}
  ul.refs li{margin:4px 0}
  footer{color:var(--muted); font-size:12px; text-align:center; margin-top:40px}
  .notice{
    background:rgba(37,99,235,.08); border:1px solid rgba(37,99,235,.25); border-radius:10px;
    padding:14px 18px; font-size:13px; color:var(--text); margin-bottom:24px;
  }
  @media (max-width:800px){ .card-grid{grid-template-columns:repeat(2,1fr)} ul.plain{columns:1} }
</style>
</head>
<body>
<div class="wrap">

  <header class="top">
    <div>
      <h1>Linux Server Performance Analysis</h1>
      <div class="meta">
        <div><strong>Host:</strong> $(html_escape "$HOST_")</div>
        <div><strong>OS:</strong> $(html_escape "$OS_PRETTY") ($(html_escape "$OS_FAMILY") family)</div>
        <div><strong>Generated:</strong> $NOW_HUMAN</div>
        <div><strong>Tool version:</strong> $(html_escape "$SCRIPT_VERSION")</div>
      </div>
    </div>
    <div class="score-wrap">
      <div class="score" style="color:${RISK_COLOR}">${SCORE}</div>
      <div class="muted" style="font-size:11.5px; color:var(--muted)">HEALTH SCORE / 100</div>
      <div class="score-label" style="background:${RISK_COLOR}">${RISK_LABEL}</div>
    </div>
  </header>

  <div class="notice">
    This report is the result of <strong>read-only</strong> data collection: no configuration was
    changed, no service was restarted, and no package was installed or upgraded on this host.
    Findings and recommendations are cross-referenced against vendor and upstream best-practice
    documentation (see References at the end of this report).
  </div>

  <section>
    <h2>Executive Summary</h2>
    <div class="card-grid">
      <div class="stat-card"><div class="n" style="color:#dc2626">${CRIT}</div><div class="l">Critical</div></div>
      <div class="stat-card"><div class="n" style="color:#ea580c">${HIGH}</div><div class="l">High</div></div>
      <div class="stat-card"><div class="n" style="color:#ca8a04">${MED}</div><div class="l">Medium</div></div>
      <div class="stat-card"><div class="n" style="color:#2563eb">${LOW}</div><div class="l">Low</div></div>
      <div class="stat-card"><div class="n" style="color:#16a34a">${INFO}</div><div class="l">Info</div></div>
    </div>
  </section>

  <section>
    <h2>Detected Application Stack</h2>
    <div class="chips">
$(build_stack_chips)
    </div>
  </section>

  <section>
    <h2>Findings, Risks &amp; Recommendations ($TOTAL total)</h2>
HTML_HEAD

if (( TOTAL == 0 )); then
  echo '<div class="empty-state">No findings were raised against the configured thresholds — collected metrics were within expected ranges at the time of this snapshot.</div>'
else
  cat <<HTML_TABLE_HEAD
    <div class="filters" id="sevFilters">
      <button data-sev="all" class="active">All ($TOTAL)</button>
      <button data-sev="CRITICAL">Critical ($CRIT)</button>
      <button data-sev="HIGH">High ($HIGH)</button>
      <button data-sev="MEDIUM">Medium ($MED)</button>
      <button data-sev="LOW">Low ($LOW)</button>
      <button data-sev="INFO">Info ($INFO)</button>
    </div>
    <table id="findingsTable">
      <thead>
        <tr>
          <th>Severity</th><th>Category</th><th>Module</th><th>Finding</th>
          <th>Detail</th><th>Recommendation</th><th>Reference</th>
        </tr>
      </thead>
      <tbody>
$(build_findings_rows)
      </tbody>
    </table>
HTML_TABLE_HEAD
fi

cat <<HTML_TAIL
  </section>

  <section>
    <h2>Appendix — Raw Collection Output</h2>
    <ul class="plain">
$(build_appendix_rows)
    </ul>
  </section>

  <section>
    <h2>References</h2>
    <ul class="refs">
$(build_reference_list)
    </ul>
  </section>

  <footer>
    Generated by linux-perf-analyzer.sh v$(html_escape "$SCRIPT_VERSION") — read-only collection, no environment changes.
  </footer>
</div>

<script>
(function(){
  var buttons = document.querySelectorAll('#sevFilters button');
  if(!buttons.length) return;
  buttons.forEach(function(btn){
    btn.addEventListener('click', function(){
      buttons.forEach(function(b){ b.classList.remove('active'); });
      btn.classList.add('active');
      var sev = btn.getAttribute('data-sev');
      document.querySelectorAll('.finding-row').forEach(function(row){
        row.style.display = (sev === 'all' || row.getAttribute('data-sev') === sev) ? '' : 'none';
      });
    });
  });
})();
</script>
</body>
</html>
HTML_TAIL
} > "$OUT_HTML"

echo "$OUT_HTML"
