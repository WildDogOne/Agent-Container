#!/usr/bin/env python3
"""doctor.py - is this machine ready to start a session, and if not, what's missing?

    ./doctor.py                 check the default harness (HARNESS in config/run.local.sh, else claude)
    ./doctor.py hermes          check one harness, or several: ./doctor.py claude opencode
    ./doctor.py --all           check every harness under harnesses/
    ./doctor.py --fix           also do the safe fixes: seed the gitignored config files from
                                their .example, create the harness's state dirs / staged files,
                                chmod 600 the env file, make run.sh/build.sh executable
    ./doctor.py --quiet         only the problems (no ok lines)
    ./doctor.py --json          machine-readable report (a CI job, or another tool)

    On Windows the same flags, run as `python .\\doctor.py` (docs/windows.md).

Everything `run.sh` needs has to be in the right place *before* it starts: the image
built, the gitignored config files present, `config/run.local.sh` valid, the docker env
file free of the names the sandbox reserves, the harness's `state`/`staged` paths under
$HOME being the right kind of thing. Each of those fails with a message that names a
file the user has usually never looked at, so this script reads exactly the same config
run.sh reads - config/run.local.sh, harnesses/<name>/harness.conf, the env file, the
allowlists - and asks docker what it knows (daemon reachable, image present, sysbox
registered). It never starts a container, and it writes nothing unless --fix is passed.

On a Windows host it checks the Windows side of the same things: config/run.local.ps1
instead of run.local.sh, run.ps1's mount rules (a drive letter's colon is fine there -
run.ps1 uses `docker run --mount`, not -v), and Docker Desktop's Linux engine.

Exit code 0 when nothing would stop a session, 1 when something would (--strict makes
warnings count too). Stdlib only, like the other host-side tools in tools/.
"""

import argparse
import base64
import fnmatch
import ipaddress
import json
import os
import platform
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone

ROOT = os.path.dirname(os.path.abspath(__file__))
HOME = os.path.expanduser("~")
DEFAULT_ENV_FILE = os.path.join(HOME, ".config", "agentcontainer.env")

IS_WINDOWS = platform.system() == "Windows"
# The two hosts read different files and mount differently (docs/windows.md), so the
# findings and the hints have to quote the entry point this machine actually uses.
RUN_SCRIPT = "run.ps1" if IS_WINDOWS else "run.sh"
BUILD_CMD = r".\build.ps1" if IS_WINDOWS else "./build.sh"
LOCAL_CONFIG = os.path.join("config", "run.local.ps1" if IS_WINDOWS else "run.local.sh")

# harnesses/README.md: the keys run.sh/entrypoint.sh read. Anything else in a
# harness.conf is a typo, and run.sh just ignores it.
HARNESS_KEYS = ("command", "sandboxed_command", "state", "tmpfs", "config", "staged", "owned")

# config/run.local.sh.example: the settings run.sh looks for. An uppercase assignment
# outside this list is a typo that silently does nothing.
LOCAL_KEYS = {
    "HARNESS", "EXTRA_MOUNTS", "EXTRA_CONFIG_RO_PATHS", "CA_CERTS", "CONTAINER_UID",
    "CONTAINER_GID", "ENV_FILE", "WITH_DOCKER", "BASH_SANDBOX", "PROXY_LOGS",
    "PROXY_LOG_DIR", "INSPECT", "ALLOW_INTERNET", "SINK_DIR",
    "SQUID_LOGS", "SQUID_LOG_DIR",  # deprecated names, warned about separately
}

# run.sh's check_env_name(): an env file setting one of these would quietly undo part of
# the sandbox (proxy settings, HOME, the flags), so run.sh refuses the whole file.
RESERVED_ENV_GLOBS = (
    "HOME", "PATH", "USER", "SHELL", "SUDO_*", "HOST_*", "AGENTCONTAINER_*", "LD_*",
    "GCONV_PATH", "OPENSSL_*", "INSPECT", "PROXY_LOGS", "PROXY_LOG_DIR",
    "ALLOW_CONTAINER", "WITH_DOCKER",
)
RESERVED_ENV_LOWER = ("http_proxy", "https_proxy", "no_proxy", "all_proxy")

# Sourced the way run.sh sources it (arrays initialised, the settings that loosen the
# sandbox unset first), then dumped as TAB-separated lines so Python can report what a
# session on this machine would get by default.
LOCAL_SH_PROLOGUE = """
EXTRA_MOUNTS=(); EXTRA_CONFIG_RO_PATHS=(); CA_CERTS=()
HARNESS="${HARNESS:-}"; CONTAINER_UID="${CONTAINER_UID:-}"; CONTAINER_GID="${CONTAINER_GID:-}"
ENV_FILE="${ENV_FILE:-}"
unset WITH_DOCKER BASH_SANDBOX PROXY_LOGS PROXY_LOG_DIR INSPECT SQUID_LOGS SQUID_LOG_DIR
unset ALLOW_INTERNET SINK_DIR
WITH_DOCKER=""; BASH_SANDBOX=""; PROXY_LOGS=""; PROXY_LOG_DIR=""; INSPECT=""
ALLOW_INTERNET=""; SINK_DIR=""
"""

LOCAL_SH_EPILOGUE = """
set +u
for k in HARNESS CONTAINER_UID CONTAINER_GID ENV_FILE WITH_DOCKER BASH_SANDBOX PROXY_LOGS \\
         PROXY_LOG_DIR INSPECT ALLOW_INTERNET SINK_DIR; do
  printf 'V\\t%s\\t%s\\n' "$k" "${!k}"
done
for a in EXTRA_MOUNTS EXTRA_CONFIG_RO_PATHS CA_CERTS; do
  eval "arr=(\\"\\${$a[@]}\\")"
  for v in "${arr[@]}"; do printf 'L\\t%s\\t%s\\n' "$a" "$v"; done
done
"""


def run(cmd, timeout=25):
    """Run cmd; return (returncode, stdout, stderr), or (None, "", why) if it can't run."""
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as exc:
        return None, "", str(exc)
    return proc.returncode, proc.stdout, proc.stderr


def first_line(text):
    """First non-empty line of a subprocess' stderr, for a one-line hint."""
    lines = (text or "").strip().splitlines()
    return lines[0] if lines else None


