#!/usr/bin/env bash
# Container init: generate host keys, start sshd, persist harness/tool configs on the
# volume, ensure a tmux server for 'dev', stay alive.
set -euo pipefail

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi

mkdir -p /var/run/sshd /workspace/projects /workspace/.config

# Persist agent config/auth on the volume so credentials survive container recreation.
# The container's home is ephemeral; symlink each tool's config dir into /workspace.
for d in opencode claude codex gemini persist-dev omp; do
  if [ "$d" = "omp" ]; then
    # omp stores everything under ~/.omp (respects PI_CONFIG_DIR)
    mkdir -p /workspace/.omp
    rm -rf /home/dev/.omp
    ln -sfn /workspace/.omp /home/dev/.omp
  else
    mkdir -p "/workspace/.config/$d"
    rm -rf "/home/dev/.config/$d"
    ln -sfn "/workspace/.config/$d" "/home/dev/.config/$d"
  fi
done
mkdir -p /workspace/.codex;  rm -rf /home/dev/.codex;  ln -sfn /workspace/.codex  /home/dev/.codex
mkdir -p /workspace/.gemini; rm -rf /home/dev/.gemini; ln -sfn /workspace/.gemini /home/dev/.gemini
chown -R dev:dev /workspace/.config /workspace/.codex /workspace/.gemini /workspace/.omp 2>/dev/null || true

# Start sshd.
/usr/sbin/sshd

# Ensure a tmux server exists for the dev user so project sessions persist
# independently of any SSH/mosh viewer.
su - dev -c 'tmux start-server 2>/dev/null || true'

# Keep the container alive.
exec tail -f /dev/null
