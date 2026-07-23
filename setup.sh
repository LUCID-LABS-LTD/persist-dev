#!/usr/bin/env bash
# Host bootstrap for persist-dev. Installs Podman + Tailscale if missing,
# pulls the prebuilt image, runs the container, and prints the connect command.
#
# Flags / Commands:
#   --status, status    Show container status and port mappings.
#   --logs, logs        Show container logs (tail 50).
#   --restart, restart  Restart the container.
#   --secure            Force a non-default 'dev' password and optionally switch to key-only SSH.
#   --cron              Schedule `dev backup` every 6h to BACKUP_TARGET (writes a host crontab entry).
#   --cron-remove       Remove the scheduled backup cron entry.
# Env (all optional):
#   PORT_SSH=2222          host SSH port mapped to container 22
#   DATA_DIR=~/.persist/workspace   host dir mounted at container /workspace
#   BACKUP_TARGET=...      rsync/rclone target used by `dev backup` and --cron
#   PERSIST_MEM / PERSIST_CPUS   podman --memory / --cpus limits (e.g. 4g / 2.0)
#   MOSH_PORT_RANGE=60000-60050  UDP port range for mosh (defaults to 60000-60050)
set -euo pipefail

IMAGE="ghcr.io/LUCID-LABS-LTD/persist-dev:latest"
CONTAINER="persist-dev"
PORT_SSH="${PORT_SSH:-2222}"
REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(getent passwd "$REAL_USER" 2>/dev/null | cut -d: -f6 || eval echo "~$REAL_USER")
DATA_DIR="${DATA_DIR:-$REAL_HOME/.persist/workspace}"
PODMAN_MEM="${PERSIST_MEM:-}"
PODMAN_CPUS="${PERSIST_CPUS:-}"
MOSH_PORT_RANGE="${MOSH_PORT_RANGE:-60000-60050}"
SECURE=false
CRON=false
CRON_REMOVE=false

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'; else RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; BOLD=''; RESET=''; fi
# Run privileged commands via sudo only when not already root.
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

# Detect the distro's package manager.
detect_pkg() {
  if command -v apt-get >/dev/null 2>&1; then PKG=apt
  elif command -v dnf >/dev/null 2>&1; then PKG=dnf
  elif command -v yum >/dev/null 2>&1; then PKG=yum
  elif command -v pacman >/dev/null 2>&1; then PKG=pacman
  elif command -v zypper >/dev/null 2>&1; then PKG=zypper
  elif command -v apk >/dev/null 2>&1; then PKG=apk
  else PKG=unknown; fi
}

# Install one or more packages with the detected manager.
pkg_install() {
  detect_pkg
  case "$PKG" in
    apt)    $SUDO apt-get update -y >/dev/null 2>&1 || echo -e "  ${YELLOW}[warn]${RESET} [persist-dev] apt update failed; install may use stale indexes" >&2; $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -Sy --noconfirm "$@" ;;
    zypper) $SUDO zypper install -y "$@" ;;
    apk)    $SUDO apk add --no-cache "$@" ;;
    *) echo -e "${RED}${BOLD}[persist-dev] Unsupported package manager — install manually: $*${RESET}" >&2; exit 1 ;;
  esac
}

install_podman() {
  if command -v podman >/dev/null 2>&1; then return 0; fi
  echo -e "${BOLD}${CYAN}== installing podman ==${RESET}"
  command -v curl >/dev/null 2>&1 || pkg_install curl
  pkg_install podman
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then return 0; fi
  echo -e "${BOLD}${CYAN}== installing tailscale ==${RESET}"
  command -v curl >/dev/null 2>&1 || pkg_install curl
  # Tailscale's installer is fetched over HTTPS and run as root (or via sudo).
  # Download to a temp file first rather than piping curl straight into sh.
  local ts_script; ts_script=$(mktemp)
  curl -fsSL https://tailscale.com/install.sh -o "$ts_script"
  $SUDO sh "$ts_script"
  rm -f "$ts_script"
}
# mosh-server runs INSIDE the container (the mosh *client* is on the
# user's laptop). Verify it's present and install into the container if missing.
ensure_mosh() {
  if podman exec "$CONTAINER" command -v mosh-server >/dev/null 2>&1; then
    echo "  mosh-server present in container."
    return 0
  fi
  echo "  mosh-server missing in container; installing..."
  # The container is debian-based, so apt is the right manager here.
  podman exec "$CONTAINER" bash -c \
    "apt-get update -y >/dev/null 2>&1; apt-get install -y mosh" \
    || {
      echo -e "  ${YELLOW}[warn]${RESET} [persist-dev] could not auto-install mosh-server." >&2
      echo "  Install 'mosh' in the container manually; mosh connections" >&2
      echo "  will fail without it." >&2
    }
}

