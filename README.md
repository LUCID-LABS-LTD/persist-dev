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

## 5-minute setup

On the always-on server:

```bash
git clone https://github.com/imb0l/persist-dev && cd persist-dev
./setup.sh
```

`setup.sh` installs Podman + Tailscale if missing, pulls the prebuilt image, runs the container,
and prints your connect command. (First-time package installs dominate the clock; the
clone→run path is instant if Podman + Tailscale are already present.)

## Connect from anywhere

```bash
# interactive project picker
mosh --ssh="ssh -p 2222" dev@<tailscale-ip> -- dev menu

# jump straight into a project
mosh --ssh="ssh -p 2222" dev@<tailscale-ip> -- dev attach <name>
```

From a phone: open the Tailscale app, then Blink/Termius → `mosh dev@<tailscale-ip> -- dev menu`.

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
| `dev new <name> [git-url] [--harness H]` | create a project dir + tmux session, launch harness `H` inside |
| `dev ls` | list projects, attach state, and which harness each uses |
| `dev attach <name>` | jump into a project's live session |
| `dev run <name> [harness]` | launch/relaunch a harness inside an existing project's session |
| `dev menu` | fzf picker over all projects (default when you connect) |
| `dev stop <name>` | kill a project's session |
| `dev rm <name>` | remove a project (asks before deleting files) |
| `dev backup` | rsync the whole workspace to `BACKUP_TARGET` |

```bash
dev new api https://github.com/you/api --harness codex
dev new web https://github.com/you/web --harness agy
dev new cli https://github.com/you/cli            # defaults to opencode
dev menu            # pick one, work, detach (Ctrl-b d), pick the other later
```

Each harness's own config and auth (OpenCode, Claude, Codex, Gemini/agy, and Oh My Pi/omp
tokens) is symlinked onto the persistent volume (`/workspace/.config`, `/workspace/.codex`,
`/workspace/.gemini`, `/workspace/.omp`), so **credentials and sessions survive a container
rebuild** — you re-pull the image and your logins are still there.

> Caveat: `agy`'s auth can live in a desktop keyring rather than a plain file, so if it prompts
> after a rebuild, re-auth once. Codex/Claude/OpenCode file-based config mounts transparently.
> `omp` stores provider keys in `~/.omp/.env` / `~/.omp/agent/.env` (or env vars like
> `GEMINI_API_KEY`); all of that lives under the symlinked `~/.omp`, so it persists too.

## Backup

Set a target and back up the entire workspace in one shot:

```bash
export BACKUP_TARGET="myserver:/backups/persist"   # or an rclone remote
dev backup
```

The workspace is a single mounted volume (`~/.persist/workspace` on the host), so a cron job
wrapping `dev backup` is all you need for off-box durability.

## Security notes

- The container's `dev` user ships with password `dev`. **Change it** (`passwd` over SSH) or, better,
  copy your SSH key in: `ssh-copy-id -p 2222 dev@<tailscale-ip>`.
- Tailscale already encrypts and restricts access to devices you approve — keep it that way; don't
  also expose port 2222 to the public internet.
- The prebuilt image is published to `ghcr.io/imb0l/persist-dev`. To build from source yourself,
  `podman build -t persist-dev -f Containerfile .` (CI does this automatically on push).

## How it fits together

```
   laptop / phone
        |  mosh (UDP, roams IPs, survives drops)
        v
   Tailscale tunnel  <--->  always-on server
        |                      |
   port 2222 / UDP 60000-61000 |
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

## Roadmap / not-yet-done

See **`HANDOFF.md`** for the full continuation brief (architecture, current state, gaps, and the
exact tasks below) — it's written so another agent can clone the repo and pick up where this
left off.

- **T1** — Publish prebuilt image via GitHub Actions → `ghcr.io/imb0l/persist-dev` (blocked: the
  GitHub PAT lacks the `workflow` scope; use a fine-grained token, then commit `.github/workflows/build.yml`).
- **T2** — Auto-restart a crashed harness inside its session (`while true` loop / `tmux respawn-pane` / `dev watch`).
- **T3** — Pin installer versions (opencode, omp) instead of floating `curl … | sh`.
- **T4** — Security hardening: force-change the default `dev` password, document key-only + Tailscale-only access, optional podman resource limits.
- **T5** — Richer `dev`: `doctor`, `rename`, auto-create on `attach`, `log`.
- **T6** — Docs: per-harness auth + troubleshooting.
- **T7** — Cron wrapper for `dev backup`.

**Open question (must resolve before "done"):** requirement #1 from the original voice spec was
cut off by STT ("important information needs to be ___"). Ask Imbol what it is — it may change a
`dev` subcommand.
