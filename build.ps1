# Windows counterpart of build.sh: builds one devcontainer:<harness> image per harness
# through Docker Desktop's WSL2 backend - every harness under harnesses\ with no
# arguments, otherwise just the ones named (e.g. `.\build.ps1 claude`). Checks the
# prerequisites first (Docker CLI, WSL2, a running Linux-mode Docker engine - starting
# Docker Desktop if it isn't up yet), since on Windows those are the usual reasons a
# build fails before it even starts. setup.ps1 installs anything missing.
#
#   .\build.ps1 [harness...]
#
# If PowerShell refuses to run it ("running scripts is disabled on this system"), either
# allow local scripts once per user:
#   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# or bypass the policy for this one call:
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Captured first: dot-sourced helpers below get their own $args.
$harnesses = @($args)

. (Join-Path $PSScriptRoot 'lib\windows-common.ps1')

Assert-Windows
Assert-DockerCli
Assert-Wsl
Wait-DockerDaemon -StartDesktop
Assert-LinuxEngine

# Not fatal: the Hyper-V backend can build and run this image too, it's just not what
# setup.ps1 sets up or what this was written against.
$backend = Get-DockerBackend
if ($backend -ne 'wsl2') {
  Write-Warning ("Docker Desktop doesn't look like it's using the WSL2 backend (detected: $backend). " +
    "Settings -> General -> 'Use the WSL 2 based engine' is the supported setup.")
}

# Unlike the .sh scripts, a PowerShell script's cd leaks into the caller's session -
# Push/Pop-Location keeps the user's own working directory intact.
Push-Location $PSScriptRoot
try {
  # Same seeding as build.sh: extra-setup.sh is gitignored and the Dockerfile COPYs it
  # unconditionally, so a fresh clone gets a no-op copy instead of a failed build.
  if (-not (Test-Path 'config\extra-setup.sh')) {
    Copy-Item 'config\extra-setup.sh.example' 'config\extra-setup.sh'
  }
  # Same for allowed-domains.txt (also gitignored, also COPYed unconditionally) - but
  # said out loud, since unlike a no-op extra-setup.sh this decides what the container
  # can reach.
  if (-not (Test-Path 'config\allowed-domains.txt')) {
    Copy-Item 'config\allowed-domains.txt.example' 'config\allowed-domains.txt'
    Write-Host 'Created config\allowed-domains.txt - add your own egress allowlist entries there.'
  }

  $available = @(Get-ChildItem -Directory 'harnesses' | ForEach-Object { $_.Name })
  if ($harnesses.Count -eq 0) { $harnesses = $available }
  foreach ($h in $harnesses) {
    if (-not (Test-Path -LiteralPath "harnesses\$h\harness.conf" -PathType Leaf)) {
      throw "unknown harness '$h' - available: $($available -join ' ')"
    }
  }

  # CRLF line endings (a checkout with core.autocrlf=true, or a file saved in Notepad)
  # would break the shell scripts and squid's domain list inside the Linux image. The
  # Dockerfile strips them on COPY regardless; this just says so, so it isn't a surprise.
  foreach ($f in @('image\entrypoint.sh', 'image\squid.conf', 'config\extra-setup.sh', 'config\allowed-domains.txt')) {
    if ([IO.File]::ReadAllText((Join-Path $PSScriptRoot $f)).Contains("`r`n")) {
      Write-Host "note: $f has CRLF line endings - converted to LF inside the image."
    }
  }

  # Repo root as the build context, same as build.sh.
  foreach ($h in $harnesses) {
    Write-Host "Building devcontainer:$h"
    & docker.exe build --no-cache -f image/Dockerfile --build-arg "HARNESS=$h" -t "devcontainer:$h" .
    if ($LASTEXITCODE -ne 0) { throw "docker build failed for $h (exit code $LASTEXITCODE)." }
  }

  # See build.sh: --no-cache dangles the previous devcontainer:<harness> on every
  # rebuild; the label scopes the prune to our own leftovers.
  $null = Invoke-NativeQuiet docker.exe @('image', 'prune', '-f',
    '--filter', 'label=project=devcontainer', '--filter', 'dangling=true')
} finally {
  Pop-Location
}
