# persist-dev

> Resumable, multi-project dev box you can reach from anywhere — survives power cuts and ISP drops.

`persist-dev` is a one-command setup for a persistent coding environment that lives on an
always-on server (your own hardware, a VPS, or a seedbox). You reach it over **mosh + Tailscale**,
work inside **tmux** sessions, and use **OpenCode** (or any TUI agent) without ever losing state
when the lights go out or the ISP blinks.

## Why

If you code through flaky power/internet (Nigeria, loadshedding, roaming cellular), a raw SSH
session dies the moment the network drops: your TUI freezes, the agent stops, and you start over.
`persist-dev` decouples the *work* from the *connection*:

- **Podman** → reproducible environment, data on a persistent volume you can back up in one command.
- **Tailscale** → stable private address + encrypted auth; laptop and phone reach the same box.
- **mosh** → UDP-based; survives IP changes and intermittent connectivity without killing the session.
- **tmux** → the session (and your agent) lives server-side, fully decoupled from the transport.

When your net drops, mosh freezes, the server keeps running, and you reconnect to the *exact* same
OpenCode session. Zero lost state.

## Prerequisites

`persist-dev` assumes a few things before you run the one-liner:

- **A Linux server** (VPS, old PC, or seedbox) you can get a shell on once and that stays online. It runs a supported package manager (apt / dnf / yum / pacman / zypper / apk) + internet.
- **Root on that server** — the setup script installs packages and joins Tailscale, so run it as root (e.g. `sudo ./setup.sh`).
- **A (free) Tailscale account**, with Tailscale installed on the laptop/phone you'll connect from, all on the same tailnet.
- **`mosh` on your client** (`brew install mosh` / `apt install mosh`) — that's what survives flaky networks.
- **Your own agent API keys** for whichever harness you'll use (OpenAI, Anthropic, Google, …). The harnesses are installed but unauthenticated; you log in inside the session.

## 5-minute setup

On the always-on server:

```bash
git clone https://github.com/LUCID-LABS-LTD/persist-dev && cd persist-dev
sudo ./setup.sh
```

`setup.sh` installs Podman + Tailscale if missing, pulls the prebuilt image, runs the container,
and prints your connect command. (Optional environment flags: `PORT_SSH=2222`, `MOSH_PORT_RANGE=60000-60050`, `PERSIST_MEM`, `PERSIST_CPUS`).
**Headless server?** `tailscale up` normally opens a browser login. On a box with no browser,
set `TS_AUTHKEY` to a key from *tailscale.com → Settings → Keys* and run
`TS_AUTHKEY=tskey-xxxxx sudo ./setup.sh` — the script joins the tailnet for you, no browser needed.

## Client setup

You only *connect to* the box — install these once on each device:

**Laptop (macOS)**
```bash
brew install tailscale mosh      # Tailscale app + mosh client
# open the Tailscale app and log into your tailnet
```

**Laptop (Linux)**
```bash
# Tailscale: https://tailscale.com/download/linux (or your distro's package)
sudo apt install mosh          # mosh client (use dnf/yum/pacman/zypper/apk per distro)
```

**Laptop (Windows)**
- Install **Tailscale** (tailscale.com/download) and **OpenSSH** (Settings → Apps → Optional features, or via WSL).
- Connect through WSL, or a mosh-capable terminal.

**Phone**
- Install the **Tailscale** app and join the same tailnet.
- Install a mosh-capable terminal: **Blink** (iOS) or **Termius** (iOS/Android).

Then connect (next section).

## Connect from anywhere

```bash
# interactive project picker
mosh --ssh="ssh -p 2222" dev@<tailscale-ip> -- dev menu

# jump straight into a project
mosh --ssh="ssh -p 2222" dev@<tailscale-ip> -- dev attach <name>
```

