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
    locales \
    sudo \
    nodejs \
    npm \
    && rm -rf /var/lib/apt/lists/*

RUN sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# OpenCode CLI (https://opencode.ai). Version pinned for reproducible builds.
ARG OPENCODE_VERSION=0.0.55
RUN curl -fsSL https://opencode.ai/install | bash -s -- --version ${OPENCODE_VERSION} \
    || echo "opencode install skipped; install manually inside the container"

# Oh My Pi (omp) — https://omp.sh. Ref pinned to a release tag for reproducibility.
ARG OMP_VERSION=v17.0.4
RUN curl -fsSL https://omp.sh/install | sh -s -- --ref ${OMP_VERSION} \
    || echo "omp install skipped; install manually inside the container"

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
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev

EXPOSE 22
EXPOSE 60000-61000/udp
VOLUME ["/workspace"]
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
