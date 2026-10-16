# Code review

Full review of the repository as of commit `e1d30e7` (main), covering all tracked
files: `build.sh`, `run.sh`, `image/` (Dockerfile, entrypoint.sh, squid.conf,
allowed-domains.txt), `harnesses/` (claude, hermes), the Windows ports
(`build.ps1`, `run.ps1`, `setup.ps1`, `lib/windows-common.ps1`), `config/`
examples, docs, CHANGELOG, workflows, and the repo metadata files
(`.gitignore`, `.gitattributes`, `.dockerignore`). Shell scripts were also run
through shellcheck 0.10.

Overall: this is a well-built, unusually well-documented repo. The scripts are
careful (CRLF stripping, bash 3.2 empty-array guards, PowerShell 5.1
stderr/`$ErrorActionPreference` handling, the `su` vs `sudo` cwd reasoning, the
httpoxy-casing comment on the proxy vars). The harness abstraction is clean and
the three readers of `harness.conf` (run.sh, run.ps1, entrypoint.sh) stay in
sync. No logic bugs were found that would break a normal session. Findings
below: one real footgun, a few cross-port inconsistencies, and hygiene items.

## Bugs / footguns

### 1. FIXED - `.gitignore` line 17 (`lib/`) silently ignores new files in `lib/`

The `lib/` entry is a leftover from the Python gitignore template (it belongs to
the Python distribution/packaging block: `eggs/`, `.eggs/`, `lib/`, `lib64/`,
`parts/`, ...). `lib/windows-common.ps1` is already tracked, so it is unaffected,
but any *new* file added under `lib/` is silently ignored:

```sh
$ git check-ignore -v lib/new-helper.ps1
.gitignore:17:lib/  lib/new-helper.ps1
```

and `git add lib/foo.ps1` fails with "did not match any files" with no clear
cause. This contradicts the documented layout (`lib/` = shared PowerShell
helpers, README "Repository layout"). **Fix: delete the `lib/` line.**

### 2. FIXED - `.gitignore` is an unmodified Python template

71 of its 226 lines are Python noise (venv, pytest, coverage, Django, Celery,
poetry, uv.lock, pdm, pixi, PyInstaller, Jupyter, ...) in a repo that contains
no Python. It also ignores `CLAUDE.md` (line 220) - presumably intentional
(personal agent config), but it means the file is untracked and won't survive a
fresh clone. **Fix: trim it to what this repo actually needs** (`.venv/`,
`.idea/`, `.claude/`, the four `config/` files, and whatever else is deliberate)
so the real rules aren't buried under the template.

### 3. `run.ps1`: `--allow-container` is not validated before mounting

`run.sh` (line 147) refuses to start when `/var/run/docker.sock` is missing:

```sh
if [[ "$allow_container" -eq 1 && ! -S /var/run/docker.sock ]]; then ... exit 1; fi
```

