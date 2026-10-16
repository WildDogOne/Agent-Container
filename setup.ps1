# One-time Windows host setup for this sandbox: installs what build.ps1/run.ps1
# need - WSL2, Docker Desktop (WSL2 backend) and, unless told otherwise, Git for
# Windows. Safe to re-run: anything already in place is skipped (WSL just gets
# `wsl --update`d).
#
#   powershell -ExecutionPolicy Bypass -File .\setup.ps1 [-SkipGit] [-SkipDockerDesktop]
#
# Needs admin; if started without it, it relaunches itself elevated (UAC prompt) in a
# new window. A reboot is usually needed afterwards when WSL was freshly enabled - the
# script says so at the end.
#
# Docker Desktop licensing: free for personal use, education, non-commercial open
# source and small businesses (< 250 employees AND < USD 10M revenue); larger
# organizations need a paid subscription. Check that your use is covered.
#Requires -Version 5.1
param(
  [switch]$SkipGit,
  [switch]$SkipDockerDesktop,
  # Account to add to the docker-users group. Set by the non-elevated instance when it
  # relaunches itself, since the elevated one may be running as a different (admin)
  # account than the person who'll actually use Docker.
  [string]$ForUser = ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
# Invoke-WebRequest's progress bar slows multi-hundred-MB downloads down by an order of
# magnitude in Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'

. (Join-Path $PSScriptRoot 'lib\windows-common.ps1')
Assert-Windows

function Step([string]$msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Host 'Not running as administrator - relaunching elevated (accept the UAC prompt)...'
  # Start-Process joins -ArgumentList with plain spaces, no quoting - quote by hand.
  $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit',
    '-File', "`"$PSCommandPath`"", '-ForUser', "`"$ForUser`"")
  if ($SkipGit) { $relaunch += '-SkipGit' }
  if ($SkipDockerDesktop) { $relaunch += '-SkipDockerDesktop' }
  Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $relaunch
  exit 0
}

$rebootNeeded = $false
$isArm = ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64')

# --- Windows version --------------------------------------------------------------
# WSL2 needs build 19041 (Windows 10 2004) at the very least; current Docker Desktop
# releases only support Windows versions still in Microsoft's servicing window
# (Windows 10 22H2 = 19045, or Windows 11).
Step 'Checking Windows version'
$build = [Environment]::OSVersion.Version.Build
if ($build -lt 19041) {
  throw "Windows build $build is too old for WSL2 (needs 19041+ / Windows 10 2004). Update Windows first."
}
if ($build -lt 19045) {
  Write-Warning "Windows build ${build}: current Docker Desktop releases expect Windows 10 22H2 (19045) or Windows 11."
}
Write-Host "Windows build $build, $(if ($isArm) { 'ARM64' } else { 'x64' })"

# --- Virtualization ---------------------------------------------------------------
# VirtualizationFirmwareEnabled reads False whenever a hypervisor is already running
# (it's hidden from the guest-like root partition), so only trust it when no
# hypervisor is present yet.
Step 'Checking hardware virtualization'
$cs = Get-CimInstance Win32_ComputerSystem
if ($cs.HypervisorPresent) {
  Write-Host 'A hypervisor is already running - virtualization is enabled.'
} else {
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  if (-not $cpu.VirtualizationFirmwareEnabled) {
    Write-Warning ('Hardware virtualization looks DISABLED in firmware. Enable Intel VT-x / AMD-V (SVM) ' +
      'in the BIOS/UEFI setup, or WSL2 and Docker Desktop will not start.')
  } else {
    Write-Host 'Virtualization is enabled in firmware.'
  }
}

# --- WSL2 -------------------------------------------------------------------------
# No distro needed: Docker Desktop brings its own (docker-desktop). `--no-distribution`
# keeps `wsl --install` from also pulling Ubuntu - install one later with
# `wsl --install -d Ubuntu` if you want to run run.sh from inside WSL instead.
Step 'Setting up WSL2'
$missing = @()
foreach ($feature in @('Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform')) {
  $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature).State
  if ($state -ne 'Enabled') { $missing += $feature }
}
if ($missing.Count -gt 0) {
  Write-Host "Enabling: $($missing -join ', ')"
  & wsl.exe --install --no-distribution
  if ($LASTEXITCODE -ne 0) {
    # Older inbox wsl.exe without --install / --no-distribution: enable the features
    # directly; the WSL package itself gets pulled by `wsl --update` after the reboot.
    Write-Warning "'wsl --install' failed (exit $LASTEXITCODE) - enabling the Windows features directly."
    foreach ($feature in $missing) {
      $null = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart
    }
  }
  $rebootNeeded = $true
} else {
  Write-Host 'WSL features already enabled - updating WSL.'
  & wsl.exe --update
  if ($LASTEXITCODE -ne 0) { Write-Warning "'wsl --update' failed (exit $LASTEXITCODE) - continuing." }
  & wsl.exe --set-default-version 2
  if ($LASTEXITCODE -ne 0) { Write-Warning "'wsl --set-default-version 2' failed (exit $LASTEXITCODE) - continuing." }
}