def read_text(path):
    """Raw text: newline="" keeps \\r so the checks below can see CRLF files. bash, run.sh
    and docker all keep a trailing \\r as part of the value, which is exactly the kind of
    confusing failure this script is meant to catch."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace", newline="") as fh:
            return fh.read()
    except OSError:
        return None


def warn_crlf(report, section, path, effect):
    if "\r" in (read_text(path) or ""):
        report.warn(section, "%s has CRLF line endings" % path, hint=effect)


class Report:
    """Flat list of findings, printed grouped by section in the order they were added."""

    def __init__(self):
        self.items = []

    def add(self, level, section, message, hint=None):
        self.items.append({"level": level, "section": section, "message": message,
                           "hint": hint})

    def fail(self, section, message, hint=None):
        self.add("fail", section, message, hint)

    def warn(self, section, message, hint=None):
        self.add("warn", section, message, hint)

    def note(self, section, message, hint=None):
        self.add("note", section, message, hint)

    def ok(self, section, message):
        self.add("ok", section, message)

    def counts(self):
        counts = {"fail": 0, "warn": 0, "note": 0, "ok": 0}
        for item in self.items:
            counts[item["level"]] += 1
        return counts


class Fixer:
    """--fix: the few repairs that are safe to automate. Nothing here overwrites a file."""

    def __init__(self, enabled):
        self.enabled = enabled
        self.applied = []

    def apply(self, description, action):
        if not self.enabled:
            return False
        try:
            action()
        except OSError as exc:
            print("doctor.py: couldn't fix %s: %s" % (description, exc), file=sys.stderr)
            return False
        self.applied.append(description)
        return True

    def copy_if_missing(self, src, dst, description):
        if os.path.exists(dst):
            return False
        return self.apply(description, lambda: shutil.copyfile(src, dst))

    def make_executable(self, path, description):
        if os.access(path, os.X_OK):
            return False

        def action():
            mode = os.stat(path).st_mode
            os.chmod(path, mode | 0o111)

        return self.apply(description, action)


def expand(path):
    """Expand ~ and $HOME the way run.sh does for the paths typed into its config."""
    if not path:
        return path
    path = os.path.expandvars(path)
    return os.path.expanduser(path)


def current_uid():
    """The POSIX uid running this script, or None on Windows (no uid to compare against)."""
    return os.getuid() if hasattr(os, "getuid") else None


def is_reserved_env(key):
    if any(fnmatch.fnmatchcase(key, glob) for glob in RESERVED_ENV_GLOBS):
        return True
    return key.lower() in RESERVED_ENV_LOWER


# --- harness.conf ------------------------------------------------------------------

def read_harness_conf(path):
    """Mirror run.sh's `sed -n "s/^key=//p" | tail -n 1`: last assignment wins, value is
    the rest of the line verbatim (run.sh does NOT strip inline comments). Keeps every
    assignment so a key set twice can be reported."""
    values = {}
    for lineno, line in enumerate((read_text(path) or "").splitlines(), 1):
        match = re.match(r"^([a-z_]+)=(.*)$", line)
        if match:
            values.setdefault(match.group(1), []).append((lineno, match.group(2)))
    return values


def conf_value(conf, key):
    """The value run.sh/entrypoint.sh would use: the last assignment for that key."""
    entries = conf.get(key)
    return entries[-1][1] if entries else ""


def conf_list(conf, key):
    """Space-separated list value, as run.sh reads it with `read -r -a`."""
    value = conf_value(conf, key)
    return value.split() if value.strip() else []


def check_harness_conf(report, section, name):
    conf_dir = os.path.join(ROOT, "harnesses", name)
    conf_path = os.path.join(conf_dir, "harness.conf")
    if not os.path.isfile(conf_path):
        available = sorted(
            entry for entry in os.listdir(os.path.join(ROOT, "harnesses"))
            if os.path.isfile(os.path.join(ROOT, "harnesses", entry, "harness.conf"))
        ) if os.path.isdir(os.path.join(ROOT, "harnesses")) else []
        report.fail(section, "harness '%s': no %s" % (name, os.path.relpath(conf_path, ROOT)),
                    hint="available harnesses: %s" % " ".join(available) if available
                         else "harnesses/ has no harnesses at all - git clone looks incomplete")
        return None

    conf = read_harness_conf(conf_path)
    rel = os.path.relpath(conf_path, ROOT)
    if not IS_WINDOWS:
        warn_crlf(report, section, conf_path,
                  "run.sh reads it as-is (the build strips \\r inside the image), so a CRLF file breaks the "
                  "command and mounts")
    # On Windows this is deliberately not a finding: run.ps1 reads it with
    # [IO.File]::ReadAllLines, which drops the \r, and the Dockerfile strips \r from
    # everything it copies into the image (docs/windows.md: Line endings).
    for key in sorted(conf):
        if key not in HARNESS_KEYS:
            report.warn(section, "%s: unknown key '%s' - %s and entrypoint.sh ignore it" % (rel, key, RUN_SCRIPT),
                        hint="harnesses/README.md lists the keys: %s" % " ".join(HARNESS_KEYS))
    for key in sorted(conf):
        entries = conf[key]
        if len(entries) > 1:
            report.note(section, "%s: '%s' set on lines %s - the last one wins"
                        % (rel, key, ", ".join(str(no) for no, _value in entries)))
        lineno, value = entries[-1]
        if " #" in value:
            report.warn(section, "%s line %d: an inline comment in '%s' is part of the value" % (rel, lineno, key),
                        hint="run.sh/entrypoint.sh take the rest of the line verbatim - put the comment on its own line")

    if not conf_value(conf, "command").strip():
        report.fail(section, "%s: no 'command' - the container would have nothing to start" % rel,
                    hint="see harnesses/README.md")
    else:
        report.ok(section, "harness.conf command: %s" % conf_value(conf, "command").strip())
    if conf_value(conf, "sandboxed_command").strip():
        report.note(section, "Bash sandbox: on by default (%s); --no-bash-sandbox or BASH_SANDBOX=0 turns it off"
                    % conf_value(conf, "sandboxed_command").strip())

    for key in ("state", "config", "staged", "tmpfs"):
        raw = conf_value(conf, key)
        if '"' in raw or "'" in raw:
            report.warn(section, "%s: '%s' has a quote in it - %s splits the value on spaces, quoting doesn't help"
                        % (rel, key, RUN_SCRIPT),
                        hint="paths in harness.conf can't contain spaces - see harnesses/README.md")
        for entry in conf_list(conf, key):
            if entry.startswith("/"):
                report.warn(section, "%s: '%s' path '%s' should be relative to $HOME" % (rel, key, entry))
    for entry in conf_list(conf, "owned"):
        if not entry.startswith("/"):
            report.warn(section, "%s: 'owned' path '%s' must be absolute (it's a path inside the image)" % (rel, entry))

    if not conf_list(conf, "state"):
        report.warn(section, "%s: no 'state' dirs - the harness's login and history won't survive a session" % rel)

    # Build inputs the Dockerfile COPYs unconditionally: a missing one fails the build.
    for filename in ("install.sh", "allowed-domains.txt"):
        path = os.path.join(conf_dir, filename)
        if os.path.isfile(path):
            report.ok(section, "%s exists" % os.path.relpath(path, ROOT))
        else:
            report.fail(section, "%s is missing - %s %s would fail" % (os.path.relpath(path, ROOT), BUILD_CMD, name),
                        hint="see harnesses/README.md")
    return conf


# --- allowlists --------------------------------------------------------------------

def split_allow_entry(entry):
    """host[:port] -> (host, port|None), the way image/inspect-proxy.py's _split_port does."""
    match = re.match(r"^\[([^\]]+)\](?::(\d+))?$", entry)
    if match:
        return match.group(1), (int(match.group(2)) if match.group(2) else None)
    try:
        ipaddress.ip_network(entry, strict=False)
        return entry, None
    except ValueError:
        pass
    match = re.match(r"^([^:]+):(\d+)$", entry)
    if match:
        return match.group(1), int(match.group(2))
    return entry, None