From a phone: open the Tailscale app, then Blink/Termius → `mosh dev@<tailscale-ip> -- dev menu`.
> **First run — change the default password.** The `dev` user ships with password `dev`. Before
> anything else, either `ssh -p 2222 dev@<tailscale-ip>` → `passwd`, or copy your key with
> `ssh-copy-id -p 2222 dev@<tailscale-ip>` and run `sudo ./setup.sh --secure` for key-only SSH.
> See [Security notes](#security-notes).

## Harness-agnostic

OpenCode was just the example. `persist-dev` launches **any** coding-agent TUI inside its own
resumable tmux session. The four you mentioned come preconfigured:

| harness | launch command | notes |
| --- | --- | --- |
| `agy` | `agy -i` | Antigravity CLI (Gemini) |
| `codex` | `codex` | OpenAI Codex |
| `claude` | `claude` | Claude Code |
| `opencode` | `opencode` | default; add more via `dev harness add` |
| `omp` | `omp` | Oh My Pi (https://omp.sh) — terminal coding agent |

List or extend them:

```bash
dev harness list
dev harness add ollama "ollama run qwen2.5-coder"
```

Note on **Hermes** (this agent): it runs on your own machine, not inside the dev box, so it's
excluded by design — you drive `persist-dev` *from* Hermes, you don't run Hermes *in* it.

## Multi-project workflow

Every project is its own tmux session, so switching is instant and nothing collides:

| command | what it does |
| --- | --- |
| `dev new <name> [git-url] [--harness H]` | create a project dir + tmux session, launch harness `H` (auto-restarts on crash) |
| `dev ls` | list projects, attach state, and which harness each uses |
| `dev attach <name>` | jump into a project's live session (auto-creates it if missing) |
| `dev run <name> [harness]` | launch/relaunch a harness inside an existing project's session |
| `dev stop <name>` | kill a project's session |
| `dev rm <name>` | remove a project (asks before deleting files) |
| `dev rename <old> <new>` | move a project dir + session + metadata |
| `dev log <name>` | print a project session's scrollback |
| `dev doctor` | health check: tmux, volume, harnesses installed, tailscale |
| `dev ctx [show\|edit <name>\|sync\|pull]` | shared agent-context store (req #1: sync context across sessions) |
| `dev backup` | rsync the whole workspace to `BACKUP_TARGET` (safe copy; `BACKUP_PRUNE=1` for mirror/`--delete`) |
| `dev harness list\|add` | list or add a custom harness |

```bash
dev new api https://github.com/you/api --harness codex
dev new web https://github.com/you/web --harness agy
dev new cli https://github.com/you/cli            # defaults to opencode
dev menu            # pick one, work, detach (Ctrl-b d), pick the other later
```

All agent config and auth (OpenCode, Claude, Codex, Gemini/agy, and Oh My Pi/omp) lives on the
persistent volume and is **bind-mounted** straight onto the dev home (`~/.config`, `~/.codex`,
`~/.gemini`, `~/.omp`), so **credentials and sessions survive a container rebuild** — you
re-pull the image and your logins are still there. (We bind-mount rather than symlink, so an
agent that does `rm -rf` on its config dir can't break persistence.)

### Per-harness auth

| harness | where creds live | notes |
| --- | --- | --- |
| `opencode` | `~/.config/opencode` | file-based; mounts transparently |
| `claude` | `~/.config/claude` | file-based; mounts transparently |
| `codex` | `~/.config/codex` (or `~/.codex`) | file-based; mounts transparently |
| `agy` | desktop keyring *or* `~/.config/gemini` | keyring creds may need one re-auth after a rebuild |
| `omp` | `~/.omp/.env` / `~/.omp/agent/.env` (or env like `GEMINI_API_KEY`) | all under the bind-mounted `~/.omp` |

> If a harness prompts for auth after a rebuild, re-auth once — the renewed creds are written
> back onto the volume and persist from then on.

## Backup

Set a target and back up the entire workspace in one shot:

```bash
export BACKUP_TARGET="myserver:/backups/persist"   # or an rclone remote
dev backup                                      # safe copy (only new/changed files)
export BACKUP_PRUNE=1; dev backup                # mirror mode: also deletes files absent from source
```

The workspace is a single mounted volume (`~/.persist/workspace` on the host), so a cron job
wrapping `dev backup` is all you need for off-box durability.

> Project names are restricted to `A-Za-z0-9 _ . -` (no `/`, `..`, or spaces). They map
> directly to a directory under `/workspace/projects`, so path traversal is not possible.

## Security notes

- The container's `dev` user ships with password `dev`. **Change it** (`passwd` over SSH) or, better,
  copy your SSH key in: `ssh-copy-id -p 2222 dev@<tailscale-ip>`.
- Tailscale already encrypts and restricts access to devices you approve — keep it that way; don't
  also expose port 2222 to the public internet.
The prebuilt image is published to `ghcr.io/lucid-labs-ltd/persist-dev`. To build from source yourself,
  `podman build -t persist-dev -f Containerfile .` (CI does this automatically on push).

## How it fits together

```
   laptop / phone
        |  mosh (UDP, roams IPs, survives drops)
        v
   Tailscale tunnel  <--->  always-on server
        |                      |
   port 2222 / UDP 60000-60050 |
        v                      v
   ┌───────────────────────────────────┐
   | container: persist-dev             |
   |   sshd + mosh-server               |
   |   tmux server (dev user)           |
   |     ├─ proj-foo  (OpenCode)        |
   |     ├─ proj-bar  (OpenCode)        |
   |     └─ ...                         |
   |   volume: /workspace  -->  backed up|
   └───────────────────────────────────┘
```

The SSH/mosh pipe is only a viewport. OpenCode runs in a tmux-owned PTY. Kill the viewport and
OpenCode doesn't notice. Open a new viewport and you're exactly where you left off.

## License

MIT

## Status / roadmap

See **`HANDOFF.md`** for the full continuation brief (architecture, current state, gaps, and the
tasks below) — it's written so another agent can clone the repo and pick up where this left off.

- **T1** — ✅ Prebuilt image published via GitHub Actions → `ghcr.io/lucid-labs-ltd/persist-dev` (`.github/workflows/build.yml`, builds on push to `main`).
- **T2** — ✅ Auto-restart a crashed harness: `dev new`/`dev run` launch via `dev-harness`, which restarts the agent on crash (clean quit / Ctrl-C does not restart).
- **T3** — ✅ Installer versions pinned (opencode `1.18.4`, omp `v17.0.4`, claude-code `2.1.214`, codex `0.144.5`).
- **T4** — ✅ Security: `./setup.sh --secure` forces a new `dev` password and can switch to key-only SSH; port 2222 is Tailscale-only; optional podman `--memory`/`--cpus` via `PERSIST_MEM`/`PERSIST_CPUS`.
- **T5** — ✅ `dev doctor`, `dev rename`, `dev attach` auto-creates, `dev log`.
- **T6** — ✅ Per-harness auth table + troubleshooting (see above).
- **T7** — ✅ `./setup.sh --cron` schedules `dev backup` every 6h (needs `BACKUP_TARGET`).
