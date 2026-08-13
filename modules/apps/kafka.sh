# =============================================================================
# Plugin: Apache Kafka
# =============================================================================
register_plugin kafka "Apache Kafka"

app_kafka_detect() {
  svc_active kafka || proc_up kafka
}

_kafka_bin() {
  local name="$1" p
  for p in /opt/kafka*/bin/"$name" /usr/share/kafka*/bin/"$name" /usr/local/kafka*/bin/"$name"; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  is_cmd "$name" && { echo "$name"; return 0; }
  return 1
}

app_kafka_analyze() {
  ps aux | grep "[k]afka.Kafka" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  local topics_bin
  topics_bin=$(_kafka_bin kafka-topics.sh || true)
  if [[ -n "$topics_bin" ]]; then
    runsh "Topics"                      "$topics_bin --bootstrap-server localhost:9092 --list 2>/dev/null | head -30"
    runsh "Under-replicated partitions" "$topics_bin --bootstrap-server localhost:9092 --describe --under-replicated-partitions 2>/dev/null"
    local urp
    urp=$(capture "$topics_bin --bootstrap-server localhost:9092 --describe --under-replicated-partitions 2>/dev/null | wc -l")
    [[ "$urp" =~ ^[0-9]+$ ]] && (( urp > 0 )) && \
      finding HIGH kafka.generic "Under-replicated partitions present" "$urp partition(s)"
  else
    warn "kafka-topics.sh not found in common install paths — skipping topic/ISR checks"
  fi

  local groups_bin
  groups_bin=$(_kafka_bin kafka-consumer-groups.sh || true)
  [[ -n "$groups_bin" ]] && runsh "Consumer groups" "$groups_bin --bootstrap-server localhost:9092 --list 2>/dev/null | head -20"
}