def check_allowlist(report, section, path, assembled):
    """One entry per line: example.com, .example.com (it + subdomains), host:port, an IP
    or CIDR. build.sh strips comments and whitespace while assembling the image's list;
    a --allow-list override only gets its \\r stripped, so keep those clean too."""
    text = read_text(path)
    if text is None:
        return
    rel = os.path.relpath(path, ROOT)
    entries = 0
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.replace("\r", "").split("#", 1)[0].strip()
        if not line:
            continue
        entries += 1
        host, port = split_allow_entry(line)
        if re.match(r"(?i)^[a-z]+://", line):
            report.warn(section, "%s line %d: '%s' has a URL scheme" % (rel, lineno, line),
                        hint="the allowlist matches hosts, not URLs - write %s" % re.sub(r"(?i)^[a-z]+://", "", line))
            continue
        if line.startswith("*."):
            report.warn(section, "%s line %d: '%s' never matches anything" % (rel, lineno, line),
                        hint="use .%s - a leading dot means the domain and every subdomain" % line[2:])
            continue
        try:
            ipaddress.ip_network(line, strict=False)
            continue  # an IP or a CIDR network (10.0.0.0/8) is a valid entry as written
        except ValueError:
            pass
        if "/" in line:
            report.warn(section, "%s line %d: '%s' has a path" % (rel, lineno, line),
                        hint="only hosts (optionally :port) can be allowed, not URLs")
            continue
        if port is not None and not 1 <= port <= 65535:
            report.warn(section, "%s line %d: port %d out of range" % (rel, lineno, port))
        if not host:
            report.warn(section, "%s line %d: '%s' has no host in it" % (rel, lineno, line))
            continue
        bare = host[1:] if host.startswith(".") else host
        try:
            ipaddress.ip_address(bare.strip("[]"))
            continue
        except ValueError:
            pass
        if not re.match(r"^[A-Za-z0-9._-]+$", bare):
            report.warn(section, "%s line %d: '%s' doesn't look like a host, IP or network" % (rel, lineno, line),
                        hint="one entry per line: example.com, .example.com, host:port or 10.0.0.0/8")
    label = "assembled into the image" if assembled else "used as-is for the session"
    if entries == 0 and rel == os.path.join("config", "allowed-domains.txt"):
        report.note(section, "%s has no entries of its own - a session gets only the shared defaults "
                    "and the harness's own domains" % rel,
                    hint="add the hosts your MCP servers or model endpoints need (one per line), then %s" % BUILD_CMD)
        return
    report.ok(section, "%s: %d entr%s %s" % (rel, entries, "y" if entries == 1 else "ies", label))


# --- host and docker ---------------------------------------------------------------

def check_host(report, fix):
    section = "Host"
    system = platform.system()
    if system == "Linux":
        report.ok(section, "Linux %s" % (platform.release() or ""))
    elif system == "Windows":
        report.note(section, "Windows: the supported entry points are setup.ps1, build.ps1 and run.ps1",
                    hint="the checks below read what %s reads: %s, harnesses/<name>/harness.conf, the env "
                         "file and Docker Desktop's engine; only the sysbox note is Linux-only"
                         % (RUN_SCRIPT, LOCAL_CONFIG))
    else:
        report.warn(section, "%s isn't a supported host - the image is Ubuntu 24.04 and run.sh is written for Linux" % system,
                    hint="see README.md Requirements")

    if not IS_WINDOWS and not shutil.which("bash"):
        report.fail(section, "bash is not on PATH - run.sh is a bash script")
    if not shutil.which("git"):
        report.warn(section, "git is not on PATH - the worktree mount and --sink can't work",
                    hint="git inside the container comes from the image; this is only about run.sh's own git calls")
    if current_uid() == 0:
        report.note(section, "running as root: dev keeps UID 1000:1000, so files the session writes land owned by 1000",
                    hint="run the session as your own user, or set CONTAINER_UID in %s" % LOCAL_CONFIG)

    for script in (("run.ps1", "build.ps1", "setup.ps1", "doctor.py") if IS_WINDOWS
                   else ("run.sh", "build.sh", "doctor.py")):
        path = os.path.join(ROOT, script)
        if not os.path.isfile(path):
            report.fail(section, "%s is missing - git clone looks incomplete" % script)
            continue
        if IS_WINDOWS:
            continue  # NTFS has no exec bit; PowerShell runs the .ps1 files regardless
        fix.make_executable(path, "chmod +x %s" % script)
        if not os.access(path, os.X_OK):
            report.warn(section, "%s is not executable" % script, hint="chmod +x %s" % path)


def check_repo(report):
    section = "Repository"
    # Everything run.sh and the build need from the repo itself, including
    # lib/seccomp-userns.json: docker refuses to start a Bash-sandbox session without it.
    required = ("image/Dockerfile", "image/entrypoint.sh", "image/allowed-domains.txt",
                "image/inspect-proxy.py", "image/redact_secrets.py", "image/loopback-forward.py",
                "lib/seccomp-userns.json", "tools/sessionlog.py", "harnesses")
    missing = [rel for rel in required if not os.path.exists(os.path.join(ROOT, rel))]
    for rel in missing:
        report.fail(section, "%s is missing - git clone looks incomplete" % rel)
    if not missing:
        report.ok(section, "sandbox files present (image/, lib/, tools/)")


def docker_info(fmt):
    return run(["docker", "info", "--format", fmt])


def check_docker(report):
    section = "Docker"
    if not shutil.which("docker"):
        report.fail(section, "docker is not on PATH - %s starts a container" % RUN_SCRIPT,
                    hint="install Docker (README.md Requirements); on Windows, Docker Desktop on WSL2 - docs/windows.md")
        return
    code, out, err = docker_info("{{.ServerVersion}}")
    if code != 0:
        detail = first_line(err) or first_line(out) or "docker info failed"
        text = (err or "").lower()
        if IS_WINDOWS:
            # The npipe in that message is Docker Desktop's own Linux-engine pipe, so the
            # address is right for this host: what fails is the engine not answering, not
            # the path. No keyword matching here - the error text arrives in the user's
            # Windows locale ("Das System kann die angegebene Datei nicht finden").
            hint = ("start Docker Desktop and wait until its engine reports running (%s starts it and waits "
                    "up to 3 minutes); if it is already running, check the tray icon is on Linux containers "
                    "and that `docker context ls` points at desktop-linux" % BUILD_CMD)
        elif "permission denied" in text:
            hint = "the daemon is running but this user may not use it: sudo usermod -aG docker \"$USER\", then log out and in"
        elif "cannot connect" in text or "no such file" in text:
            hint = "start the daemon (systemctl start docker), or check DOCKER_HOST / docker context use"
        else:
            hint = "check `docker info` by hand"
        report.fail(section, "docker can't reach a daemon: %s" % detail, hint=hint)
        return
    report.ok(section, "docker daemon reachable (server %s)" % out.strip())

    code, out, _ = docker_info("{{.OSType}}")
    if code == 0 and out.strip().lower() == "windows":
        report.fail(section, "the engine runs Windows containers - the image is Ubuntu 24.04, so it can't be built or run here",
                    hint="Docker Desktop's tray icon: 'Switch to Linux containers' (%s checks this too)" % BUILD_CMD)
    code, out, _ = docker_info("{{.SecurityOptions}}")
    if code == 0 and "rootless" in out:
        report.note(section, "rootless Docker: dev keeps UID 1000:1000 (no remap), which is already your user",
                    hint="set CONTAINER_UID in %s only if files come out owned by the wrong user" % LOCAL_CONFIG)
    code, out, _ = run(["docker", "version"])
    if code == 0 and "podman" in out.lower():
        report.note(section, "this is Podman behind the docker CLI: dev keeps UID 1000:1000, and nested Docker needs a look")
    sysbox_finding(report, section)
    code, out, _ = run(["docker", "network", "ls", "--format", "{{.Name}}"])
    if code == 0 and "bridge" not in out.split():
        report.warn(section, "Docker's default bridge network is not listed - %s uses it unless --host-network is passed" % RUN_SCRIPT)


