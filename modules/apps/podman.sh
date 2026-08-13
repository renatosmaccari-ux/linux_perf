# =============================================================================
# Plugin: Podman
# =============================================================================
register_plugin podman "Podman"

app_podman_detect() {
  is_cmd podman && { svc_active podman || proc_up podman || podman ps &>/dev/null; }
}

app_podman_analyze() {
  run "Version" podman version

  sub "Running containers"
  podman ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" \
    | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Stats (one-shot)"
  podman stats --no-stream 2>/dev/null | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Disk usage"
  podman system df 2>/dev/null | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Pods"
  podman pod ps 2>/dev/null | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
}
