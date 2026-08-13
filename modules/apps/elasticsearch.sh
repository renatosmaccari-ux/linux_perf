# =============================================================================
# Plugin: Elasticsearch / OpenSearch
# =============================================================================
register_plugin elasticsearch "Elasticsearch/OpenSearch"

app_elasticsearch_detect() {
  svc_active elasticsearch || proc_up elasticsearch || svc_active opensearch || proc_up opensearch
}

app_elasticsearch_analyze() {
  local base="http://localhost:9200"
  if ! curl -sf --max-time 5 "${base}/_cluster/health" &>/dev/null; then
    warn "Elasticsearch/OpenSearch REST API not reachable on ${base}"
    return
  fi

  runsh "Cluster health" "curl -s '${base}/_cluster/health?pretty'"
  runsh "Node stats (jvm, indices)" "curl -s '${base}/_nodes/stats/jvm,indices?pretty' | head -100"
  runsh "Indices (top 20 by size)" "curl -s '${base}/_cat/indices?v&s=store.size:desc' | head -20"
  runsh "Pending tasks" "curl -s '${base}/_cluster/pending_tasks?pretty'"

  local status
  status=$(capture "curl -s '${base}/_cluster/health' | grep -oP '(?<=\"status\":\")[a-z]+'")
  if [[ "$status" == "red" ]]; then
    finding CRITICAL elasticsearch.cluster_health "Cluster health RED" "One or more primary shards unassigned"
  elif [[ "$status" == "yellow" ]]; then
    finding MEDIUM elasticsearch.cluster_health "Cluster health YELLOW" "Replica shards unassigned"
  fi

  local heap_pct
  heap_pct=$(capture "curl -s '${base}/_nodes/stats/jvm' | grep -oP '(?<=\"heap_used_percent\":)[0-9]+' | sort -rn | head -1")
  [[ "$heap_pct" =~ ^[0-9]+$ ]] && (( heap_pct > 85 )) && \
    finding MEDIUM elasticsearch.heap "JVM heap usage high on at least one node" "${heap_pct}% heap used"
}