def sysbox_finding(report, section):
    """The sysbox runtime, in the form that's true on this host: sysbox can't be
    installed into Docker Desktop's VM at all, so there's nothing to install there."""
    code, out, _ = docker_info("{{json .Runtimes}}")
    if code != 0:
        return
    if "sysbox-runc" in out:
        report.ok(section, "sysbox-runc is registered: --with-docker gets user-namespace isolation (docs/sysbox.md)")
    elif IS_WINDOWS:
        report.note(section, "no sysbox-runc, and Docker Desktop's VM can't run one: --with-docker always uses --privileged",
                    hint="%s refuses --sysbox; that's privileged inside Docker Desktop's VM, not over Windows itself"
                         " - docs/windows.md" % RUN_SCRIPT)
    else:
        report.note(section, "no sysbox-runc runtime: --with-docker falls back to --privileged",
                    hint="install sysbox for real isolation around a nested dockerd - docs/sysbox.md")


# --- config/run.local.sh (Linux) and config/run.local.ps1 (Windows) -----------------

# Dot-sourced the way run.ps1 dot-sources it (the arrays initialised and the settings that
# loosen the sandbox set to $null first, exactly as run.ps1 does), then dumped as
# TAB-separated lines so Python can report what a Windows session would get by default.
LOCAL_PS1_PROLOGUE = """
$ErrorActionPreference = 'Stop'
$EXTRA_MOUNTS = @(); $EXTRA_CONFIG_RO_PATHS = @(); $CA_CERTS = @()
$HARNESS = $env:HARNESS; $CONTAINER_UID = $env:CONTAINER_UID; $CONTAINER_GID = $env:CONTAINER_GID
$ENV_FILE = $env:ENV_FILE
$WITH_DOCKER = $null; $BASH_SANDBOX = $null; $PROXY_LOGS = $null; $PROXY_LOG_DIR = $null
$INSPECT = $null; $ALLOW_INTERNET = $null; $SINK_DIR = $null
"""

LOCAL_PS1_EPILOGUE = """
foreach ($k in 'HARNESS','CONTAINER_UID','CONTAINER_GID','ENV_FILE','WITH_DOCKER','BASH_SANDBOX',
                'PROXY_LOGS','PROXY_LOG_DIR','INSPECT','ALLOW_INTERNET','SINK_DIR') {
  Write-Output ("V`t" + $k + "`t" + [string](Get-Variable -Name $k -ValueOnly -ErrorAction SilentlyContinue))
}
foreach ($a in 'EXTRA_MOUNTS','EXTRA_CONFIG_RO_PATHS','CA_CERTS') {
  foreach ($v in @(Get-Variable -Name $a -ValueOnly -ErrorAction SilentlyContinue)) {
    if ($null -ne $v) { Write-Output ("L`t" + $a + "`t" + [string]$v) }
  }
}
"""


def read_local_config(report):
    """The per-machine config the entry point on this host reads: run.sh sources
    config/run.local.sh, run.ps1 dot-sources config/run.local.ps1."""
    return read_local_ps1(report) if IS_WINDOWS else read_local_sh(report)


def read_local_sh(report):
    """Source config/run.local.sh the way run.sh does and return its settings
    ({"V": scalars, "L": arrays}). A file that fails to source is a hard finding:
    run.sh would stop right there."""
    section = "Local config"
    path = os.path.join(ROOT, "config", "run.local.sh")
    if not os.path.isfile(path):
        report.note(section, "no config/run.local.sh - everything keeps its default",
                    hint="copy config/run.local.sh.example to config/run.local.sh: default harness, "
                         "standing mounts, proxy logs, ...")
        return check_local_settings(report, section, {"V": {}, "L": {}})

    code, _out, err = run(["bash", "-n", path])
    if code != 0:
        report.fail(section, "config/run.local.sh has a syntax error - run.sh sources it and stops",
                    hint=first_line(err))
        return {"V": {}, "L": {}}

    script = "set -eu\n" + LOCAL_SH_PROLOGUE + '. "$1"\n' + LOCAL_SH_EPILOGUE
    code, out, err = run(["bash", "-c", script, "doctor", path])
    if code != 0:
        report.fail(section, "config/run.local.sh fails when sourced - run.sh stops at the same line",
                    hint=first_line(err))
        return {"V": {}, "L": {}}

    settings = parse_settings(out)
    report.ok(section, "config/run.local.sh sources cleanly")
    warn_crlf(report, section, path,
              "run.sh sources it, so a trailing \\r lands inside the value (HARNESS=claude\\r finds no such harness)")

    # Typos in setting names are silent: only the names run.sh reads have any effect.
    for lineno, line in enumerate(read_text(path).splitlines(), 1):
        match = re.match(r"^\s*(?:export\s+)?([A-Z][A-Z0-9_]*)=[^=]*$", line)
        if not match:
            continue
        check_local_name(report, section, lineno, match.group(1))

    return check_local_settings(report, section, settings)


def read_local_ps1(report):
    """Dot-source config/run.local.ps1 the way run.ps1 does, and return its settings in the
    same shape as read_local_sh's. Bypass is passed because the finding here is about what
    the file sets, not about this shell's script policy (docs/windows.md covers that)."""
    section = "Local config"
    path = os.path.join(ROOT, "config", "run.local.ps1")
    if not os.path.isfile(path):
        report.note(section, "no config\\run.local.ps1 - everything keeps its default",
                    hint="copy config\\run.local.ps1.example to config\\run.local.ps1: default harness, "
                         "standing mounts, proxy logs, ...")
        return check_local_settings(report, section, {"V": {}, "L": {}})

    shell = shutil.which("powershell") or shutil.which("pwsh")
    if not shell:
        report.warn(section, "can't read config\\run.local.ps1: no PowerShell on PATH",
                    hint="run.ps1 needs PowerShell too - see docs/windows.md")
        return {"V": {}, "L": {}}

    # -EncodedCommand (base64 UTF-16LE) rather than -Command with a quoted script: the
    # snippet is full of quotes, tabs and $, and Windows' argument quoting would eat some
    # of it. Both Windows PowerShell 5.1 and pwsh take it.
    command = LOCAL_PS1_PROLOGUE + ". '" + path.replace("'", "''") + "'\n" + LOCAL_PS1_EPILOGUE
    encoded = base64.b64encode(command.encode("utf-16-le")).decode("ascii")
    code, out, err = run([shell, "-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", encoded])
    if code != 0:
        report.fail(section, "config\\run.local.ps1 fails when dot-sourced - run.ps1 stops at the same line",
                    hint=first_line(err))
        return {"V": {}, "L": {}}

    settings = parse_settings(out)
    # No CRLF check: PowerShell reads a CRLF file as-is and leaves no \r inside a value,
    # which is the opposite of run.sh sourcing a shell file (docs/windows.md: Line endings).
    report.ok(section, "config\\run.local.ps1 dot-sources cleanly")

    for lineno, line in enumerate(read_text(path).splitlines(), 1):
        match = re.match(r"^\s*\$([A-Z][A-Z0-9_]*)\s*(?:\+?=|=(?!=))", line)
        if not match:
            continue
        check_local_name(report, section, lineno, match.group(1))

    return check_local_settings(report, section, settings)


