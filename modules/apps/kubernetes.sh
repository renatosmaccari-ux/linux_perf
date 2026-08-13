# =============================================================================
# Plugin: Kubernetes (node-local view via kubectl, if configured)
# =============================================================================
register_plugin kubernetes "Kubernetes"

app_kubernetes_detect() {
  is_cmd kubectl || svc_active kubelet || proc_up kubelet
}

app_kubernetes_analyze() {
  svc_active kubelet && log "kubelet service is active on this node"

  if ! is_cmd kubectl || ! kubectl version --request-timeout=3s &>/dev/null; then
    warn "kubectl not usable from this host/context — skipping cluster-level checks (kubelet-only host, or no kubeconfig)"
    return
  fi

  runsh "Nodes"          "kubectl get nodes -o wide 2>/dev/null"
  runsh "Node conditions" "kubectl describe nodes 2>/dev/null | grep -A5 'Conditions:' | head -60"
  runsh "Top nodes"       "kubectl top nodes 2>/dev/null || echo 'metrics-server not available'"
  runsh "Top pods"        "kubectl top pods -A 2>/dev/null | head -30 || echo 'metrics-server not available'"
  runsh "Pods not Running" "kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -30"
  runsh "Recent warning events" "kubectl get events -A --field-selector type=Warning 2>/dev/null | tail -30"

  local pressure
  pressure=$(capture "kubectl describe nodes 2>/dev/null | grep -E 'MemoryPressure|DiskPressure|PIDPressure' | grep -v False")
  [[ -n "$pressure" ]] && \
    finding HIGH kubernetes.nodepressure "Node reports resource pressure" "$(echo "$pressure" | tr '\n' '; ')"

  local restarts
  restarts=$(capture "kubectl get pods -A --no-headers 2>/dev/null | awk '{print \$5}' | grep -oE '^[0-9]+' | awk '{s+=\$1} \$1>5{c++} END{print c+0}'")
  [[ "$restarts" =~ ^[0-9]+$ ]] && (( restarts > 0 )) && \
    finding MEDIUM kubernetes.generic "Pods with high restart counts" "$restarts pod(s) with >5 restarts"
}