# --- Git for Windows --------------------------------------------------------------
# Windows ships without git; needed to clone this repo and, on the host, for anything
# you do with your projects outside the container.
if (-not $SkipGit) {
  Step 'Checking Git for Windows'
  if (Get-Command git.exe -ErrorAction SilentlyContinue) {
    Write-Host "Already installed: $(Invoke-NativeCapture git.exe @('--version'))"
  } elseif (Get-Command winget.exe -ErrorAction SilentlyContinue) {
    & winget.exe install --exact --id Git.Git --source winget --silent `
      --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
      Write-Warning "winget failed to install Git (exit $LASTEXITCODE). Install it manually from https://git-scm.com/download/win"
    }
  } else {
    Write-Warning 'winget not available - install Git manually from https://git-scm.com/download/win'
  }
}

# --- Docker Desktop ---------------------------------------------------------------
$dockerExe = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
# Docker's own installer arguments, used by both install paths below. --override
# replaces winget's default silent switches outright, so --quiet has to be in here too.
$dockerInstallArgs = @('install', '--quiet', '--accept-license', '--backend=wsl-2')

# Fallback when winget is missing (LTSC/Server, or a fresh install whose App Installer
# hasn't updated yet) or fails: fetch the installer straight from Docker.
function Install-DockerDesktopDirect {
  $arch = 'amd64'
  if ($isArm) { $arch = 'arm64' }
  $url = "https://desktop.docker.com/win/main/$arch/Docker%20Desktop%20Installer.exe"
  $installer = Join-Path $env:TEMP 'DockerDesktopInstaller.exe'
  Write-Host "Downloading $url (~600 MB)..."
  # Windows PowerShell 5.1 on older .NET still defaults to TLS 1.0/1.1.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
  Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $installer

  # Refuse anything that isn't validly signed by Docker - a proxy/captive portal can
  # hand back an HTML page or worse instead of the installer. (winget does the
  # equivalent itself, against the hash in its package manifest.)
  $sig = Get-AuthenticodeSignature -FilePath $installer
  if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch 'Docker Inc') {
    Remove-Item $installer -Force
    throw "Downloaded installer isn't validly signed by Docker Inc (status: $($sig.Status)). Aborting."
  }

  Write-Host 'Installing Docker Desktop (WSL2 backend) - takes a few minutes...'
  $proc = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList $dockerInstallArgs
  Remove-Item $installer -Force -ErrorAction SilentlyContinue
  if ($proc.ExitCode -ne 0) {
    throw "Docker Desktop installer failed (exit $($proc.ExitCode))."
  }
}

if (-not $SkipDockerDesktop) {
  Step 'Checking Docker Desktop'
  if (Test-Path $dockerExe) {
    Write-Host 'Already installed (update with: winget upgrade --id Docker.DockerDesktop).'
  } else {
    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
      Write-Host 'Installing Docker Desktop via winget (WSL2 backend) - takes a few minutes...'
      & winget.exe install --exact --id Docker.DockerDesktop --source winget `
        --accept-package-agreements --accept-source-agreements `
        --override ($dockerInstallArgs -join ' ')
      # Judged by the result on disk rather than the exit code alone: winget also
      # returns non-zero for outcomes like "installed, reboot required".
      if (-not (Test-Path $dockerExe)) {
        Write-Warning "winget didn't install Docker Desktop (exit $LASTEXITCODE) - falling back to Docker's own installer."
        Install-DockerDesktopDirect
      }
    } else {
      Write-Host 'winget not available - using Docker''s own installer.'
      Install-DockerDesktopDirect
    }
    $rebootNeeded = $true
  }

  # The installer adds whoever ran it - which is the admin account if UAC elevated a
  # standard user with someone else's credentials. Docker Desktop refuses to start for
  # users outside this group.
  Step "Adding $ForUser to docker-users"
  try {
    Add-LocalGroupMember -Group 'docker-users' -Member $ForUser
    Write-Host "Added. $ForUser has to sign out and back in for it to take effect."
  } catch {
    # Matched by error id rather than `catch [MemberExistsException]`: that type only
    # exists once the LocalAccounts module has loaded, and a catch on an unknown type
    # is itself an error.
    if ($_.FullyQualifiedErrorId -match 'MemberExists') {
      Write-Host 'Already a member.'
    } else {
      Write-Warning "Couldn't add $ForUser to docker-users: $($_.Exception.Message)"
    }
  }
}

# --- Summary ----------------------------------------------------------------------
Step 'Done'
$n = 1
if ($rebootNeeded) {
  Write-Host "$n. REBOOT now (WSL/Docker Desktop were just installed or enabled)." -ForegroundColor Yellow; $n++
}
Write-Host "$n. Start Docker Desktop once and accept its terms; wait for 'Engine running'."; $n++
Write-Host "   (A bare 'wsl' saying 'no installed distributions' is expected - Docker Desktop"
Write-Host "   creates its own docker-desktop distro on first start; no Ubuntu needed.)"
Write-Host "$n. Open a NEW PowerShell window (so PATH has git/docker), then in this folder:"; $n++
Write-Host '     .\build.ps1'
Write-Host "$n. From a project folder, first run (logs in, saves the login):"
Write-Host "     $(Join-Path $PSScriptRoot 'run.ps1') --allow-config"
Write-Host ''
Write-Host 'If PowerShell refuses to run the scripts, allow local scripts for your user once:'
Write-Host '     Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
