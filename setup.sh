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
set -euo pipefail

IMAGE="ghcr.io/LUCID-LABS-LTD/persist-dev:latest"
CONTAINER="persist-dev"
PORT_SSH="${PORT_SSH:-2222}"
DATA_DIR="${DATA_DIR:-$HOME/.persist/workspace}"
PODMAN_MEM="${PERSIST_MEM:-}"
PODMAN_CPUS="${PERSIST_CPUS:-}"
SECURE=false
CRON=false
CRON_REMOVE=false

need() { command -v "$1" >/dev/null 2>&1 || { echo "this script needs '$1'"; exit 1; }; }

install_podman() {
  if command -v podman >/dev/null 2>&1; then return 0; fi
  echo "== installing podman =="
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update && sudo apt-get install -y podman
  elif command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y podman
  elif command -v pacman >/dev/null 2>&1; then
    sudo pacman -S --noconfirm podman
  else
    echo "Unsupported package manager. Install podman manually: https://podman.io/getting-started/installation"
    exit 1
  fi
}

install_tailscale() {
  if command -v tailscale >/dev/null 2>&1; then return 0; fi
  echo "== installing tailscale =="
  curl -fsSL https://tailscale.com/install.sh | sh
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
  local extra=()
  [ -n "$PODMAN_MEM" ]  && extra+=(--memory "$PODMAN_MEM")
  [ -n "$PODMAN_CPUS" ] && extra+=(--cpus "$PODMAN_CPUS")
  if podman ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    podman start "$CONTAINER" >/dev/null
    echo "== restarted existing container =="
  else
    mkdir -p "$DATA_DIR"/.config "$DATA_DIR"/.codex "$DATA_DIR"/.gemini "$DATA_DIR"/.omp
    podman run -d --name "$CONTAINER" \
      -p "$PORT_SSH:22" \
      -p 60000-61000:60000-61000/udp \
      -v "$DATA_DIR:/workspace" \
      -v "$DATA_DIR/.config:/home/dev/.config" \
      -v "$DATA_DIR/.codex:/home/dev/.codex" \
      -v "$DATA_DIR/.gemini:/home/dev/.gemini" \
      -v "$DATA_DIR/.omp:/home/dev/.omp" \
      --restart unless-stopped \
      "${extra[@]}" \
      "$IMAGE"
    echo "== started container =="
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
    podman exec "$CONTAINER" sh -c "sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config; pkill -HUP sshd" || true
    echo "  password auth disabled in container; sshd reloaded. Restart the container if sshd didn't pick it up."
  fi
}

install_cron() {
  local target="${BACKUP_TARGET:-}"
  if [ -z "$target" ]; then
    echo "BACKUP_TARGET not set; cannot schedule backup. Export it first, e.g.:"
    echo "  export BACKUP_TARGET='myserver:/backups/persist'"
    exit 1
  fi
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
Usage: ./setup.sh [--secure] [--cron] [--cron-remove]
  --secure        force a new 'dev' password and optionally go key-only
  --cron          schedule `dev backup` every 6h (needs BACKUP_TARGET set)
  --cron-remove   remove the scheduled backup cron entry
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
  need curl
  install_podman
  install_tailscale
  # Bring the server onto your tailnet (opens a browser / shows a login URL).
  sudo tailscale up
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
