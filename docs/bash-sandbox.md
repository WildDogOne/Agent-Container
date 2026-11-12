# Bash sandbox deep dive

The summary and the normal-mode behavior are in the
[README](../README.md#bash-sandbox). This file covers the details: settings generation,
Docker access, and the nested mode used under `--sysbox`.

## Settings generation

The sandbox settings are generated at startup and passed with `--settings`, so neither
your `~/.claude/settings.json` nor the host's native `claude` change. If bubblewrap
doesn't work at all, `claude-sandboxed` refuses to start rather than run unsandboxed.

## Writable paths

Shell commands can write only in the project directory, temp dirs, and the
read-write `--mount`/`EXTRA_MOUNTS` paths of the session (`:ro` ones stay
read-only). Those paths are also added as working directories for Claude Code's
file tools.

## Docker access under the sandbox

With `--allow-container` or `--with-docker`, shell commands can use the Docker socket
(Unix sockets allowed, socket paths not denied, `~/.docker` writable). Without either
flag, the socket paths are denied and Unix sockets are blocked. Docker access is root
over the daemon's host, so with these flags the Bash sandbox no longer contains a
command that sets out to escape - that is what the flags already mean.

## Under `--sysbox` (nested mode)

The sandbox works under `--sysbox` too, in a nested mode that `claude-sandboxed` picks
by itself (it says so when it starts). Sysbox refuses a fresh `/proc` mount, and only
lets a process bind the container's own `/proc` when it has its own IPC, UTS and cgroup
namespaces, which Claude Code doesn't create. So in nested mode:

- sandboxed commands see the container's `/proc` (Claude Code's
  `enableWeakerNestedSandbox`), i.e. the container's other processes;
- a small `bwrap` wrapper in the image (`harnesses/claude/bwrap-sysbox-shim`) adds the
  missing namespaces. It only ever adds isolation, and does nothing outside nested mode;
- Claude Code's seccomp filter for Unix sockets can't run (it needs a fresh `/proc`), so
  sockets are reachable by path. The nested Docker daemon's sockets are denied as files
  instead (unless Docker was asked for, see above). Other sockets do work in nested mode;
- sandboxed commands may create user namespaces of their own. The sandbox's mounts are
  locked inside them: unmasking the denied files or remounting read-only paths writable
  is refused (tested);
- **known leak:** because that `/proc` is the container's and everything in the
  container runs as the same UID, sandboxed commands can read `/proc/<pid>/environ` of
  Claude Code and its MCP servers. `--env-file` variables are stripped from the
  commands' own environment but still readable there, so the `--env-file` secret
  handling is only fully effective in normal mode. The login token and config backups
  stay denied either way (they're files, not env vars). No cheap fix: `hidepid` isn't
  something bwrap can set on that bind mount.

Network and write restrictions behave the same as in normal mode; secrets slightly less
so (the `/proc` bullet above).
