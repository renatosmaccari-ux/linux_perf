# =============================================================================
# Plugin: Docker
# =============================================================================
register_plugin docker "Docker"

app_docker_detect() {
  is_cmd docker && { svc_active docker || proc_up dockerd; }
}

app_docker_analyze() {
  runsh "Version" "docker version --format '{{.Server.Version}}' 2>/dev/null || docker version"
  runsh "Info"    "docker info 2>/dev/null | grep -E 'Containers|Images|Driver|Logging|Kernel|CPUs|Total Memory'"

  sub "Running containers"
  docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}" \
    | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Stats (one-shot)"
  docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}\t{{.BlockIO}}" \
    2>/dev/null | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Images (top 20)"
  docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" \
    | head -21 | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Disk usage"
  docker system df 2>/dev/null | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  # Flag when a large absolute reclaimable figure is present (GB-scale)
  if capture "docker system df 2>/dev/null" | grep -qE '[0-9]{2,}\.?[0-9]*GB'; then
    finding LOW docker.diskusage "Significant reclaimable Docker disk space" "See 'docker system df' output — dangling images/build cache/stopped containers"
  fi

  sub "Networks"
  docker network ls | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Volumes"
  docker volume ls | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Compose projects"
  { docker compose ls 2>/dev/null || docker-compose ls 2>/dev/null; } | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Logging driver / policy per running container"
  local nolimit=0 c
  while IFS= read -r c; do
    [[ -z "$c" ]] && continue
    local logcfg
    logcfg=$(docker inspect --format '{{.HostConfig.LogConfig.Type}} max-size={{index .HostConfig.LogConfig.Config "max-size"}}' "$c" 2>/dev/null)
    echo "$c: $logcfg" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    # json-file with an empty max-size value means unlimited log growth
    [[ "$logcfg" == json-file*"max-size=" ]] && nolimit=$(( nolimit + 1 ))
  done < <(docker ps -q 2>/dev/null)
  (( nolimit > 0 )) && \
    finding MEDIUM docker.logdriver "Containers using json-file logging without size limits" "$nolimit container(s) — unbounded log growth risk"

  sub "Recent events (last hour)"
  docker events --since "1h" --until "$(date -u +%Y-%m-%dT%H:%M:%S)" 2>/dev/null \
    | tail -20 | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
}