def parse_settings(out):
    """The TAB-separated dump both prologues print: 'V <name> <value>', 'L <array> <item>'."""
    settings = {"V": {}, "L": {}}
    for line in out.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        kind, key, value = parts
        if kind == "V":
            settings["V"][key] = value
        else:
            settings["L"].setdefault(key, []).append(value)
    return settings


def check_local_name(report, section, lineno, name):
    """One assignment's name: a deprecated one, or one no entry point reads at all."""
    if name in ("SQUID_LOGS", "SQUID_LOG_DIR"):
        report.warn(section, "%s line %d: %s is deprecated" % (LOCAL_CONFIG, lineno, name),
                    hint="rename it to %s" % name.replace("SQUID", "PROXY"))
    elif name not in LOCAL_KEYS:
        report.warn(section, "%s line %d: %s is not a setting %s reads" % (LOCAL_CONFIG, lineno, name, RUN_SCRIPT),
                    hint="%s.example lists the ones that exist - a typo here does nothing" % LOCAL_CONFIG)


def check_local_settings(report, section, settings):
    """What those settings mean for the next session - shared by both hosts."""
    scalars, arrays = settings["V"], settings["L"]

    for name in ("WITH_DOCKER", "PROXY_LOGS", "INSPECT", "ALLOW_INTERNET"):
        value = scalars.get(name, "")
        if value and value != "1":
            report.warn(section, "%s=%s in %s has no effect - only =1 turns it on" % (name, value, LOCAL_CONFIG))
    bash_sandbox = scalars.get("BASH_SANDBOX", "")
    if bash_sandbox not in ("", "0", "1"):
        report.warn(section, "BASH_SANDBOX=%s in %s has no effect (only 0 changes anything)"
                    % (bash_sandbox, LOCAL_CONFIG))
    if scalars.get("ALLOW_INTERNET") == "1":
        report.warn(section, "ALLOW_INTERNET=1: every session gets the full internet - the allowlist "
                             "and the egress firewall are off",
                    hint="drop it and use config/allowed-domains.txt or --allow-list for the one host you need")
    if scalars.get("INSPECT") == "1":
        report.warn(section, "INSPECT=1: every session decrypts HTTPS and logs bodies; breaks TLS-pinning services",
                    hint="pass --inspect for the one session you're debugging instead")
    if scalars.get("WITH_DOCKER") == "1":
        code, out, _ = docker_info("{{json .Runtimes}}")
        if code == 0 and "sysbox-runc" not in out and IS_WINDOWS:
            report.warn(section, "WITH_DOCKER=1: every session runs --privileged, and Docker Desktop's VM has no "
                                 "sysbox to make that narrower",
                        hint="drop it from %s and pass --with-docker when you need a nested daemon - docs/windows.md"
                             % LOCAL_CONFIG)
        elif code == 0 and "sysbox-runc" not in out:
            report.warn(section, "WITH_DOCKER=1 without sysbox-runc: every session runs --privileged",
                        hint="install sysbox (docs/sysbox.md), or drop WITH_DOCKER=1 and pass --with-docker when needed")

    uid, gid = scalars.get("CONTAINER_UID", ""), scalars.get("CONTAINER_GID", "")
    if uid and uid != "off":
        if not uid.isdigit() or uid == "0":
            report.fail(section, "CONTAINER_UID=%s is not a non-zero number (or 'off') - %s refuses it"
                        % (uid, RUN_SCRIPT))
        else:
            report.note(section, "CONTAINER_UID=%s: dev takes that UID inside the container" % uid)
    if gid and (not gid.isdigit() or gid == "0"):
        report.fail(section, "CONTAINER_GID=%s is not a non-zero number - %s refuses it" % (gid, RUN_SCRIPT))

    for name, values in arrays.items():
        for value in values:
            if name == "EXTRA_MOUNTS":
                check_mount_spec(report, section, value)
            elif name == "CA_CERTS":
                cert = expand(value)
                if os.path.isfile(cert):
                    report.ok(section, "CA_CERTS: %s" % cert)
                else:
                    report.fail(section, "CA_CERTS entry is not a file: %s - %s stops there" % (value, RUN_SCRIPT),
                                hint="fix the path in %s or remove the entry" % LOCAL_CONFIG)
            elif name == "EXTRA_CONFIG_RO_PATHS":
                target = os.path.join(HOME, value)
                if os.path.exists(target):
                    report.ok(section, "EXTRA_CONFIG_RO_PATHS: %s (read-only unless --allow-config)" % target)
                else:
                    report.note(section, "EXTRA_CONFIG_RO_PATHS entry doesn't exist: %s (skipped)" % target)

    for name in ("PROXY_LOG_DIR", "SINK_DIR"):
        value = scalars.get(name, "")
        if not value:
            continue
        target = expand(value)
        parent = os.path.dirname(target.rstrip("/")) or "/"
        if os.path.isdir(target) and os.access(target, os.W_OK):
            report.ok(section, "%s=%s exists and is writable" % (name, target))
        elif os.path.isdir(parent) and os.access(parent, os.W_OK):
            report.note(section, "%s=%s doesn't exist yet - %s creates it" % (name, target, RUN_SCRIPT))
        else:
            if IS_WINDOWS:
                hint = "an older session or another tool may have created it read-only: check the ACL on %s" % parent
            else:
                hint = "if an older session created it as root: sudo chown -R \"$USER\": %s" % parent
            report.warn(section, "%s=%s can't be created: %s isn't writable" % (name, target, parent), hint=hint)

    return settings


def check_mount_spec(report, section, spec):
    """EXTRA_MOUNTS entries go straight into `docker run -v`: host[:container[:ro]]."""
    if IS_WINDOWS:
        check_mount_spec_windows(report, section, spec)
        return
    parts = [expand(part) for part in spec.split(":")]
    if len(parts) > 3:
        report.fail(section, "EXTRA_MOUNTS entry '%s' isn't host[:container[:ro]]" % spec)
        return
    source = parts[0]
    if not os.path.exists(source):
        report.warn(section, "EXTRA_MOUNTS source doesn't exist: %s" % source,
                    hint="Docker creates the missing source as a root-owned empty directory - fix the path or drop the entry")
    if len(parts) >= 2:
        if not parts[1].startswith("/"):
            report.fail(section, "EXTRA_MOUNTS entry '%s': the container path must be absolute" % spec)
        if len(parts) == 3 and parts[2] not in ("ro", "rw"):
            report.fail(section, "EXTRA_MOUNTS entry '%s': unknown option '%s' (only ro or rw)" % (spec, parts[2]))


