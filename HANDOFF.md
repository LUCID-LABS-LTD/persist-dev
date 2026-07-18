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

> Repo: **https://github.com/LUCID-LABS-LTD/persist-dev** (private, branch `main`).

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
| `dev` | The project/harness switcher CLI (runs as `dev` user). Subcommands: `ls new attach run stop rm rename log doctor ctx backup harness menu`. |
| `dev-harness` | Auto-restart wrapper launched by `dev new`/`dev run`; restarts a crashed harness (clean quit / Ctrl-C does not restart). |
| `entrypoint.sh` | Container init: ssh-keygen, start sshd, ensure the bind-mounted agent-config dirs are owned by `dev`, `tmux start-server`, keep-alive. |
| `setup.sh` | Host bootstrap: install podman+tailscale, `tailscale up`, pull-or-build image, `podman run` (with agent-config bind mounts + optional resource limits), print connect cmd. Flags: `--secure`, `--cron`, `--cron-remove`. |
| `Containerfile` | debian-slim + sshd + mosh + tmux + fzf + sudo + node/npm; installs **pinned** opencode (0.0.55), omp (v17.0.4), claude-code (2.1.214), codex (0.144.5). |
| `config/tmux.conf` | tmux server config (256color, mouse, history 50k). |
| `config/sshd_config` | sshd config (port 22, password+key auth, no root). |
| `README.md` | User docs: 5-min setup, harness table, multi-project workflow, backup, security, roadmap. |
| `LICENSE` | MIT. |
| `.gitignore` | ignores `/workspace/`, logs. |

---

## 5. OPEN QUESTION — RESOLVED

The original voice spec listed three requirements. #2 (easy backup) and #3 (resumable) were
implemented. #1 was cut off by STT: "…important information needs to be ___ …".

**RESOLVED:** Imbol confirmed requirement #1 = **"sync agent context across sessions."**
Implemented as the `dev ctx` subcommand (see §6 T5b / README). Context lives in a shared store
on the volume (`/workspace/.context`), is visible to every session, is included in `dev backup`,
and syncs across machines via `dev ctx sync` / `dev ctx pull`. **No open questions remain.**

---

## 6. Roadmap (all implemented)

### T1 — Prebuilt image (GitHub Actions / GHCR) ✅
`.github/workflows/build.yml` builds and pushes `ghcr.io/LUCID-LABS-LTD/persist-dev:latest`
(and `:${{ github.sha }}`) on every push to `main` / `v*` tag. The repo's PAT has the
`workflow` scope, so the file committed cleanly and CI runs. `setup.sh` pulls it; on failure it
falls back to a local `podman build`. Multi-arch (arm64) stays OUT OF SCOPE.

### T2 — Auto-restart a crashed harness ✅
`dev new` / `dev run` launch the harness via `dev-harness` (on PATH in the container), which wraps
the agent in a restart loop: restarts on crash, but NOT on clean exit (0) or SIGINT/SIGTERM
(130/143 — your Ctrl-C quit). Touch `/workspace/projects/.persist/<name>.norestart` to stop the
loop without killing the agent. `dev run` remains the manual relaunch path.

### T3 — Pinned installer versions ✅
`Containerfile` no longer floats `curl … | sh`:
- opencode `0.0.55`  (`opencode.ai/install --version`)
- omp `v17.0.4`       (`omp.sh/install --ref`)
- `@anthropic-ai/claude-code@2.1.214`, `@openai/codex@0.144.5` (npm)
Each keeps the `|| echo skipped` fallback so an offline build still succeeds.

### T4 — Security hardening ✅
- `./setup.sh --secure` forces a non-default `dev` password (or generates a random one) and can
  switch the container to **key-only** SSH (`PasswordAuthentication no` + sshd reload).
- Port 2222 / UDP 60000-61000 are Tailscale-only — never expose to the public internet.
- Optional podman resource limits via `PERSIST_MEM` / `PERSIST_CPUS` (e.g. `4g` / `2.0`).

### T5 — Richer `dev` commands ✅
- `dev doctor` — tmux server, /workspace writable, each harness installed?, tailscale up?, projects.
- `dev rename <old> <new>` — moves dir + tmux session + `.harness` meta.
- `dev attach <name>` — auto-creates the project if the session is missing.
- `dev log <name>` — prints the session scrollback (`capture-pane`).

### T5b — Requirement #1: sync agent context across sessions ✅
`dev ctx` — a shared context store at `/workspace/.context` (one place, visible to every session):
- `dev ctx edit <name>` opens a markdown note; `dev ctx show` lists them.
- Included in `dev backup` (whole-workspace rsync) and synced across machines with
  `dev ctx sync` / `dev ctx pull` (pushes/pulls to `BACKUP_TARGET/context`).

### T6 — Docs ✅
Per-harness auth table + troubleshooting live in `README.md` (Persistence / Per-harness auth /
Security notes). `agy` may need one re-auth after a rebuild (keyring); everything else mounts
transparently via the bind-mounted volume dirs.

### T7 — Cron backup wrapper ✅
`./setup.sh --cron` writes a host crontab entry that runs `dev backup` every 6h to
`BACKUP_TARGET` (needs `BACKUP_TARGET` set). `--cron-remove` deletes it. `dev backup` now rsyncs
the **whole** `/workspace` (projects + agent config), so creds/context are actually backed up
(previously only `projects/` was covered).

### Persistence model (changed from symlinks → bind mounts)
Agent config dirs (`~/.config`, `~/.codex`, `~/.gemini`, `~/.omp`) are now **bind-mounted** from
the volume (`$DATA_DIR/{.config,.codex,.gemini,.omp}`) straight onto the dev home by `podman run`.
`entrypoint.sh` no longer symlinks; it just ensures the dirs exist and are owned by `dev`. This is
rm-rf-safe: an agent that deletes its config dir can't orphan persistence the way a symlink could.

---

## 7. Definition of done

- [x] Prebuilt GHCR image builds via CI (T1).
- [x] At least one harness auto-relaunches on crash (T2).
- [x] Installers pinned (T3).
- [x] Security: default password forced-changed / key-only path documented (T4).
- [x] `dev doctor` + auth + troubleshooting docs present (T5, T6).
- [x] **Requirement #1 clarified with the user and implemented (`dev ctx`, §5/§6 T5b).**
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
