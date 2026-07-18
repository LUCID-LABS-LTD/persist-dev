#!/usr/bin/env bash
# Host bootstrap for persist-dev. Installs Podman + Tailscale if missing,
# pulls the prebuilt image, runs the container, and prints the connect command.
set -euo pipefail

IMAGE="ghcr.io/imb0l/persist-dev:latest"
CONTAINER="persist-dev"
PORT_SSH="${PORT_SSH:-2222}"
DATA_DIR="${DATA_DIR:-$HOME/.persist/workspace}"

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
  if podman ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    podman start "$CONTAINER" >/dev/null
    echo "== restarted existing container =="
  else
    mkdir -p "$DATA_DIR"
    podman run -d --name "$CONTAINER" \
      -p "$PORT_SSH:22" \
      -p 60000-61000:60000-61000/udp \
      -v "$DATA_DIR:/workspace" \
      --restart unless-stopped \
      "$IMAGE"
    echo "== started container =="
  fi
}

main() {
  need curl
  install_podman
  install_tailscale
  # Bring the server onto your tailnet (opens a browser / shows a login URL).
  sudo tailscale up
  pull_or_build
  run_container

  local ip
  ip=$(tailscale ip -4 2>/dev/null | head -1 || echo "<tailscale-ip>")
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
  echo "SECURITY: 'dev' user password is 'dev'. Change it:"
  echo "  ssh -p $PORT_SSH dev@$ip   # then: passwd"
  echo "  # or copy your key: ssh-copy-id -p $PORT_SSH dev@$ip"
}

main "$@"
