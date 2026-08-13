# =============================================================================
# Plugin: Java / JVM
# =============================================================================
register_plugin java "Java/JVM"

app_java_detect() {
  pgrep -fa "java " &>/dev/null || pgrep -x java &>/dev/null
}

app_java_analyze() {
  is_cmd java && run "Java version" java -version

  sub "JVM processes"
  ps aux | grep "[j]ava" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Per-JVM memory, heap & threads"
  while IFS= read -r pid; do
    echo -e "\n--- PID $pid ---" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    is_cmd jstat && jstat -gcutil "$pid" 2>/dev/null | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    is_cmd jcmd  && jcmd "$pid" VM.flags 2>/dev/null | head -3 | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    if [[ -f "/proc/$pid/status" ]]; then
      awk '/VmRSS/{print "RSS: "$2,$3}' "/proc/$pid/status" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
      echo "Threads: $(ls "/proc/$pid/task" 2>/dev/null | wc -l)" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    fi

    if is_cmd jstat; then
      local old_pct
      old_pct=$(jstat -gcutil "$pid" 2>/dev/null | awk 'NR==2{print $4}')
      [[ "$old_pct" =~ ^[0-9.]+$ ]] && awk "BEGIN{exit !($old_pct > 90)}" && \
        finding MEDIUM java.heap "JVM old-gen heap usage high" "PID $pid: old-gen ${old_pct}% used — risk of frequent full GCs"
    fi
  done < <(pgrep java 2>/dev/null || true)

  sub "GC logs (last 30 lines each, if present)"
  find /var /opt /home -maxdepth 8 -name "gc*.log" -newer /proc/1 -size +0c 2>/dev/null | head -5 \
    | while read -r f; do
        echo "--- $f ---" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
        tail -30 "$f"    | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
      done
}
