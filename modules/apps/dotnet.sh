# =============================================================================
# Plugin: .NET (dotnet / ASP.NET Core on Linux)
# =============================================================================
register_plugin dotnet ".NET"

app_dotnet_detect() {
  pgrep -f "dotnet" &>/dev/null
}

app_dotnet_analyze() {
  is_cmd dotnet && run "dotnet --info" dotnet --info

  sub "Processes"
  ps aux | grep "[d]otnet" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "RSS per process"
  while IFS= read -r pid; do
    [[ -f "/proc/$pid/status" ]] || continue
    local rss cmd
    rss=$(awk '/VmRSS/{print $2,$3}' "/proc/$pid/status")
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)
    echo "PID $pid  RSS: $rss  |  $cmd" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  done < <(pgrep -f dotnet 2>/dev/null || true)

  sub "GC / runtime environment variables (per process, if set)"
  while IFS= read -r pid; do
    [[ -f "/proc/$pid/environ" ]] || continue
    tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^DOTNET_|^ASPNETCORE_' \
      | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  done < <(pgrep -f dotnet 2>/dev/null || true)
}
