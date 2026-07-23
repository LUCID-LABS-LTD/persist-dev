#!/usr/bin/env bash
# Host bootstrap for persist-dev. Installs Podman + Tailscale if missing,
# pulls the prebuilt image, runs the container, and prints the connect command.
#
# Flags:
#   --secure        Force a non-default 'dev' password and optionally switch to key-only SSH.
#   --cron          Schedule `dev backup` every 6h to BACKUP_TARGET (writes a host crontab entry).
#   --cron-remove   Remove the scheduled backup cron entry.
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
DATA_DIR="${DATA_DIR:-$HOME/.persist/workspace}"
PODMAN_MEM="${PERSIST_MEM:-}"
PODMAN_CPUS="${PERSIST_CPUS:-}"
MOSH_PORT_RANGE="${MOSH_PORT_RANGE:-60000-60050}"
SECURE=false
CRON=false
CRON_REMOVE=false

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
    apt)    $SUDO apt-get update -y >/dev/null 2>&1 || echo "  [warn] apt update failed; install may use stale indexes"; $SUDO apt-get install -y "$@" ;;
    dnf)    $SUDO dnf install -y "$@" ;;
    yum)    $SUDO yum install -y "$@" ;;
    pacman) $SUDO pacman -S --noconfirm "$@" ;;
    zypper) $SUDO zypper install -y "$@" ;;
    apk)    $SUDO apk add --no-cache "$@" ;;
    *) echo "Unsupported package manager — install manually: $*"; exit 1 ;;
  esac
}

install_podman() {
  if command -v podman >/dev/null 2>&1; then return 0; fi
  echo "== installing podman =="
  command -v curl >/dev/null 2>&1 || pkg_install curl
  pkg_install podman
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then return 0; fi
  echo "== installing tailscale =="
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
    || echo "  [warn] could not auto-install mosh-server. Install 'mosh' in the container manually; mosh connections will fail without it."
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
        echo "  [warn] UDP port $p in range $ports appears in use on host."
        echo "  Free port $p or set MOSH_PORT_RANGE=<start:end> (note: if you change this range, pass -p <port> to your mosh client)."
        break
      fi
    done
  fi
}
pull_or_build() {
  if podman pull "$IMAGE" 2>/dev/null; then
    echo "== pulled prebuilt image =="
  else
    echo "== prebuilt image unavailable; building locally (slower) =="
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
      echo "== restarted existing container =="
      ensure_mosh
      return 0
    fi
    echo "== container failed to start (stale port spec?); recreating... =="
    podman rm -f "$CONTAINER" >/dev/null 2>&1 || true
  fi

  mkdir -p "$DATA_DIR"/.config "$DATA_DIR"/.codex "$DATA_DIR"/.gemini "$DATA_DIR"/.omp
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
  echo "== started container (mosh ports: $mosh_ports/udp) =="
  ensure_mosh
  # Best-effort: enable systemd podman-restart service so container resumes on host reboot
  if command -v systemctl >/dev/null 2>&1; then
    $SUDO systemctl enable --now podman-restart 2>/dev/null || true
  fi
}

secure_server() {
  local ip="$1"
  echo
  echo "== SECURE: the 'dev' user ships with password 'dev'. Change it. =="
  read -r -s -p "  new dev password (echoed as you type)> " pw; echo
  if [ -z "$pw" ]; then
    pw=$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)
    echo "  (blank entered) generated random password: $pw"
  fi
  podman exec "$CONTAINER" sh -c "echo 'dev:$(printf '%q' "$pw")' | chpasswd"
  echo "  password set. Save it now — it will not be shown again."
  echo
  echo "For key-only access (recommended):"
  echo "  ssh-copy-id -p $PORT_SSH dev@$ip"
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
    echo "== installing cron =="
    case "$PKG" in
      apt|zypper) pkg_install cron ;;
      dnf|yum|pacman) pkg_install cronie ;;
      apk) pkg_install cron ;;
      *) echo "Unsupported distro — install a cron daemon manually"; exit 1 ;;
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
    echo "BACKUP_TARGET not set; cannot schedule backup. Export it first, e.g.:"
    echo "  export BACKUP_TARGET='myserver:/backups/persist'"
    exit 1
  fi
  ensure_cron
  local log="$DATA_DIR/../backup-cron.log"
  local line="0 */6 * * *  BACKUP_TARGET='$target' podman exec '$CONTAINER' dev backup >> '$log' 2>&1"
  ( crontab -l 2>/dev/null | grep -v "persist-dev backup"; echo "$line" ) | crontab - || true
  echo "== scheduled backup: $line =="
}

remove_cron() {
  ( crontab -l 2>/dev/null | grep -v "persist-dev backup" ) | crontab - || true
  echo "== removed persist-dev backup cron entry =="
}

usage() {
  cat <<'EOF'
Usage: sudo ./setup.sh [--secure] [--cron] [--cron-remove]
  --secure        force a new 'dev' password and optionally go key-only
  --cron          schedule `dev backup` every 6h (needs BACKUP_TARGET set)
  --cron-remove   remove the scheduled backup cron entry
Env (all optional):
  TS_AUTHKEY      tailscale auth key (headless servers) — joins the tailnet without a browser
  PORT_SSH, DATA_DIR, BACKUP_TARGET, PERSIST_MEM, PERSIST_CPUS  (see header)
EOF
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --secure)       SECURE=true; shift ;;
      --cron)         CRON=true; shift ;;
      --cron-remove)  CRON_REMOVE=true; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) echo "unknown flag: $1"; usage; exit 1 ;;
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
  echo "=============================================="
  echo " persist-dev is up"
  echo " Server Tailscale IP: $ip"
  echo "=============================================="
  echo
  echo "From your laptop / phone:"
  echo "  mosh --ssh=\"ssh -p $PORT_SSH\" dev@$ip -- dev menu"
  echo "  # or a specific project:"
  echo "  mosh --ssh=\"ssh -p $PORT_SSH\" dev@$ip -- dev attach <name>"
  echo
  if ! $SECURE; then
    echo "SECURITY: 'dev' user password is 'dev'. Change it (or run: ./setup.sh --secure):"
    echo "  ssh -p $PORT_SSH dev@$ip   # then: passwd"
    echo "  # or copy your key: ssh-copy-id -p $PORT_SSH dev@$ip"
  fi
}

main "$@"
