# HANDOFF.md — Continue `persist-dev`

> You are an autonomous coding agent taking over this project on a different machine.
> Clone the repo, read this file top to bottom, then execute the roadmap below.
> Do NOT start from scratch — the scaffold is built and pushed. Your job is the gaps.

---

## 1. What this project is

`persist-dev` is a **clone-and-run, resumable, multi-project dev box** that survives power cuts
and ISP drops (the user lives in Nigeria — loadshedding + flaky ISP). You reach it over
**mosh + Tailscale**, work inside **tmux** sessions, and run coding-agent TUIs (OpenCode, Claude
Code, OpenAI Codex, Antigravity/agy, Oh My Pi/omp) without ever losing state when the network dies.

The core idea: the *work* (tmux session + agent TUI) is decoupled from the *connection*
(mosh over Tailscale). SSH/mosh is only a viewport. The agent runs in a tmux-owned PTY, so
killing the viewer leaves the agent running; a new viewer shows the exact same live session.

Repo: **https://github.com/imb0l/persist-dev** (public, branch `main`).

---

## 2. Current state (verified vs not)

**VERIFIED (this session):**
- All shell scripts pass `bash -n` (no syntax errors): `dev`, `entrypoint.sh`, `setup.sh`.
- Files committed and pushed to `main`. Remote file listing confirms they landed.
- 5 harnesses preconfigured in `dev`: `agy` (`agy -i`), `codex`, `claude`, `opencode` (default),
  `omp` (`omp` — Oh My Pi, https://omp.sh).
- Persistent-config symlinks implemented in `entrypoint.sh`:
  `~/.config/{opencode,claude,codex,gemini,persist-dev}`, `~/.omp`, `~/.codex`, `~/.gemini`
  all symlink to `/workspace/...` so agent creds survive a container rebuild.

**NOT VERIFIED (could NOT be tested in the build environment):**
- No `podman` / `tmux` / `mosh` in the agent's container, so **no live end-to-end run**.
- The prebuilt `ghcr.io/imb0l/persist-dev:latest` image does **NOT exist yet** — `setup.sh`
  falls back to a local `podman build` when the pull fails. Confirmed by design.
- Each harness binary's installer (`curl ... | sh`) is best-effort (`|| echo skipped`), so a
  real `podman build` may or may not fetch them depending on network. Verify after building.

**The user MUST run `./setup.sh` on their always-on server** to do the live smoke test. You
cannot do that for them unless you have access to that server.

---

## 3. Architecture / pipeline

```
   laptop / phone (anywhere, roaming IP)
        │
        │  mosh  (UDP 60000-61000 — survives IP change + drops; raw SSH would freeze)
        │
        ▼
   Tailscale tunnel  ──►  always-on server (own power / UPS, static on tailnet)
        │
        │  port 2222 (ssh) + UDP 60000-61000 (mosh)
        ▼
   ┌─────────────────────────────────────────────────────────┐
   │ container: persist-dev  (podman, --restart unless-stopped)│
   │                                                          │
   │   sshd (port 22 ← host 2222)                             │
   │   mosh-server                                            │
   │   tmux server (user: dev)  ◄── persistent, independent    │
   │     ├─ proj-foo  (pane → OpenCode TUI, cwd /workspace/…)  │
   │     ├─ proj-bar  (pane → omp TUI)                         │
   │     └─ proj-<name>  (one session per project)             │
   │                                                          │
   │   volume: /workspace  ──►  host $DATA_DIR (~/.persist/…)  │
   │     ├─ projects/   (one dir per project + .persist meta)  │
   │     ├─ .config/  .codex/  .gemini/  .omp/  (agent creds)  │
   └─────────────────────────────────────────────────────────┘
        │
        ▼
   BACKUP:  dev backup  →  rsync /workspace → $BACKUP_TARGET (seedbox / rclone)
```

**Connection command (printed by setup.sh):**
```
mosh --ssh="ssh -p 2222" dev@<tailscale-ip> -- dev menu
```
`dev menu` = fzf picker over live project sessions. `dev attach <name>` = jump straight in.

---

## 4. File map

| file | role |
| --- | --- |
| `dev` | The project/harness switcher CLI (runs as `dev` user inside container). Subcommands: `ls new attach run stop rm backup harness menu`. |
| `entrypoint.sh` | Container init: ssh-keygen, start sshd, symlink agent config dirs onto `/workspace`, `tmux start-server`, keep-alive. |
| `setup.sh` | Host bootstrap: install podman+tailscale, `tailscale up`, pull-or-build image, `podman run`, print connect cmd. |
| `Containerfile` | debian-slim + sshd + mosh + tmux + fzf + sudo + node/npm; installs opencode, omp, claude, codex. |
| `config/tmux.conf` | tmux server config (256color, mouse, history 50k). |
| `config/sshd_config` | sshd config (port 22, password+key auth, no root). |
| `README.md` | User docs: 5-min setup, harness table, multi-project workflow, backup, security, roadmap. |
| `LICENSE` | MIT. |
| `.gitignore` | ignores `/workspace/`, logs. |

---

## 5. ⚠️ OPEN QUESTION — clarify before finalizing

The original voice spec listed three requirements. **Requirement #1 was cut off by STT:**
> "…the problems I'm facing now is one, important information needs to be ___ … two data needs
> to be easy to back up and three it has to be resumable…"

Requirements #2 (easy backup) and #3 (resumable) are implemented. **Requirement #1 is unknown.**
It may change a `dev` subcommand (e.g. syncing agent context/notes across sessions, or a
knowledge store). **Ask the user (Imbol, @imb0l_1 on Telegram, UTC+1) what requirement #1 is**
before you declare the project "done". Do not invent it.

---

## 6. Roadmap (execute in this order)

### T1 — Publish the prebuilt image (GitHub Actions / GHCR)
BLOCKER: the current GitHub PAT lacks the `workflow` scope, so pushing `.github/workflows/*.yml`
was rejected (`refusing to allow a Personal Access Token to create or update workflow ... without
'workflow' scope`). Fix: use a **fine-grained PAT** (or GitHub App) with `workflow` permission on
repo `imb0l/persist-dev`, then commit this file as `.github/workflows/build.yml`:

```yaml
name: build
on:
  push:
    branches: [main]
    tags: ['v*']
permissions:
  contents: read
  packages: write
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository }}:latest
            ghcr.io/${{ github.repository }}:${{ github.sha }}
```

After it's green, `setup.sh`'s `podman pull ghcr.io/imb0l/persist-dev:latest` will succeed
instead of falling back to a local build. Multi-arch (arm64) is explicitly OUT OF SCOPE (user
said no Pi / no arm64).

### T2 — Auto-restart a crashed harness
Today, if a harness TUI crashes, `dev attach` shows a dead shell. Decide ONE approach:
- **(a)** Wrap launch in `dev new`/`dev run`: send a loop into the pane, e.g.
  `tmux send-keys -t $sess "while true; do $cmd; echo '[crashed] restarting in 2s'; sleep 2; done" C-m`.
  Caveat: TUI agents don't love being in a `while` loop (Ctrl-C exits the loop, not just the agent).
- **(b)** Document `tmux respawn-pane -k -t proj-X` for manual recovery (already effectively
  covered by `dev run`).
- **(c)** Add a `dev watch <name>` that monitors the pane and respawns on exit.
Pick (a) or (c) and implement; update README. Keep `dev run` as the manual relaunch path.

### T3 — Pin installer versions for reproducibility
`Containerfile` currently uses floating `curl ... | sh` for opencode and omp. Replace with
pinned release URLs (research current stable release tags on each project's GitHub) so a build
is reproducible and not subject to an upstream change breaking the image. Keep the
`|| echo skipped` fallback.

### T4 — Security hardening
- `setup.sh`: after first boot, **force** a `dev` password change or require `ssh-copy-id`; the
  default password is `dev` (shipped knowingly — must be changed).
- Optionally disable password auth once a key is present (`PasswordAuthentication no` in
  `config/sshd_config`, regenerated by setup).
- Document clearly: **never expose port 2222 to the public internet** — Tailscale-only. The
  mosh UDP range (60000-61000) must be reachable on the Tailscale interface.
- Optional: add podman resource limits (`--memory`, `--cpus`) in `setup.sh` so one project
  can't starve the box.

### T5 — Richer `dev` commands
- `dev doctor` — healthcheck: tmux server up? harnesses installed? tailscale connected? volume mounted?
- `dev rename <old> <new>` — move project dir + session.
- `dev attach <name>` — if session missing, offer to `dev new` it (currently errors).
- `dev log <name>` — tail the pane scrollback / a session log.

### T6 — Docs
- Per-harness auth section: agy (keyring caveat — may need one re-auth after rebuild), omp
  (provider keys in `~/.omp/.env` or env like `GEMINI_API_KEY`), claude/codex (file config under
  `~/.config`), opencode. All persist via the symlinks.
- Troubleshooting: "mosh hangs" (UDP 60000-61000 blocked / not on tailscale iface), "can't reach
  box" (tailscale down — `tailscale status`), "session frozen" (detach `Ctrl-b d`, re-`dev attach`).

### T7 — Cron backup wrapper
Add a `setup.sh --cron` (or document) that schedules `dev backup` (e.g. every 6h) to
`$BACKUP_TARGET`. The rsync already covers all agent config dirs via the symlinks.

---

## 7. Definition of done

- [ ] Prebuilt GHCR image builds via CI (T1).
- [ ] At least one harness auto-relaunches on crash (T2).
- [ ] Installers pinned (T3).
- [ ] Security: default password forced-changed / key-only path documented (T4).
- [ ] `dev doctor` + auth + troubleshooting docs present (T5, T6).
- [ ] **Requirement #1 clarified with the user and implemented or explicitly deferred (§5).**
- [ ] Live test performed by the user (or a documented test plan with expected output).

---

## 8. Verify your work

```bash
# syntax
bash -n dev entrypoint.sh setup.sh

# build (needs podman)
podman build -t persist-dev -f Containerfile .

# live (needs the always-on server + tailscale)
./setup.sh
# from laptop:
mosh --ssh="ssh -p 2222" dev@<tailscale-ip> -- dev new test https://github.com/octocat/Hello-World --harness omp
# confirm:  tmux ls   shows   proj-test
```

---

## 9. User / tone notes

- **User: Imbol** (@imb0l_1 on Telegram, GitHub `imb0l`). Blunt, no-BS, Nigerian (ABUAD,
  Mechatronics), UTC+1. Builds things himself; wants **every flag/option explained** (what it
  does, why, and what breaks without it). Respond in plain language, no filler, no sugarcoating.
- **Hermes** (this agent's family) is deliberately excluded from the harness list — it drives the
  box from the user's machine, it is not run inside the container.
- If offered Yoruba, engage in Yoruba.