def check_mount_spec_windows(report, section, spec):
    """run.ps1 splits these with its own regex rather than on ':': the drive letter's colon
    is part of the host path, and the mount goes through `docker run --mount`, not -v."""
    match = re.match(r"^(?P<host>(?:[A-Za-z]:)?[^:]+)(?::(?P<target>/[^:]*))?(?::(?P<mode>ro|rw))?$", spec)
    if not match:
        report.fail(section, "EXTRA_MOUNTS entry '%s' isn't host[:container][:ro] - %s refuses it"
                    % (spec, RUN_SCRIPT),
                    hint="e.g. C:\\data (mounted at /c/data), C:\\data:/data or C:\\data:/data:ro")
        return
    source = expand(match.group("host"))
    target = match.group("target")
    if "," in source or "," in (target or ""):
        report.fail(section, "EXTRA_MOUNTS entry '%s' contains a ',' - %s can't mount it (docker --mount syntax)"
                    % (spec, RUN_SCRIPT),
                    hint="a comma can't be escaped in a --mount spec: keep that folder somewhere else")
    if not os.path.exists(source):
        report.warn(section, "EXTRA_MOUNTS source doesn't exist: %s" % source,
                    hint="%s stops with 'mount source doesn't exist' - unlike -v, --mount never creates it"
                         % RUN_SCRIPT)
    if target is None and not re.match(r"^[A-Za-z]:", source):
        report.fail(section, "EXTRA_MOUNTS entry '%s' has no container path, and '%s' can't be translated into one"
                    % (spec, source),
                    hint="only drive-letter paths map themselves (C:\\data -> /c/data); add ':/container' - docs/windows.md")


# --- docker env file ---------------------------------------------------------------

def resolve_env_file(report, section, scalars):
    """Same order as run.sh: --env-file (n/a here), ENV_FILE, else the default path if it
    exists. Returns the path in use, or None."""
    env_value = scalars.get("ENV_FILE", "")
    if env_value == "off":
        report.note(section, "env file off (ENV_FILE=off in %s)" % LOCAL_CONFIG)
        return None
    if env_value:
        path = expand(env_value)
        if not os.path.isfile(path):
            report.fail(section, "ENV_FILE points at a file that doesn't exist: %s" % path,
                        hint="%s stops with 'env file not found' - fix the path or remove ENV_FILE" % RUN_SCRIPT)
            return None
        report.ok(section, "env file from ENV_FILE: %s" % path)
        return path
    if os.path.isfile(DEFAULT_ENV_FILE):
        report.ok(section, "env file (default): %s" % DEFAULT_ENV_FILE)
        return DEFAULT_ENV_FILE
    if IS_WINDOWS:
        hint = ("create it (NTFS keeps your own profile private by default) or set $ENV_FILE in %s if your "
                "MCP config uses ${VAR}" % LOCAL_CONFIG)
    else:
        hint = "create it (chmod 600) or set ENV_FILE in %s if your MCP config uses ${VAR}" % LOCAL_CONFIG
    report.note(section, "no env file - %s doesn't exist (optional: tokens for MCP servers)" % DEFAULT_ENV_FILE,
                hint=hint)
    return None


def check_env_file(report, section, path, fix):
    """Docker env file format: KEY=value per line, a bare KEY copies it from the entry
    point's own environment, # starts a comment. run.sh/run.ps1 exit on a bad name or a
    reserved one, and warn about permissions and about the file inside the mounted project."""
    text = read_text(path)
    if text is None:
        report.fail(section, "can't read env file: %s" % path)
        return
    mode = os.stat(path).st_mode
    name = os.path.basename(path)
    if not IS_WINDOWS and mode & 0o077:
        # Only on POSIX: st_mode on Windows is a fixed 0o666 for any file, so its bits say
        # nothing about who can read it - the NTFS ACL does, which this can't read.
        report.warn(section, "%s is readable by other users (%03o) - it holds secrets" % (name, mode & 0o777),
                    hint="chmod 600 %s" % path)
        fix.apply("chmod 600 %s" % path, lambda: os.chmod(path, (mode & 0o7777) & ~0o0077))
    if not os.access(path, os.R_OK):
        report.fail(section, "%s is not readable by this user" % path)
        return
    if os.path.normcase(path).startswith(os.path.normcase(os.path.abspath(os.getcwd())) + os.sep):
        report.warn(section, "%s is inside the current directory, which is mounted into the session" % path,
                    hint="keep it outside your projects - the harness can read and edit anything it's mounted on")
    if "\r" in text:
        if IS_WINDOWS:
            hint = ("PowerShell writes files that way; %s trims the \\r when it reads the names, but docker "
                    "gets the file as written - rewrite it: (Get-Content -Raw '%s') -replace \"`r`n\", \"`n\" "
                    "| Set-Content -NoNewline '%s'" % (RUN_SCRIPT, path, path))
        else:
            hint = "docker keeps the \\r as part of the value: sed -i 's/\\r$//' %s" % path
        report.warn(section, "%s has CRLF line endings" % name, hint=hint)

    names = []
    problems = 0
    for lineno, line in enumerate(text.splitlines(), 1):
        line = line.rstrip("\r")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, _value = line.partition("=")
        key = key.strip()
        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            report.fail(section, "%s line %d: '%s' is not a valid variable name - %s refuses the whole file"
                        % (name, lineno, key, RUN_SCRIPT),
                        hint="KEY=value per line, no quotes or 'export' around the name")
            problems += 1
            continue
        if is_reserved_env(key):
            report.fail(section, "%s line %d: %s is reserved by the sandbox - %s refuses the whole file"
                        % (name, lineno, key, RUN_SCRIPT),
                        hint="an env file setting a proxy variable or HOME would quietly undo the egress allowlist")
            problems += 1
            continue
        if not sep:
            # A bare KEY copies the value from run.sh's environment; unset there means
            # the variable arrives empty, which usually surprises whoever wrote it.
            if key not in os.environ:
                report.warn(section, "%s line %d: bare %s copies from the environment, and %s isn't set there"
                            % (name, lineno, key, key),
                            hint="write %s=<value> instead" % key)
        names.append(key)
    if not problems:
        report.ok(section, "%s: %d variable%s (%s)" % (path, len(names), "" if len(names) == 1 else "s",
                                                      ", ".join(names) if names else "none"))


# --- the harness's files under $HOME -----------------------------------------------

FIRST_RUN_HINT = ("first run needs --allow-config so the harness can save its login - "
                  "see docs/quickstart-%s.md")


