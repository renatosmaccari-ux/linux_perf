# =============================================================================
# Plugin: RabbitMQ
# =============================================================================
register_plugin rabbitmq "RabbitMQ"

app_rabbitmq_detect() {
  svc_active rabbitmq-server || proc_up rabbitmq
}

app_rabbitmq_analyze() {
  if ! is_cmd rabbitmqctl; then
    warn "rabbitmqctl not found — skipping live metrics"
    return
  fi

  run "Status"         rabbitmqctl status
  run "Queues"         rabbitmqctl list_queues name messages consumers memory
  run "Cluster status" rabbitmqctl cluster_status

  local growing
  growing=$(capture "rabbitmqctl list_queues messages consumers 2>/dev/null | awk '\$1 > 10000 && \$2 == 0'")
  [[ -n "$growing" ]] && \
    finding MEDIUM rabbitmq.generic "Queue(s) with large backlog and zero consumers" "$(echo "$growing" | wc -l) queue(s) affected"
}
