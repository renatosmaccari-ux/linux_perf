# =============================================================================
# lib/os_detect.sh — distro-agnostic OS family detection
# Classifies the host into one of: rhel | suse | debian | unknown
# so modules can pick the right paths / package manager without hard-coding
# a single distro. Detection is pure reads of /etc/os-release — never mutates.
# =============================================================================

OS_ID="unknown"
OS_ID_LIKE=""
OS_VERSION="unknown"
OS_PRETTY="unknown"
OS_FAMILY="unknown"
PKG_MGR="unknown"

detect_os_family() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-unknown}"
  fi

  case " $OS_ID $OS_ID_LIKE " in
    *" rhel "*|*" fedora "*|*" centos "*|*" rocky "*|*" almalinux "*|*" ol "*)
      OS_FAMILY="rhel" ;;
    *" suse "*|*" sles "*|*" opensuse"*)
      OS_FAMILY="suse" ;;
    *" debian "*|*" ubuntu "*)
      OS_FAMILY="debian" ;;
    *)
      OS_FAMILY="unknown" ;;
  esac

  if is_cmd dnf; then PKG_MGR="dnf"
  elif is_cmd yum; then PKG_MGR="yum"
  elif is_cmd zypper; then PKG_MGR="zypper"
  elif is_cmd apt; then PKG_MGR="apt"
  elif is_cmd apt-get; then PKG_MGR="apt-get"
  fi
}

# Returns the first existing path among the given candidates (used to locate
# distro-specific log/config paths without branching everywhere).
first_existing() {
  local p
  for p in "$@"; do
    [[ -e "$p" ]] && { echo "$p"; return 0; }
  done
  return 1
}
