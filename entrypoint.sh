#!/usr/bin/env bash
# Container init: generate host keys, start sshd, ensure the persistent
# agent-config directories (bind-mounted from the volume) are owned by 'dev',
# ensure a tmux server for 'dev', stay alive.
#
# Persistence model: agent config dirs (~/.config, ~/.codex, ~/.gemini, ~/.omp)
# are bind-mounted from the volume ($DATA_DIR/{.config,.codex,.gemini,.omp})
# straight onto the dev home by `podman run`. No symlinks — so an agent that
# does `rm -rf ~/.config/<x>` can't break persistence. The volume is the source
# of truth; the home paths are just mount points.
set -euo pipefail

# Ensure default UTF-8 locale environment for all SSH sessions
echo "LANG=C.UTF-8" > /etc/environment
echo "LC_ALL=C.UTF-8" >> /etc/environment
# Save container's mapped mosh port range for mosh-server wrapper
mosh_range="${MOSH_PORT_RANGE:-60000-60050}"
echo "${mosh_range//-/:}" > /etc/mosh_ports
chmod 644 /etc/mosh_ports
cat <<'EOF' > /etc/profile.d/persist-dev-welcome.sh
if [ -n "$PS1" ] && [ -z "${TMUX:-}" ]; then
  echo "======================================================================"
  echo "  Welcome to persist-dev"
  echo "  Resumable Multi-Project Dev Box"
  echo "======================================================================"
  echo "Commands:"
  echo "  dev menu         - Interactive project switcher"
  echo "  dev new <name>   - Create a new project"
  echo "  dev ls           - List all projects"
  echo "  dev link         - View latest browser/OAuth auth link & QR code"
  echo "  dev doctor       - Check environment health"
  echo "  dev help         - Display help for all commands"
  echo "----------------------------------------------------------------------"
  echo "  FIRST TIME? Change the default password: passwd"
  echo "  Copy your SSH key: ssh-copy-id -p 2222 dev@$(hostname -s 2>/dev/null || echo '<host>')"
  echo "----------------------------------------------------------------------"
  echo "Tip: Press Ctrl+b then d to detach from a project session anytime."
  echo
fi
EOF
chmod 644 /etc/profile.d/persist-dev-welcome.sh

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi
sshd -t || { echo 'sshd config invalid; not starting' >&2; exit 1; }

mkdir -p /var/run/sshd /workspace/projects

# The four agent-config dirs are bind-mounted from the volume. Make sure they
# exist on the volume and are owned by 'dev' so the agents can write to them.
for d in /workspace/.config /workspace/.codex /workspace/.gemini /workspace/.omp; do
  mkdir -p "$d"
done
chown dev:dev /workspace 2>/dev/null || true
for d in /workspace/.config /workspace/.codex /workspace/.gemini /workspace/.omp /workspace/projects; do
  [ -d "$d" ] && chown -R dev:dev "$d" 2>/dev/null || true
done

# Start sshd.
/usr/sbin/sshd

# Ensure a tmux server exists for the dev user so project sessions persist
# independently of any SSH/mosh viewer.
su - dev -c 'tmux new-session -d -s main 2>/dev/null || true'

# Keep the container alive.
exec tail -f /dev/null
