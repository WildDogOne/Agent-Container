# Hardening plan

Order of fixes for the sandbox threat-model gaps found in the 2026-11-01 review
(full write-up in the Obsidian note "Agent-Container - Sandbox Security Review").
Central problem: the docs justify `--permission-mode auto` and the read-only-config
mount split with sandbox properties the **default** configuration doesn't actually
have (`--privileged` + nested dockerd + passwordless sudo + advisory-only proxy).

Ordering logic: first close the leaks that are real escape vectors *under today's
posture* and don't depend on any posture decision; then invert the defaults so the
safety argument becomes true; then make egress actually enforced (deepest change,
and the one most likely to break workflows, so it goes last).

## Phase 1 — close host-executed-code leaks in shared writable paths

Independent of the posture decision; do these regardless.

Implemented 2026-11-01. Static validation done (`bash -n`/`sh -n`, generated-settings
jq run, `run.sh --help` mount listing). Rebuild + runtime smoke test pending: this
session runs inside the sandbox, whose nested dockerd cannot build or run containers
(overlay-on-overlay) — run `./build.sh claude hermes` and a `run.sh` session on the
host to verify.

- [x] **hermes: stop sharing `~/.hermes/installs`.** It's a dependency environment
      Hermes executes, inside the rw `state` mount — a session can plant code the
      host's native hermes later runs. Fix in `hermes-session`: add `installs` to
      the skip list in the symlink loop (same reasoning as the gateway/state.db
      entries already there), so each container prepares its own on first launch.
      Cost: a few hundred MB re-download per session — note the trade-off in
      `harness.conf`. **rebuild**
- [x] **claude: make `~/.claude/shell-snapshots` container-local.** Claude Code
      sources these snapshots in *every* later Bash session, including native host
      sessions, but must write them each session — so neither `:ro` nor a plain
      share works. New `harness.conf` key `tmpfs` (paths relative to `$HOME`):
      `run.sh` adds `--tmpfs "$HOME/<path>"`, `entrypoint.sh` chowns the mount to
      dev after startup. Extend the format in all three readers (`run.sh`,
      `run.ps1`, `entrypoint.sh`) and `harnesses/README.md`. `claude/harness.conf`
      gets `tmpfs=.claude/shell-snapshots`. **rebuild**
- [x] **Project-level settings vector.** The agent can write
      `.claude/settings.json` / `.claude/settings.local.json` / `.mcp.json` into
      `$PWD`, which the *native* claude then trusts (hooks, MCP servers) — the exact
      vector the ro config mounts exist for. Partial fix in `claude-sandboxed`: add
      `Edit(<abs>/...)` deny rules for those three paths (relative to `$PWD`) to the
      generated settings. Can't be fixed by mounting at all (it's the working dir),
      and it stays open in plain `command` mode — document that explicitly in
      `docs/quickstart-claude.md`. Optional follow-up: `run.sh` hashes those paths
      before the session and warns after, if they changed. **rebuild**

## Phase 2 — invert the default posture

Make the sandbox match the safety argument instead of the docs matching the sandbox.

- [x] **DinD opt-in.** `entrypoint.sh` starts the nested `dockerd` only with
      `WITH_DOCKER=1`; `run.sh`/`run.ps1` get a `--with-docker` flag (replacing
      "always on"). Without it, no dockerd and no `--privileged` at all — the
      default container becomes an ordinary unprivileged container. `--allow-container`
      stays as-is (explicit host-socket path), now mutually exclusive with
      `--with-docker`/`--sysbox`. Default `docker` *client* can stay
      installed. **rebuild**
- [x] **Prefer sysbox automatically.** When `--with-docker` is passed and
      `docker info` shows `sysbox-runc`, select it by default; `--privileged` only
      as fallback (loud warning) or with an explicit `--privileged` flag. Update
      `docs/sysbox.md`. Note: `run.ps1` can't auto-prefer — sysbox is never
      available in Docker Desktop's VM, so Windows always falls back to
      `--privileged` (inside the VM).
- [x] **`--bash-sandbox` on by default for harnesses that have it.** Flip
      `BASH_SANDBOX` default to `1` in `run.sh`/`run.ps1`; add `--no-bash-sandbox`
      to opt out. The refusal for harnesses without `sandboxed_command` stays, but
      the default must then silently fall back for those (opencode, hermes) —
      distinguish "user asked" (refuse) from "default" (fall back with a note).
- [x] **Drop `dev`'s `NOPASSWD:ALL` sudoers entry** (Dockerfile:122). It's what
      makes the dev demotion meaningless inside the container. `entrypoint.sh`'s
      root→dev `sudo` doesn't need it (root sudoing down is unrestricted). Check
      nothing in the image/MCP defaults needs dev-sudo; sessions that need root
      tooling belong in `config/extra-setup.sh` at build time, not `apt` mid-session.
      If someone genuinely needs it, an opt-in flag re-installs the sudoers file.
      Done without the opt-in flag (none requested); squid logs made world-readable
      instead so `sudo tail` troubleshooting advice is gone. **rebuild**

## Phase 3 — make egress enforcement real

Turn squid from advisory into enforced, so `--permission-mode auto` rests on
something. Only after Phase 2, since the rule set depends on the runtime mode.

- [ ] **nftables in `entrypoint.sh`** (before dropping to dev): outbound for dev
      restricted to `127.0.0.1:3128` (squid) + outbound DNS blocked except from
      squid's uid; the `allowed-ports.txt` ports squid itself may reach stay as-is.
      This closes the `curl --noproxy` / raw-socket / resolve-then-connect bypasses
      in *default* (non-bwrap) mode.
- [ ] **Decide the git-over-SSH carve-out.** Outbound :22 is currently unproxied
      and unrestricted (agent forwarding is a documented feature). Either keep an
      explicit allow for tcp/22 in the ruleset (documented, matches current
      behavior) or gate it behind a flag. Pick one; the plan's default is keep-and-document.
- [ ] **`--host-network` honesty.** It grants the container unrestricted access to
      the *host's* loopback services — bigger than the inbound concern the
      squid.conf comment mentions. Warn loudly (or require `--i-know` style
      confirmation) and fix the comment.
- [ ] `--allow-internet` drops the nftables rules too (it already drops the squid
      ones), or the rules defeat the flag.

## Phase 4 — small / documentation

- [ ] **Nested-mode `/proc` environ leak** (`claude-sandboxed:53`): same-UID
      sandboxed Bash can read `/proc/<pid>/environ` of claude/MCP processes in
      sysbox/nested mode, bypassing the `credentials.envVars` deny. No cheap fix
      (hidepid isn't available to bwrap) — document the limitation in
      `claude-sandboxed`'s header and `docs/quickstart-claude.md`.
- [ ] Update `README.md` + quickstarts for every flag/default flip; add
      `## Unreleased` CHANGELOG entries (marked **rebuild** where applicable) as
      each phase lands.

## Sequencing notes

- Phase 1 items are one-time cost and protect against the realistic attack
  (prompt injection writing host-executed code) even if nothing else changes.
- Phase 2 changes defaults = user-visible behavior; each item should land with its
  own CHANGELOG entry and opt-out flag rather than as one flip.
- Phase 3 is the only item likely to break existing workflows (SSH, odd egress);
  do it after the defaults are honest, and keep `--allow-internet` as the escape
  hatch.
