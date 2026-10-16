# Shared helpers for the Windows scripts (build.ps1, run.ps1) - dot-sourced, never run
# directly. Kept to Windows PowerShell 5.1 syntax (no `??`, `?:`, `&&`) and plain ASCII,
# since 5.1 is what every Windows install ships with and it reads BOM-less files as ANSI.

# Windows PowerShell 5.1 wraps a native command's redirected stderr in ErrorRecords,
# which $ErrorActionPreference = 'Stop' (set by both callers) turns into a terminating
# error - so `docker info 2>$null` would throw the moment the daemon is down instead of
# just returning a non-zero exit code. Every probe goes through these two instead.
function Invoke-NativeQuiet {
  param([string]$Exe, [string[]]$Arguments)
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $null = & $Exe @Arguments 2>&1
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  } finally {
    $ErrorActionPreference = $eap
  }
}

# Same as above, but returns trimmed stdout (stderr discarded), or $null on failure.
function Invoke-NativeCapture {
  param([string]$Exe, [string[]]$Arguments)
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @Arguments 2>$null
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($out | Out-String).Trim())
  } catch {
    return $null
  } finally {
    $ErrorActionPreference = $eap
  }
}

function Assert-Windows {
  if ($env:OS -ne 'Windows_NT') {
    throw "This script is for Windows. On Linux/macOS (or inside WSL) use the .sh scripts instead."
  }
}

function Assert-DockerCli {
  if (-not (Get-Command docker.exe -ErrorAction SilentlyContinue)) {
    throw ("docker.exe not found on PATH. Install Docker Desktop first (setup.ps1 does it), " +
      "then open a NEW PowerShell window so PATH picks it up.")
  }
}

# WSL itself, not a distro: Docker Desktop's WSL2 backend runs its own docker-desktop
# distro, so the user doesn't need Ubuntu or anything else installed - and a bare `wsl`
# complaining "no installed distributions" is expected, not a failure. `wsl --version`
# (Store WSL) or `wsl --status` (older inbox WSL) succeeding is taken as "installed";
# depending on the WSL version, `--status` alone can fail just for lack of a distro.
function Assert-Wsl {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw "wsl.exe not found - WSL2 isn't installed. Run setup.ps1 (as admin) first."
  }
  if (-not (Invoke-NativeQuiet wsl.exe @('--version')) -and -not (Invoke-NativeQuiet wsl.exe @('--status'))) {
    throw ("WSL is present but not set up ('wsl --status' failed). Run setup.ps1 (as admin), " +
      "or 'wsl --install --no-distribution' manually, then reboot.")
  }
}

function Test-DockerDaemon {
  return (Invoke-NativeQuiet docker.exe @('info', '--format', '{{.ServerVersion}}'))
}

# Waits for the Docker daemon to answer, starting Docker Desktop first if it isn't
# running and -StartDesktop is given. Docker Desktop takes anywhere from ~10s to a couple
# of minutes to bring its WSL2 VM up from cold, hence the generous default timeout.
function Wait-DockerDaemon {
  param([int]$TimeoutSeconds = 180, [switch]$StartDesktop)
  if (Test-DockerDaemon) { return }

  if (-not $StartDesktop) {
    throw "The Docker daemon isn't reachable. Start Docker Desktop and wait for it to say 'Engine running'."
  }

  $desktopExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
  if (-not (Get-Process -Name 'Docker Desktop' -ErrorAction SilentlyContinue)) {
    if (-not (Test-Path $desktopExe)) {
      throw "The Docker daemon isn't reachable and Docker Desktop isn't installed at '$desktopExe'. Run setup.ps1 first."
    }
    Write-Host "Docker Desktop isn't running - starting it..."
    Start-Process -FilePath $desktopExe | Out-Null
  } else {
    Write-Host "Docker Desktop is running but its engine isn't up yet - waiting..."
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (Test-DockerDaemon) {
      Write-Host "Docker engine is up."
      return
    }
  }
  throw ("Docker engine still not reachable after $TimeoutSeconds s. Check Docker Desktop's " +
    "window for an error (first start needs its license prompt accepted once).")
}

# Docker Desktop can be switched to Windows containers, where this Ubuntu-based image
# can't run at all.
function Assert-LinuxEngine {
  $osType = Invoke-NativeCapture docker.exe @('info', '--format', '{{.OSType}}')
  if ($osType -ne 'linux') {
    throw ("Docker Desktop is in Windows-containers mode (OSType '$osType'). Switch it via the " +
      "tray icon -> 'Switch to Linux containers...', then retry.")
  }
}

# 'wsl2', 'hyperv' or 'unknown', from the engine VM's kernel string. Docker Desktop's
# WSL2 kernel reports e.g. "5.15.153.1-microsoft-standard-WSL2"; the legacy Hyper-V
# backend runs its own LinuxKit kernel instead.
function Get-DockerBackend {
  $kernel = Invoke-NativeCapture docker.exe @('info', '--format', '{{.KernelVersion}}')
  if ($null -eq $kernel) { return 'unknown' }
  if ($kernel -match 'WSL2') { return 'wsl2' }
  if ($kernel -match 'linuxkit') { return 'hyperv' }
  return 'unknown'
}