# Check whether any UDP port in MOSH_PORT_RANGE (60000-60050) is bound on the host.
check_mosh_ports() {
  local ports="${MOSH_PORT_RANGE:-60000-60050}"
  if command -v ss >/dev/null 2>&1; then
    local bound
    bound=$(ss -a -u -n 2>/dev/null || true)
    local s="${ports%%-*}"
    local e="${ports##*-}"
    for p in $(seq "$s" "$e" 2>/dev/null || echo "$s"); do
      if echo "$bound" | grep -qE ":$p([[:space:]]|$)"; then
        echo -e "  ${YELLOW}[warn]${RESET} [persist-dev] UDP port $p in range $ports appears in use on host." >&2
        echo "  Free port $p or set MOSH_PORT_RANGE=<start:end>" >&2
        echo "  (note: if you change this range, pass -p <port> to your"
        echo "  mosh client)."
        break
      fi
    done
  fi
}
pull_or_build() {
  echo -e "${BOLD}${CYAN}== checking container image ==${RESET}"
  if podman pull "$IMAGE"; then
    echo -e "${BOLD}${CYAN}== pulled prebuilt image ==${RESET}"
  else
    echo -e "${BOLD}${CYAN}== prebuilt image unavailable; building locally (slower) ==${RESET}"
    if [ ! -f Containerfile ]; then
      echo -e "${RED}${BOLD}[persist-dev] Error: Containerfile not found in current directory ($(pwd)).${RESET}" >&2
      echo "Please run setup.sh from the cloned persist-dev directory." >&2
      exit 1
    fi
    podman build -t persist-dev-local -f Containerfile .
    IMAGE="persist-dev-local"
  fi
}
run_container() {
  check_mosh_ports
  local mosh_ports="${MOSH_PORT_RANGE:-60000-60050}"
  local extra=()
  [ -n "$PODMAN_MEM" ]  && extra+=(--memory "$PODMAN_MEM")
  [ -n "$PODMAN_CPUS" ] && extra+=(--cpus "$PODMAN_CPUS")
  if podman ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    if podman start "$CONTAINER" >/dev/null 2>&1; then
      echo -e "${BOLD}${CYAN}== restarted existing container ==${RESET}"
      ensure_mosh
      return 0
    fi
    echo -e "${BOLD}${CYAN}== container failed to start (stale port spec?); recreating... ==${RESET}"
    podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi

  mkdir -p "$DATA_DIR"/.config "$DATA_DIR"/.codex "$DATA_DIR"/.gemini "$DATA_DIR"/.omp
  # If running under sudo, ensure the real user owns the data directory so
  # rootless Podman (or manual inspections) work without permission errors.
  if [ -n "${SUDO_USER:-}" ]; then
    chown -R "$REAL_USER:$REAL_USER" "$DATA_DIR"
  fi
  # Bind-mount the whole volume at /workspace AND its agent-config subdirs onto
  # the dev home. The subdir mounts are nested inside $DATA_DIR on purpose:
  # /workspace/.config etc. resolve to the very volume paths mounted at
  # /home/dev/.config, so config persists without symlinks.
  podman run -d --name "$CONTAINER" \
      -p "$PORT_SSH:22" \
      -p "$mosh_ports:$mosh_ports/udp" \
      -e "MOSH_PORT_RANGE=$mosh_ports" \
      -v "$DATA_DIR:/workspace" \
      -v "$DATA_DIR/.config:/home/dev/.config" \
      -v "$DATA_DIR/.codex:/home/dev/.codex" \
      -v "$DATA_DIR/.gemini:/home/dev/.gemini" \
      -v "$DATA_DIR/.omp:/home/dev/.omp" \
      --restart unless-stopped \
      "${extra[@]}" \
      "$IMAGE"
  echo -e "${BOLD}${CYAN}== started container (mosh ports: $mosh_ports/udp) ==${RESET}"
  ensure_mosh
  # Best-effort: enable systemd podman-restart service so container resumes on host reboot
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now podman-restart 2>/dev/null || true
  fi
}

