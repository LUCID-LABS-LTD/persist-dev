#!/usr/bin/env bash
# Container init: generate host keys, start sshd, ensure a tmux server for 'dev', stay alive.
set -euo pipefail

if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
  ssh-keygen -A
fi

mkdir -p /var/run/sshd /workspace/projects

# Start sshd in the background.
/usr/sbin/sshd

# Ensure a tmux server exists for the dev user so project sessions persist
# independently of any SSH/mosh viewer.
su - dev -c 'tmux start-server 2>/dev/null || true'

# Keep the container alive.
exec tail -f /dev/null
