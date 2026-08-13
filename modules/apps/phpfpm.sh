# =============================================================================
# Plugin: PHP-FPM
# =============================================================================
register_plugin phpfpm "PHP-FPM"

app_phpfpm_detect() {
  svc_active php-fpm || proc_up "php-fpm" || pgrep -fa "php[0-9].*fpm" &>/dev/null
}

app_phpfpm_analyze() {
  local php_bin
  php_bin=$(ls /usr/bin/php* 2>/dev/null | sort -V | tail -1)
  [[ -z "$php_bin" ]] && is_cmd php && php_bin=php
  [[ -n "$php_bin" ]] && run "PHP version" "$php_bin" --version || warn "PHP binary not found"

  sub "Pool config"
  local d
  for d in /etc/php/*/fpm/pool.d /etc/php-fpm.d /etc/opt/remi/php*/php-fpm.d; do
    [[ -d "$d" ]] && runsh "Pool files in $d" "ls '$d'"
  done

  sub "FPM status endpoint"
  if curl -sf --max-time 3 "http://127.0.0.1/status?full" &>/dev/null; then
    runsh "fpm-status" "curl -s 'http://127.0.0.1/status?full'"
  else
    finding LOW phpfpm.status "FPM status endpoint not accessible" "Configure pm.status_path in the pool to expose it"
  fi

  sub "Processes"
  ps aux | grep -E "[p]hp-fpm|[p]hp[0-9].*fpm" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "php.ini (key values)"
  [[ -n "$php_bin" ]] && \
    runsh "php -i grep" \
      "$php_bin -i 2>/dev/null | grep -E '^(memory_limit|max_execution_time|upload_max|post_max|error_log|display_errors|opcache)' || true"

  sub "OPcache status"
  local opc_enabled=""
  if [[ -n "$php_bin" ]]; then
    opc_enabled=$(capture "$php_bin -r 'var_export(function_exists(\"opcache_get_status\") && opcache_get_status(false) !== false);' 2>/dev/null")
    runsh "opcache" "$php_bin -r 'print_r(opcache_get_status(false));' 2>/dev/null | head -30 || echo 'OPcache unavailable'"
  fi
  [[ "$opc_enabled" != "true" ]] && \
    finding MEDIUM phpfpm.opcache "OPcache appears disabled or unavailable" "opcache_get_status() returned false/unavailable"
}
