# =============================================================================
# Module 10 — Application stack detection & plugin dispatch (read-only)
#
# Adding support for a new product does NOT require touching this file:
# drop a new modules/apps/<name>.sh that calls register_plugin and defines
# app_<key>_detect()/app_<key>_analyze(), and it is picked up automatically.
# =============================================================================

load_app_plugins() {
  local f
  for f in "$MODULES_DIR"/apps/*.sh; do
    [[ -f "$f" ]] || continue
    # shellcheck disable=SC1090
    source "$f"
  done
}

detect_apps() {
  CURRENT_MODULE_LABEL="Stack Detection"
  module_begin "10-detect-stack"
  section "8 · APPLICATION DETECTION"

  local key detect_fn found=()
  for key in "${APP_PLUGIN_KEYS[@]}"; do
    detect_fn="app_${key}_detect"
    if declare -f "$detect_fn" >/dev/null 2>&1 && "$detect_fn" 2>/dev/null; then
      register_app "$key" "${APP_LABELS[$key]}"
      found+=("${APP_LABELS[$key]}")
    fi
  done

  # Generic catch-all: surface active services / listening ports that were
  # not matched by a dedicated plugin, so nothing running is silently ignored.
  sub "Active systemd services (all, for cross-reference)"
  runsh "systemctl list-units" "systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '{print \$1}' | sort"

  sub "All listening TCP/UDP ports"
  is_cmd ss && runsh "ss -tulpn" "ss -tulpn 2>/dev/null"

  if [[ ${#found[@]} -eq 0 ]]; then
    log "No recognized application stack detected by dedicated plugins — see the generic service/port listing above."
  else
    echo -e "\n${B}${G}Detected stack:${X}" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    printf '  * %s\n' "${found[@]}" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  fi
}

analyze_detected_apps() {
  local key analyze_fn
  for key in "${!DETECTED[@]}"; do
    analyze_fn="app_${key}_analyze"
    if declare -f "$analyze_fn" >/dev/null 2>&1; then
      CURRENT_MODULE_LABEL="${DETECTED[$key]}"
      module_begin "app-${key}"
      section "APP · ${DETECTED[$key]}"
      "$analyze_fn"
    fi
  done
}
