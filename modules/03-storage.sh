# =============================================================================
# Module 03 — Storage (read-only)
# =============================================================================
mod_storage() {
  CURRENT_MODULE_LABEL="Storage"
  module_begin "03-storage"
  section "4 · STORAGE"

  runsh "Disk usage" "df -hT | grep -Ev 'tmpfs|devtmpfs|udev|squashfs'"
  runsh "Inodes"     "df -i  | grep -Ev 'tmpfs|devtmpfs|udev|squashfs'"
  is_cmd iostat && run "I/O stats (1s sample)" iostat -xz 1 1
  runsh "Block devices" "lsblk 2>/dev/null || true"
  runsh "I/O scheduler per device" "for d in /sys/block/*/queue/scheduler; do echo \"\$d: \$(cat \$d 2>/dev/null)\"; done"

  while IFS= read -r line; do
    local pct mnt
    pct=$(awk '{gsub(/%/,""); print $5}' <<<"$line")
    mnt=$(awk '{print $6}' <<<"$line")
    [[ "$pct" =~ ^[0-9]+$ ]] || continue
    if (( pct > 90 )); then
      finding HIGH sys.disk_high "Disk usage critical on $mnt" "${pct}% used"
    elif (( pct > 85 )); then
      finding MEDIUM sys.disk_high "Disk usage high on $mnt" "${pct}% used"
    fi
  done < <(df -h 2>/dev/null | tail -n +2 | grep -Ev "tmpfs|devtmpfs|udev|squashfs")

  while IFS= read -r line; do
    local ipct imnt
    ipct=$(awk '{gsub(/%/,""); print $5}' <<<"$line")
    imnt=$(awk '{print $6}' <<<"$line")
    [[ "$ipct" =~ ^[0-9]+$ ]] || continue
    (( ipct > 85 )) && finding MEDIUM sys.disk_inodes "Inode usage high on $imnt" "${ipct}% inodes used"
  done < <(df -i 2>/dev/null | tail -n +2 | grep -Ev "tmpfs|devtmpfs|udev|squashfs")
}