secure_server() {
  local ip="$1"
  echo
  echo -e "${BOLD}${CYAN}== SECURE: the 'dev' user ships with password 'dev'. Change it. ==${RESET}"
  read -r -s -p "  new dev password: " pw; echo
  if [ -z "$pw" ]; then
    pw=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)
    echo "  (blank entered) generated random password: $pw"
  fi
  printf 'dev:%s\n' "$pw" | podman exec -i "$CONTAINER" chpasswd
  echo "  password set. Save it now — it will not be shown again."
  echo
  echo "For key-only access (recommended):"
  echo "  ssh-copy-id -p $PORT_SSH dev@$ip"
  if ! podman exec "$CONTAINER" test -s /home/dev/.ssh/authorized_keys 2>/dev/null; then
    echo -e "  ${YELLOW}Warning:${RESET} No SSH keys detected in container."
    echo "  Ensure you have copied your key via:"
    echo "    ssh-copy-id -p $PORT_SSH dev@$ip"
    echo "  before disabling password authentication!"
  fi
  read -r -p "  Disable password SSH auth entirely (key-only)? [y/N] " konly
  if [[ "$konly" =~ ^[Yy]$ ]]; then
    podman exec "$CONTAINER" sh -c "sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config; sshd -t && { pid=\$(cat /run/sshd.pid 2>/dev/null); [ -n \"\$pid\" ] && kill -HUP \$pid || pkill -HUP sshd; } || true"
    echo "  password auth disabled in container; sshd reloaded. Restart the container if sshd didn't pick it up."
  fi
}

# Make sure a cron daemon is installed and running (per distro).
ensure_cron() {
  detect_pkg
  command -v crontab >/dev/null 2>&1 || {
    echo -e "${BOLD}${CYAN}== installing cron ==${RESET}"
    case "$PKG" in
      apt|zypper) pkg_install cron ;;
      dnf|yum|pacman) pkg_install cronie ;;
      apk) pkg_install cron ;;
      *) echo -e "${RED}${BOLD}[persist-dev] Unsupported distro — install a cron daemon manually${RESET}" >&2; exit 1 ;;
    esac
  }
  start_cron
}

# Best-effort: enable + start the cron service under systemd or OpenRC.
start_cron() {
  if [ -d /run/systemd/system ]; then
    local unit
    case "$PKG" in
      apt|zypper) unit=cron ;;
      dnf|yum|pacman) unit=cronie ;;
      apk) unit=crond ;;
      *) unit=cron ;;
    esac
    $SUDO systemctl enable --now "$unit" >/dev/null 2>&1 || true
  elif command -v rc-service >/dev/null 2>&1; then
    $SUDO rc-update add crond default >/dev/null 2>&1 || true
    $SUDO rc-service crond start >/dev/null 2>&1 || true
  else
    $SUDO service cron start >/dev/null 2>&1 || $SUDO service crond start >/dev/null 2>&1 || true
  fi
}

install_cron() {
  local target="${BACKUP_TARGET:-}"
  if [ -z "$target" ]; then
    echo -e "${RED}${BOLD}[persist-dev] Error: BACKUP_TARGET not set; cannot schedule backup.${RESET}" >&2
    echo "Export it first, e.g.:" >&2
    echo "  export BACKUP_TARGET='myserver:/backups/persist'" >&2
    exit 1
  fi
  ensure_cron
  local log="$DATA_DIR/../backup-cron.log"
  local line="0 */6 * * *  BACKUP_TARGET='$target' podman exec '$CONTAINER' dev backup >> '$log' 2>&1"
  ( crontab -l 2>/dev/null | grep -v "persist-dev.*backup"; echo "$line" ) | crontab - || true
  echo -e "${BOLD}${CYAN}== scheduled backup: $line ==${RESET}"
}

