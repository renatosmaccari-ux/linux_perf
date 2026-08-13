# =============================================================================
# Module 00 — OS / Kernel identification and patch posture (read-only)
# =============================================================================
mod_os_kernel() {
  CURRENT_MODULE_LABEL="OS/Kernel"
  module_begin "00-os-kernel"
  section "1 · SYSTEM & KERNEL"

  sub "OS / Kernel"
  run "OS Release"   cat /etc/os-release
  run "Kernel"        uname -r
  run "Architecture"  uname -m
  run "Uptime & Load" uptime
  runsh "Timezone"    "timedatectl show --property=Timezone --value 2>/dev/null || date +%Z"
  log "Detected OS family: ${OS_FAMILY} (id=${OS_ID}, pkg-mgr=${PKG_MGR})"

  sub "Pending reboot"
  local pending=""
  case "$OS_FAMILY" in
    rhel)
      if is_cmd needs-restarting; then
        needs-restarting -r &>/dev/null || pending="yes"
      fi ;;
    suse)
      if is_cmd zypper; then
        capture "zypper ps -s 2>/dev/null" | grep -qi 'reboot' && pending="yes"
      fi ;;
    debian)
      [[ -f /var/run/reboot-required ]] && pending="yes" ;;
  esac
  if [[ "$pending" == "yes" ]]; then
    finding MEDIUM sys.pending_reboot "Pending reboot" "Kernel/library updates staged but not yet active"
  else
    log "No pending-reboot indicator found"
  fi

  sub "Security updates available (read-only query)"
  case "$PKG_MGR" in
    dnf|yum)
      runsh "Security updates" "$PKG_MGR -q updateinfo list security 2>/dev/null | head -30 || echo 'unavailable (needs subscription/repo metadata)'"
      local n; n=$(capture "$PKG_MGR -q updateinfo list security 2>/dev/null | wc -l")
      [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && \
        finding MEDIUM sys.security_updates "Security updates pending" "$n security advisories available via $PKG_MGR"
      ;;
    zypper)
      runsh "Patches" "zypper --non-interactive list-patches 2>/dev/null | head -30 || echo 'unavailable'"
      local n; n=$(capture "zypper --non-interactive list-patches 2>/dev/null | grep -c '^ *[0-9]' || true")
      [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && \
        finding MEDIUM sys.security_updates "Patches pending" "$n patches available via zypper"
      ;;
    apt|apt-get)
      runsh "Upgradable packages" "apt list --upgradable 2>/dev/null | head -30"
      local n; n=$(capture "apt list --upgradable 2>/dev/null | tail -n +2 | wc -l")
      [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )) && \
        finding LOW sys.security_updates "Package updates pending" "$n packages upgradable via apt (security subset not separable read-only without unattended-upgrades dry-run)"
      ;;
    *) warn "Unknown package manager — skipping update check" ;;
  esac

  sub "Time synchronization"
  if is_cmd timedatectl; then
    runsh "timedatectl" "timedatectl status 2>/dev/null | grep -Ei 'ntp|sync'"
    capture "timedatectl status 2>/dev/null" | grep -qi "synchronized: yes" || \
      finding MEDIUM sys.ntp "Clock not synchronized" "timedatectl reports NTP not synchronized"
  elif is_cmd chronyc; then
    runsh "chronyc tracking" "chronyc tracking 2>/dev/null"
  else
    warn "No timedatectl/chronyc found to verify clock sync"
  fi

  sub "Mandatory Access Control"
  if is_cmd getenforce; then
    local se; se=$(capture "getenforce")
    log "SELinux mode: ${se:-unknown}"
    [[ "$se" == "Disabled" || "$se" == "Permissive" ]] && \
      finding MEDIUM sys.mac_disabled "SELinux not enforcing" "Current mode: $se"
  elif is_cmd aa-status; then
    runsh "AppArmor status" "aa-status --enabled 2>/dev/null && echo enabled || echo 'not enforcing/unavailable'"
    capture "aa-status --enabled 2>/dev/null" >/dev/null || \
      finding MEDIUM sys.mac_disabled "AppArmor not enforcing" "aa-status reports not enabled"
  else
    log "No SELinux/AppArmor tooling detected"
  fi

  sub "Host firewall"
  local fw="none"
  svc_active firewalld && fw="firewalld"
  svc_active ufw && fw="ufw"
  is_cmd nft && capture "nft list ruleset 2>/dev/null" | grep -q . && fw="${fw/none/nftables}"
  if [[ "$fw" == "none" ]]; then
    finding LOW sys.firewall "No active host firewall detected" "Checked firewalld/ufw/nftables"
  else
    log "Active firewall layer: $fw"
  fi
}
