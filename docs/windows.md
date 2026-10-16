# Windows hosts

On Windows, the sandbox runs through Docker Desktop with its WSL2 backend. Three
PowerShell scripts stand in for the shell scripts:

| Script      | Linux/macOS equivalent | What it does                                                        |
|-------------|------------------------|---------------------------------------------------------------------|
| `setup.ps1` | none                   | One-time host setup: WSL2, Docker Desktop, Git for Windows          |
| `build.ps1` | `build.sh`             | Checks WSL2 and Docker, starts Docker Desktop if needed, then builds |
| `run.ps1`   | `run.sh`               | Launches a session in the current directory, with the same flags    |

They're written for Windows PowerShell 5.1, which every Windows 10/11 install ships with,
and they also run under PowerShell 7.

> [!NOTE]
> The Windows scripts haven't been tested on a real Windows host yet. If something
> breaks, `run.ps1 --help` shows the mounts and settings it resolved.

## 1. Install Git

Windows doesn't include git, and you need it to clone this repo. Install Git for Windows
with `winget`, which is built into current Windows 10/11:

```powershell
winget install --exact --id Git.Git --source winget
```

Or download the installer from <https://git-scm.com/download/win>. Then open a **new**
PowerShell window so `git` is on `PATH`, and clone the repo:

```powershell
git clone https://github.com/WildDogOne/Devcontainer.git
cd Devcontainer
```

`setup.ps1` also installs Git if it's still missing, unless you pass `-SkipGit`. That
only helps if you got the repo some other way, such as a ZIP download.

## 2. Set up the host

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

The script asks for admin rights through a UAC prompt and continues in a new, elevated
window. You can run it again later; it skips whatever is already installed. It does
the following:

1. Checks the Windows build. WSL2 needs 19041 or later, and Docker Desktop expects
   Windows 10 22H2 or Windows 11. It also checks that hardware virtualization (VT-x or
   AMD-V) is enabled in the firmware.
2. Enables WSL2 with `wsl --install --no-distribution`. Docker Desktop brings its own
   distro, so no Ubuntu is installed. If WSL is already set up, it runs `wsl --update`.
   Running a bare `wsl` afterwards prints "no installed distributions". That's
   expected. Docker Desktop creates its `docker-desktop` distro on first start.
3. Installs Git for Windows through `winget`, unless you pass `-SkipGit`.
4. Installs Docker Desktop with the WSL2 backend through `winget`
   (`Docker.DockerDesktop`). Without `winget`, or if `winget` fails, it downloads
   Docker's installer directly, checks that it's signed by Docker Inc, and runs it
   silently. Pass `-SkipDockerDesktop` to skip this. Update later with
   `winget upgrade --id Docker.DockerDesktop`, or from Docker Desktop's own settings.
5. Adds your account to the `docker-users` group.

Afterwards:

- **Reboot** if the script says so. A reboot is needed after WSL or Docker Desktop was
  first installed.
- Sign out and back in, so the `docker-users` membership takes effect.
- Start Docker Desktop once and accept its terms.

Docker Desktop is free for personal use, education, non-commercial open source and small
businesses. Larger organizations need a paid subscription.

### Execution policy

By default, Windows doesn't run unsigned `.ps1` files. To allow local scripts for your
own account, run this once:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

Or prefix each call with `powershell -ExecutionPolicy Bypass -File`.

## 3. Build

```powershell
.\build.ps1
```

Before building, `build.ps1` checks that:

- `docker.exe` is on `PATH`.
- WSL is installed (`wsl --status`).
- The Docker engine is reachable. If it isn't, the script starts Docker Desktop and
  waits up to 3 minutes for it.
- Docker Desktop is in Linux-containers mode, not Windows-containers mode.

It warns if Docker Desktop isn't using the WSL2 backend. Then it builds and prunes the
images exactly like `build.sh`, including creating `config\allowed-domains.txt` and
`config\extra-setup.sh` from their `.example` files if they don't exist yet. Like
`build.sh`, it builds every harness by default, or only the ones you name
(`.\build.ps1 claude`).

## 4. Run

```powershell
cd C:\path\to\project
C:\path\to\Devcontainer\run.ps1 --allow-config   # first run: log in, see README.md
C:\path\to\Devcontainer\run.ps1                  # afterwards
```

On the first run, `run.ps1` creates the harness's state under `%USERPROFILE%` for you
(for Claude Code, `.claude` and `.claude.json`).

To launch it by a short name, add a function to your PowerShell profile (`notepad $PROFILE`):

```powershell
function claudecli { & 'C:\path\to\Devcontainer\run.ps1' @args }
```

`run.ps1` takes the same flags as `run.sh`; see [Usage](../README.md#usage). For a
per-machine config like `run.local.sh`, copy `config\run.local.ps1.example` to
`config\run.local.ps1`.

## How it differs from Linux

- **Paths.** Windows paths can't appear unchanged inside a Linux container, so
  `C:\Users\me\proj` is mounted at `/c/Users/me/proj`. Inside the container, `$HOME`
  is `%USERPROFILE%` translated the same way. If you also run the harness natively on
  Windows, it may record Windows paths: Claude Code does (plugin `installLocation`,
  per-project entries in `~/.claude.json`). Those don't match inside the container,
  so plugins registered natively may have to be registered again from inside.
- **`--mount` syntax.** Use a Windows host path: `C:\data` (mounted at `/c/data`,
  read-write), `C:\data:/data` or `C:\data:/data:ro`. Paths containing `,` can't be
  mounted.
- **No UID/GID remap.** Windows has no UIDs, and Docker Desktop lets any container user
  write to mounted Windows folders. To force a remap anyway, set `CONTAINER_UID` and
  `CONTAINER_GID`.
- **No SSH agent forwarding.** The Windows OpenSSH agent is a named pipe, which can't be
  passed into a Linux container. Inside the container, use HTTPS remotes with `gh auth
  login` instead.
- **No `--sysbox`.** Sysbox can't be installed in Docker Desktop's VM. `--privileged`
  only applies inside that VM, not to Windows itself.
- **`--host-network`** shares the network of Docker Desktop's VM, not the network of
  Windows itself.
- **`--allow-container`** mounts Docker Desktop's own daemon socket.
- **Speed.** Mounted Windows folders go through a file-sharing layer that is slow on
  large trees, such as `node_modules` or `.venv`.

### Alternative: run from inside WSL

If a project lives inside a WSL distro, for example `\\wsl.localhost\Ubuntu\home\me\proj`,
`run.ps1` refuses to start. Open a WSL shell there and use `build.sh` and `run.sh`
instead. Docker Desktop's WSL integration provides `docker` inside the distro
(Settings -> Resources -> WSL integration). File access is much faster there, and paths
stay the same on both sides, as on Linux.

## Line endings

A Windows checkout with `core.autocrlf=true` would normally convert files to CRLF,
which breaks shell scripts and squid's domain list inside the Linux image. Three things
prevent that:

- `.gitattributes` keeps every tracked file LF, except `*.ps1`.
- The Dockerfile strips CRs from everything it copies in, including gitignored files you
  edited in Notepad (`config\allowed-domains.txt`, `config\extra-setup.sh`).
- `entrypoint.sh` does the same for an `--allow-list` file.