def check_home_paths(report, section, conf, name, fix):
    """run.sh mounts the harness's state at the same absolute path inside the container,
    and creates what's missing. A missing *file* is the dangerous case: Docker would
    create it as a root-owned directory, which is fatal for e.g. ~/.claude.json."""
    if not os.path.isdir(HOME):
        report.fail(section, "$HOME (%s) is not a directory" % HOME)
        return
    if not os.access(HOME, os.W_OK):
        report.fail(section, "$HOME (%s) is not writable - %s creates the harness's state dirs there"
                    % (HOME, RUN_SCRIPT))

    for entry in conf_list(conf, "state"):
        target = os.path.join(HOME, entry)
        if os.path.isdir(target):
            report.ok(section, "~/%s exists (mounted read-write: login, history, state)" % entry)
            check_owner(report, section, target)
        elif os.path.exists(target):
            report.fail(section, "~/%s is a file, but harness.conf 'state' needs a directory" % entry,
                        hint="Docker would refuse the mount - fix harnesses/%s/harness.conf or move the file" % name)
        else:
            def make(target=target):
                os.makedirs(target, exist_ok=True)

            fixed = fix.apply("created %s" % target, make)
            if not fixed:
                report.note(section, "~/%s doesn't exist yet - %s creates it" % (entry, RUN_SCRIPT),
                            hint=FIRST_RUN_HINT % name)

    for entry in conf_list(conf, "staged"):
        target = os.path.join(HOME, entry)
        if os.path.isdir(target):
            if IS_WINDOWS:
                hint = "remove that directory and re-run %s - see README.md Troubleshooting" % RUN_SCRIPT
            else:
                hint = ("sudo rmdir %s, then chown -R \"$USER\": %s - see README.md Troubleshooting"
                        % (target, os.path.dirname(target)))
            report.fail(section, "~/%s is a directory (left over from a run before that file existed)" % entry,
                        hint=hint)
            continue
        if os.path.isfile(target):
            report.ok(section, "~/%s exists (copied in read-only; edits are discarded on exit)" % entry)
            check_owner(report, section, target)
        else:
            def make(target=target):
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(target, "w", encoding="utf-8") as fh:
                    fh.write("{}\n" if target.endswith(".json") else "")

            if not fix.apply("created %s" % target, make):
                report.note(section, "~/%s doesn't exist yet - %s creates it" % (entry, RUN_SCRIPT),
                            hint=FIRST_RUN_HINT % name)

    present = [entry for entry in conf_list(conf, "config")
               if os.path.exists(os.path.join(HOME, entry))]
    missing = [entry for entry in conf_list(conf, "config")
               if not os.path.exists(os.path.join(HOME, entry))]
    if present:
        report.ok(section, "config paths present, read-only unless --allow-config: %s" % ", ".join(present))
    if missing:
        report.note(section, "config paths not on this host (%s skips them): %s" % (RUN_SCRIPT, ", ".join(missing)))

    for entry in conf_list(conf, "tmpfs"):
        report.note(section, "~/%s is container-local tmpfs: writable in the session, never reaches $HOME" % entry)


def check_owner(report, section, path):
    """A state dir owned by root is the leftover of an older run.sh creating a missing
    mount source; the harness then can't write its own login."""
    try:
        info = os.stat(path)
    except OSError:
        return
    uid = current_uid()
    if uid is None:
        return
    if info.st_uid != uid and info.st_uid != 0:
        report.warn(section, "%s is owned by uid %d, not you" % (path, info.st_uid),
                    hint="chown -R \"$USER\": %s" % path)
    elif info.st_uid == 0 and not os.access(path, os.W_OK):
        report.warn(section, "%s is owned by root and not writable by you" % path,
                    hint="sudo chown -R \"$USER\": %s - see README.md Troubleshooting" % path)


# --- image and project -------------------------------------------------------------

def build_input_files(name):
    """Everything the Dockerfile COPYs for this harness: touch one of these and the image
    is stale, which is the usual reason a change seems to have no effect."""
    files = [os.path.join(ROOT, "config", "allowed-domains.txt"),
             os.path.join(ROOT, "config", "extra-setup.sh")]
    for directory in (os.path.join(ROOT, "image"), os.path.join(ROOT, "harnesses", name)):
        for dirpath, dirnames, filenames in os.walk(directory):
            dirnames[:] = [d for d in dirnames if d != "__pycache__"]
            files.extend(os.path.join(dirpath, f) for f in filenames)
    return [f for f in files if os.path.isfile(f)]


def check_image(report, section, name):
    image = "agentcontainer:%s" % name
    code, out, _err = run(["docker", "image", "inspect", "--format", "{{.Id}}\t{{.Created}}", image])
    if code != 0:
        report.fail(section, "image %s not found - a session can't start" % image,
                    hint="%s %s" % (BUILD_CMD, name))
        return
    image_id, _, created = out.partition("\t")
    report.ok(section, "%s exists (%s)" % (image, image_id.split(":")[-1][:19]))
    try:
        # Docker reports "2026-11-09T18:20:00Z" (sometimes with sub-seconds); strip both
        # so fromisoformat works on every Python 3 the image's host might run.
        built = datetime.fromisoformat(re.sub(r"\.\d+", "", created.strip()).replace("Z", "+00:00"))
    except ValueError:
        return
    newest, newest_path = 0.0, None
    for path in build_input_files(name):
        mtime = os.path.getmtime(path)
        if mtime > newest:
            newest, newest_path = mtime, path
    if newest_path is None:
        return
    newest_dt = datetime.fromtimestamp(newest, tz=timezone.utc)
    if newest_dt > built:
        report.warn(section, "%s was built %s, before %s last changed - the change is not in the image"
                    % (image, built.strftime("%Y-%m-%d %H:%M"), os.path.relpath(newest_path, ROOT)),
                    hint="%s %s (README.md: a stale image runs the old version without warning)" % (BUILD_CMD, name))


def check_build_inputs(report, section, fix):
    """config/allowed-domains.txt and config/extra-setup.sh are gitignored but COPYed
    unconditionally, so build.sh seeds them from the .example - check that here too."""
    for filename, description in (("allowed-domains.txt", "your extra egress allowlist entries"),
                                  ("extra-setup.sh", "the no-op extra image setup")):
        path = os.path.join(ROOT, "config", filename)
        example = path + ".example"
        if os.path.isfile(path):
            report.ok(section, "config/%s exists (%s)" % (filename, description))
            continue
        fixed = fix.copy_if_missing(example, path, "created config/%s from the example" % filename)
        if not fixed:
            report.fail(section, "config/%s is missing - docker build can't COPY it" % filename)
        else:
            report.note(section, "config/%s was missing and has just been created from its .example" % filename,
                        hint="add your own entries - they only take effect after %s" % BUILD_CMD)

    path = os.path.join(ROOT, "config", "allowed-domains.txt")
    if os.path.isfile(path):
        check_allowlist(report, section, path, assembled=True)


def container_path(win_path):
    """run.ps1's ConvertTo-ContainerPath: C:\\Users\\me\\proj -> /c/Users/me/proj."""
    match = re.match(r"^([A-Za-z]):[\\/]?(.*)$", win_path)
    if not match:
        return None
    rest = match.group(2).replace("\\", "/").rstrip("/")
    return "/%s%s" % (match.group(1).lower(), "/" + rest if rest else "")