`run.ps1` (line 344) has no equivalent - it unconditionally adds the mount and
`-e ALLOW_CONTAINER=1`. If the socket path is wrong for the given Docker
Desktop setup, the failure surfaces deep inside `entrypoint.sh` (`stat` on a
missing socket) instead of as a clear pre-flight message. **Fix: add the same
check (or a comment if it's intentional).**

### 4. `CONTAINER_GID` default differs between the two ports

- `run.sh` (line 203): `remap_gid="${CONTAINER_GID:-$(id -g)}"` - defaults to
  the host user's real primary GID when only `CONTAINER_UID` is set.
- `run.ps1` (line 196): `if (-not $remapGid) { $remapGid = $remapUid }` -
  defaults the GID to the UID value.

On Windows this is mostly academic (no remap by default), but it's a silent
divergence from the documented "same flags as run.sh" contract. **Fix: make
them match.**

## Cosmetic / consistency

### 5. FIXED - `run.ps1` help text misdescribed `--sysbox`

`run.ps1 --help` prints `Runtime: --privileged (sysbox not available on Docker
Desktop)`, but passing `--sysbox` doesn't print help - it hard-fails at line
136 with a clear error. The help line reads as if the flag exists and is a
no-op. The two scripts' `--help` output should describe the same flag set the
same way.

### 6. FIXED - `build.sh:27` - the only shellcheck warning in the repo

```sh
echo "build.sh: unknown harness '$harness' - available:" $(cd harnesses && ls -d */ | tr -d /) >&2
```

SC2046: unquoted command substitution. Harmless in practice (harness names are
directory names you control), but quoting it kills the warning. Everything else
passes shellcheck 0.10 at `-S warning` (remaining hits at `-S style` are
informational: SC2012/SC2035 on the `ls -d */` listings, SC2015 on run.sh:278
which is a false positive there, and SC1091 on the sourced `run.local.sh`).

## Reproducibility / supply chain

### 7. `harnesses/hermes/install.sh` pipes an unpinned installer from `main`

```sh
curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
  | bash -s -- ...
```

Every rebuild pulls whatever `main` is that day: the image is not reproducible,
and an upstream change (or a compromised `main`) silently changes what gets
baked in. **Fix: pin a release tag or commit SHA, and ideally checksum the
script.** Same class of issue, milder: `harnesses/claude/install.sh` runs
`npm install -g @anthropic-ai/claude-code` with no version pin.

### 8. Workflows pin actions by tag, not digest

`.github/workflows/claude.yml` and `claude-code-review.yml` use
`actions/checkout@v4` and `anthropics/claude-code-action@v1`. For a repo that is
otherwise careful about what runs with what access, pinning by SHA digest is the
norm. Note also that `claude.yml` triggers on any `@claude` mention in an issue
or PR - that's the action's default design, but worth being aware of given the
`id-token: write` permission.

## Performance (documented trade-off, flagged anyway)

### 9. `build.sh` always builds with `--no-cache`

Each harness build redoes the entire shared base (apt, Node, Python 3.14, uv,
bun) from scratch. With two harnesses, a change to anything - even a one-line
`harness.conf` - costs two full base builds. If build time ever bothers you,
drop `--no-cache` and rely on layer caching (the harness-specific layers still
invalidate when `harnesses/` or `config/` inputs change), or keep `--no-cache`
only for the harness section. Not urgent: the dangling-image prune at the bottom
is correct and properly scoped by the `project=devcontainer` label.

## Housekeeping

### 10. FIXED - Stale submodule remnant in `.git/`

`.git/modules/claude-code-server/pcloud` exists with no corresponding
`.gitmodules` entry or tracked file (a submodule was removed at some point). It
never gets committed, but `rm -rf .git/modules/claude-code-server` cleans it up.

### 11. `entrypoint.sh` starts squid/dockerd with no readiness check

Lines 81-101: `nohup squid ... & sleep 1` and `nohup dockerd ... & sleep 1`. If
either fails to start (port 3128 taken, dockerd can't create its network), the
session still launches and the failure surfaces later as a confusing "proxy
connection refused" or "docker: cannot connect to the Docker daemon". A short
retry loop on the socket - plus a hint pointing at `/tmp/squid.log` /
`/tmp/dockerd.log` - would make failures diagnosable in seconds.

## Checked and found fine

In case any of these were on the radar:

- **Staged-file copy loop** (entrypoint.sh:136-144): the `| while read`
  subshell is fine - nothing after the loop depends on loop variables.
- **Command forwarding** (entrypoint.sh:152-161): the
  `zsh -lc "exec $harness_command \"\$@\""` quoting is correct; `run.sh
  --continue` (flag forwarding) and `run.sh bash` (full command override) both
  behave as documented.
- **Squid ACL ordering** (squid.conf): `deny !Safe_ports` /
  `deny CONNECT !SSL_ports` / `allow allowed_dst` / `deny all` is correct, and
  the `--allow-internet` sed pattern in entrypoint.sh:50 matches the exact line
  in squid.conf.
- **UID remap**: the UID-0 refusal path is sound (run.sh never sends 0;
  entrypoint.sh refuses it independently).
- **Fresh-clone build**: `.dockerignore` whitelist plus `build.sh`'s seeding of
  missing `config/extra-setup.sh` and `config/allowed-domains.txt` means a
  fresh clone builds without manual setup.
- **`run.ps1` `--mount` regex**: the drive-letter colon is handled
  (`C:\data`, `C:\data:/data`, `C:\data:/data:ro` all parse correctly);
  `Add-Bind` uses `--mount` rather than `-v` precisely to avoid the
  colon-in-drive-letter collision and to refuse missing sources.
- **`A && B || C` at run.sh:278**: shellcheck's SC2015 is a false positive
  there - the branches can't fail in a way that double-runs.
