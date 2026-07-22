FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    tmux \
    mosh \
    git \
    curl \
    ca-certificates \
    fzf \
    locales-all \
    sudo \
    nodejs \
    npm \
    unzip \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8
RUN echo "LANG=C.UTF-8" > /etc/default/locale && echo "LC_ALL=C.UTF-8" >> /etc/default/locale

# OpenCode CLI (https://opencode.ai). Version pinned for reproducible builds.
ARG OPENCODE_VERSION=1.18.4
RUN curl -fsSL https://opencode.ai/install -o /tmp/oc-install \
 && bash /tmp/oc-install --version ${OPENCODE_VERSION} \
 && mv /root/.opencode/bin/opencode /usr/local/bin/opencode \
 && rm -rf /root/.opencode \
 || echo "opencode install skipped; install manually inside the container" \
 ; rm -f /tmp/oc-install

# Oh My Pi (omp) — https://omp.sh. Ref pinned to a release tag for reproducibility.
ARG OMP_VERSION=v17.0.4
RUN curl -fsSL https://omp.sh/install -o /tmp/omp-install \
 && PI_INSTALL_DIR=/usr/local/bin sh /tmp/omp-install --binary --ref ${OMP_VERSION} \
 || echo "omp install skipped; install manually inside the container" \
 ; rm -f /tmp/omp-install

# Claude Code + OpenAI Codex (best-effort; build still succeeds if offline).
# Versions pinned for reproducible builds.
RUN npm install -g @anthropic-ai/claude-code@2.1.214 @openai/codex@0.144.5 2>/dev/null \
    || echo "claude/codex npm install skipped (offline or unsupported); install inside the container if needed"

COPY dev /usr/local/bin/dev
COPY dev-harness /usr/local/bin/dev-harness
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config/tmux.conf /etc/tmux.conf
COPY config/sshd_config /etc/ssh/sshd_config

RUN chmod +x /usr/local/bin/dev /usr/local/bin/dev-harness /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/run/sshd /workspace /workspace/projects /home/dev \
    && useradd -m -s /bin/bash dev \
    && echo 'dev:dev' | chpasswd \
    && echo 'dev ALL=(ALL) ALL' > /etc/sudoers.d/dev   # password required, not passwordless root

EXPOSE 22
EXPOSE 60000-60050/udp
VOLUME ["/workspace"]
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
