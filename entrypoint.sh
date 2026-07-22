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
for d in /workspace/.config /workspace/.codex /workspace/.gemini /workspace/.omp /workspace/projects; do
  [ -d "$d" ] && chown -R dev:dev "$d" 2>/dev/null || true
done

# Start sshd.
/usr/sbin/sshd

# Ensure a tmux server exists for the dev user so project sessions persist
# independently of any SSH/mosh viewer.
su - dev -c 'tmux start-server 2>/dev/null || true'

# Keep the container alive.
exec tail -f /dev/null