remove_cron() {
  ( crontab -l 2>/dev/null | grep -v "persist-dev.*backup" ) | crontab - || true
  echo -e "${BOLD}${CYAN}== removed persist-dev backup cron entry ==${RESET}"
}

usage() {
  cat <<'EOF'
Usage: sudo ./setup.sh [flags | commands]
       sudo TS_AUTHKEY=tskey-xxx ./setup.sh   # headless (no browser login)
       sudo PORT_SSH=2345 ./setup.sh           # custom SSH port
  --status, status    show container status and port mappings
  --logs, logs        show container logs (tail 50)
  --restart, restart  restart the container
  --secure            force a new 'dev' password and optionally go key-only
  --cron              schedule `dev backup` every 6h (needs BACKUP_TARGET set)
  --cron-remove       remove the scheduled backup cron entry
Env (all optional):
  TS_AUTHKEY          tailscale auth key (headless servers) — joins the tailnet without a browser
  PORT_SSH, DATA_DIR, BACKUP_TARGET, PERSIST_MEM, PERSIST_CPUS  (see header)
EOF
}

main() {
  echo -e "${BOLD}${CYAN}======================================================"
  echo "  persist-dev — Resumable Multi-Project Dev Box"
  echo -e "======================================================${RESET}"
  echo "Setting up Podman, Tailscale, and persistent container..."
  echo
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --status|status)
        podman ps -a --filter name="$CONTAINER"
        podman port "$CONTAINER" || true
        exit 0
        ;;
      --logs|logs)
        podman logs --tail 50 "$CONTAINER"
        exit 0
        ;;
      --restart|restart)
        podman restart "$CONTAINER"
        exit 0
        ;;
      --secure)       SECURE=true; shift ;;
      --cron)         CRON=true; shift ;;
      --cron-remove)  CRON_REMOVE=true; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) echo -e "${RED}${BOLD}[persist-dev] unknown flag: $1${RESET}" >&2; usage; exit 1 ;;
    esac
  done
  command -v curl >/dev/null 2>&1 || { detect_pkg; pkg_install curl; }
  install_podman
  install_tailscale
  # Bring the server onto your tailnet. On a headless box, set TS_AUTHKEY to a
  # tailscale.com auth key; otherwise it prints a login URL to open in a browser.
  if [ -n "${TS_AUTHKEY:-}" ]; then
    $SUDO tailscale up --auth-key "$TS_AUTHKEY"
  else
    $SUDO tailscale up
  fi
  pull_or_build
  run_container

  local ip
  ip=$(tailscale ip -4 2>/dev/null | head -1 || echo "<tailscale-ip>")

  if $CRON_REMOVE; then remove_cron; fi
  if $CRON;       then install_cron; fi
  if $SECURE;     then secure_server "$ip"; fi

  echo
  echo -e "${BOLD}${GREEN}=============================================="
  echo " persist-dev is up"
  echo " Server Tailscale IP: $ip"
  echo -e "==============================================${RESET}"
  echo
  echo "From your laptop / phone:"
  echo "  mosh --ssh=\"ssh -p $PORT_SSH\" dev@$ip -- dev menu"
  echo "  # or a specific project:"
  echo "  mosh --ssh=\"ssh -p $PORT_SSH\" dev@$ip -- dev attach <name>"
  echo
  if ! $SECURE; then
    echo -e "${YELLOW}SECURITY:${RESET} 'dev' user password is 'dev'."
    echo "  Change it (or run: ./setup.sh --secure):"
    echo "  ssh -p $PORT_SSH dev@$ip   # then: passwd"
    echo "  # or copy your key: ssh-copy-id -p $PORT_SSH dev@$ip"
  fi
}

main "$@"
