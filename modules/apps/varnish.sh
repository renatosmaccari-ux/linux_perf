# =============================================================================
# Plugin: Varnish Cache
# =============================================================================
register_plugin varnish "Varnish Cache"

app_varnish_detect() {
  svc_active varnish || proc_up varnishd
}

app_varnish_analyze() {
  is_cmd varnishstat && run "Stats snapshot" varnishstat -1
  is_cmd varnishadm  && runsh "Backend health" "varnishadm backend.list 2>/dev/null || true"

  local hit miss ratio
  hit=$(capture "varnishstat -1 2>/dev/null | awk '/cache_hit /{print \$2}'")
  miss=$(capture "varnishstat -1 2>/dev/null | awk '/cache_miss /{print \$2}'")
  if [[ "$hit" =~ ^[0-9]+$ && "$miss" =~ ^[0-9]+$ ]] && (( hit + miss > 0 )); then
    ratio=$(( hit * 100 / (hit + miss) ))
    log "Cache hit ratio: ${ratio}%"
    (( ratio < 80 )) && finding MEDIUM varnish.generic "Low Varnish cache hit ratio" "${ratio}% (hits=${hit}, misses=${miss})"
  fi
}