def check_project(report, section):
    """The session project is bind-mounted, so the path itself has to be mountable and
    writable. run.sh mounts $PWD at the same path; run.ps1 translates it (a drive letter's
    colon is not a problem there, because it mounts with --mount rather than -v)."""
    pwd = os.getcwd()
    if not os.access(pwd, os.W_OK):
        report.fail(section, "%s is not writable by you - the harness works in a bind mount of it" % pwd)
    elif IS_WINDOWS:
        target = container_path(pwd)
        report.ok(section, "session project: %s%s" % (pwd, " (mounted at %s)" % target if target else ""))
    else:
        report.ok(section, "session project: %s" % pwd)
    if IS_WINDOWS:
        if container_path(pwd) is None:
            report.fail(section, "%s isn't a drive-letter path - %s can't map it into the container"
                        % (pwd, RUN_SCRIPT),
                        hint=r"UNC and \\wsl.localhost paths are refused: open a WSL shell there and use run.sh "
                             "(docs/windows.md)")
        if "," in pwd:
            report.fail(section, "%s contains a ',' - %s can't mount it (docker --mount syntax)" % (pwd, RUN_SCRIPT),
                        hint="move the project somewhere without a comma")
    elif ":" in pwd:
        report.fail(section, "%s contains a ':' - run.sh passes it to docker -v, which splits on ':'" % pwd,
                    hint="run the session from a path without a colon, or use --mount host:container explicitly")
    if os.path.abspath(pwd) == ROOT:
        report.note(section, "this repo itself is the project - the sandbox can change its own files")

    # Git worktree: $PWD/.git is a file pointing outside $PWD, so the runner mounts the main
    # repo's git dir - but only after checking the links both ways (see run.sh).
    dot_git = os.path.join(pwd, ".git")
    if not os.path.isfile(dot_git):
        return
    if not shutil.which("git"):
        report.warn(section, "%s is a git worktree, but git isn't on PATH to resolve its git dir" % pwd)
        return
    code, worktree_git, _ = run(["git", "-C", pwd, "rev-parse", "--absolute-git-dir"])
    code2, common, _ = run(["git", "-C", pwd, "rev-parse", "--path-format=absolute", "--git-common-dir"])
    if code != 0 or code2 != 0:
        report.warn(section, "%s has a .git file, but git can't resolve it - git won't work in the container" % pwd)
        return
    worktree_git, common = worktree_git.strip(), common.strip()
    gitdir_link = os.path.join(worktree_git, "gitdir")
    back = read_text(gitdir_link)
    ok = (os.path.dirname(worktree_git) == os.path.join(common, "worktrees")
          and back is not None and os.path.realpath(back.strip()) == os.path.realpath(dot_git)
          and os.path.isfile(os.path.join(common, "HEAD"))
          and os.path.isdir(os.path.join(common, "objects"))
          and os.path.isdir(os.path.join(common, "refs")))
    if ok:
        report.ok(section, "git worktree: the main repo's git dir (%s) will be mounted read-write" % common)
    else:
        report.warn(section, "%s is a git worktree, but its git dir links don't check out - "
                            "git won't work in the container" % pwd,
                    hint="the worktree looks broken or was moved; see %s's worktree block" % RUN_SCRIPT)


# --- output ------------------------------------------------------------------------

MARKS = {"fail": "FAIL", "warn": "WARN", "note": "note", "ok": "ok  "}
COLORS = {"fail": "\033[31m", "warn": "\033[33m", "note": "\033[36m", "ok": "\033[32m"}
RESET = "\033[0m"


def print_report(report, quiet):
    color = sys.stdout.isatty() and os.environ.get("TERM") not in (None, "dumb") \
        and not os.environ.get("NO_COLOR")
    shown = [item for item in report.items
             if not quiet or item["level"] in ("fail", "warn")]
    section = None
    for item in shown:
        if item["section"] != section:
            section = item["section"]
            print("\n%s" % section)
        tag = MARKS[item["level"]]
        if color:
            tag = COLORS[item["level"]] + tag + RESET
        print("  %s  %s" % (tag, item["message"]))
        if item["hint"]:
            print("        -> %s" % item["hint"])


def print_summary(report, fix, strict):
    counts = report.counts()
    print("\nSummary: %d blocking, %d warning%s"
          % (counts["fail"], counts["warn"], "" if counts["warn"] == 1 else "s"))
    for description in fix.applied:
        print("  fixed: %s" % description)
    blocking = [item for item in report.items if item["level"] == "fail"]
    if blocking:
        print("\nWhat would stop a session:")
        for item in blocking:
            print("  - %s" % item["message"])
            if item["hint"]:
                print("    -> %s" % item["hint"])
    warnings = [item for item in report.items if item["level"] == "warn" and item["hint"]]
    if warnings:
        print("\nWorth fixing:")
        for item in warnings:
            print("  - %s" % item["message"])
            print("    -> %s" % item["hint"])
    if counts["fail"]:
        return 1
    if strict and counts["warn"]:
        return 1
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="doctor.py",
        description="Check whether a session on this machine would start, and say what's missing.",
        epilog="Reads the same config the entry point on this host reads (run.sh's or run.ps1's) and asks "
               "docker what it knows; it never starts a container, and writes nothing unless --fix is passed.",
    )
    parser.add_argument("harness", nargs="*",
                        help="harness name(s) to check (default: HARNESS from %s, else claude)" % LOCAL_CONFIG)
    parser.add_argument("--harness", dest="harness_flag", metavar="NAME",
                        help="same as a positional name, for symmetry with %s" % RUN_SCRIPT)
    parser.add_argument("--all", action="store_true", help="check every harness under harnesses/")
    fix_help = ("do the safe repairs: seed config/allowed-domains.txt and config/extra-setup.sh from their "
                ".example, create the harness's state dirs and staged files")
    if not IS_WINDOWS:
        fix_help += ", chmod 600 the env file, chmod +x the scripts"
    parser.add_argument("--fix", action="store_true", help=fix_help)
    parser.add_argument("--quiet", action="store_true", help="only show warnings and failures")
    parser.add_argument("--strict", action="store_true", help="also exit non-zero on warnings")
    parser.add_argument("--json", action="store_true", help="machine-readable report instead of text")
    args = parser.parse_args(argv)

    report = Report()
    fix = Fixer(args.fix)

    check_host(report, fix)
    check_repo(report)
    check_docker(report)
    settings = read_local_config(report)
    env_path = resolve_env_file(report, "Env file", settings["V"])
    if env_path:
        check_env_file(report, "Env file", env_path, fix)
    check_build_inputs(report, "Build inputs", fix)
    check_project(report, "Project")

    names = list(args.harness)
    if args.harness_flag:
        names.append(args.harness_flag)
    if args.all:
        names = sorted(
            entry for entry in os.listdir(os.path.join(ROOT, "harnesses"))
            if os.path.isfile(os.path.join(ROOT, "harnesses", entry, "harness.conf"))
        )
    if not names:
        names = [settings["V"].get("HARNESS") or "claude"]
    names = list(dict.fromkeys(names))  # the same harness named twice checks it once

    for name in names:
        section = "Harness %s" % name
        conf = check_harness_conf(report, section, name)
        if conf is None:
            continue
        harness_allowlist = os.path.join(ROOT, "harnesses", name, "allowed-domains.txt")
        if os.path.isfile(harness_allowlist):
            check_allowlist(report, section, harness_allowlist, assembled=True)
        check_home_paths(report, section, conf, name, fix)
        check_image(report, section, name)
        if conf_value(conf, "sandboxed_command").strip() and settings["V"].get("BASH_SANDBOX") == "0":
            report.warn(section, "BASH_SANDBOX=0: the Bash sandbox (%s) is off for every session on this machine"
                        % conf_value(conf, "sandboxed_command").strip())

    if args.json:
        print(json.dumps({
            "harnesses": names,
            "summary": report.counts(),
            "fixed": fix.applied,
            "items": report.items,
        }, indent=2))
        return 1 if report.counts()["fail"] else (1 if args.strict and report.counts()["warn"] else 0)

    print("Agent-Container setup check: %s" % ROOT)
    print_report(report, args.quiet)
    return print_summary(report, fix, args.strict)


if __name__ == "__main__":
    sys.exit(main())
