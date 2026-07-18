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

# OpenCode CLI (https://opencode.ai).
RUN curl -fsSL https://opencode.ai/install | bash || echo "opencode install skipped; install manually inside the container"

# Claude Code + OpenAI Codex (best-effort; build still succeeds if offline).
RUN npm install -g @anthropic-ai/claude-code @openai/codex 2>/dev/null \
    || echo "claude/codex npm install skipped (offline or unsupported); install inside the container if needed"

COPY dev /usr/local/bin/dev
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY config/tmux.conf /etc/tmux.conf
COPY config/sshd_config /etc/ssh/sshd_config

RUN chmod +x /usr/local/bin/dev /usr/local/bin/entrypoint.sh \
    && mkdir -p /var/run/sshd /workspace /workspace/projects /home/dev \
    && useradd -m -s /bin/bash dev \
    && echo 'dev:dev' | chpasswd \
    && echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev

EXPOSE 22
EXPOSE 60000-61000/udp
VOLUME ["/workspace"]
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
