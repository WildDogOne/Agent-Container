# Windows counterpart of run.sh: launches a fresh, disposable sandbox container scoped to
# the current directory, through Docker Desktop. Same flags as run.sh (see run.sh's
# header and README.md for what each one does and why) - parsed by hand from $args rather
# than a param() block, so `--continue`-style harness flags pass through untouched:
#
#   cd C:\path\to\project
#   C:\path\to\Agent-Container\run.ps1 [--harness claude] [--allow-config] [--continue] ...
#
# Differences from run.sh, all forced by the host being Windows:
#
# - Paths can't be the same on both sides. C:\Users\me\proj is mounted at
#   /c/Users/me/proj, and dev's $HOME is %USERPROFILE% translated the same way. A
#   harness that also runs natively on Windows records Windows paths (e.g. Claude
#   Code's plugin installLocation, per-project settings in ~/.claude.json), which won't
#   match the container's - plugins registered natively may need re-registering inside.
# - No UID/GID remap by default: Windows has no UIDs, and Docker Desktop's bind mounts of
#   Windows folders accept writes from any container user and own the results by you.
#   CONTAINER_UID/CONTAINER_GID (environment or config\run.local.ps1) still force one.
# - No git-over-SSH: agent forwarding was removed from both ports by design (outbound
#   :22 is firewalled in the container); pushing is a host-side operation. Use HTTPS
#   remotes (gh auth) inside instead.
# - --sysbox is refused: sysbox can't be installed into Docker Desktop's VM.
# - --host-network shares the network of Docker Desktop's VM, not of Windows itself,
#   and skips the nftables egress firewall entrypoint.sh normally installs.
#
# A project that lives inside a WSL distro (\\wsl.localhost\...) is refused - open a WSL
# shell there and use run.sh instead; it's also much faster, since bind mounts of Windows
# drives go through a file-sharing layer that's slow on big trees (node_modules, .venv).
#
# Windows PowerShell 5.1 mangles embedded double quotes in arguments passed to native
# programs (docker.exe here), so a forwarded argument like `-p 'say "hi"'` may arrive
# altered. Plain arguments, including ones with spaces, are fine.
#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# Captured first: dot-sourced helpers below get their own $args.
$cliArgs = @($args)

. (Join-Path $PSScriptRoot 'lib\windows-common.ps1')
Assert-Windows

function Fail([string]$msg) {
  [Console]::Error.WriteLine("run.ps1: $msg")
  exit 1
}

# C:\Users\me\proj -> /c/Users/me/proj. Relative paths resolve against PowerShell's
# current location (not .NET's process cwd, which PowerShell doesn't keep in sync).
function Resolve-HostPath([string]$path) {
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
}
function ConvertTo-ContainerPath([string]$winPath) {
  if ($winPath -match '^([A-Za-z]):[\\/]?(.*)$') {
    $rest = ($Matches[2] -replace '\\', '/').TrimEnd('/')
    $drive = $Matches[1].ToLower()
    if ($rest) { return "/$drive/$rest" }
    return "/$drive"
  }
  Fail "can't map '$winPath' into the container - only drive-letter paths (C:\...) are supported, not UNC/network or WSL paths."
}

# One `docker run --mount` bind, from a Windows host path. --mount rather than -v: -v's
# colon-separated syntax collides with the drive letter's colon, and -v silently
# creates a missing source as an empty directory (the root-owned ~/.claude.json
# problem from README.md) where --mount refuses to start instead.
function Add-Bind([string]$hostPath, [string]$target, [switch]$ReadOnly) {
  if ($hostPath.Contains(',') -or $target.Contains(',')) {
    Fail "paths containing ',' can't be mounted (docker --mount syntax): $hostPath"
  }
  if (-not (Test-Path -LiteralPath $hostPath)) {
    Fail "mount source doesn't exist: $hostPath"
  }
  $spec = "type=bind,source=$hostPath,target=$target"
  if ($ReadOnly) { $spec += ',readonly' }
  $script:dockerArgs.Add('--mount')
  $script:dockerArgs.Add($spec)
}

# --mount / EXTRA_MOUNTS spec: host[:container][:ro|rw]. The drive letter's own colon
# is part of the host path, so this can't just split on ':' like run.sh. A bare path
# mounts at its translated container path, read-write. `C:\data:ro` (no container path)
# is accepted too, as same-path read-only.
function Add-MountSpec([string]$spec, [string]$origin) {
  if ($spec -notmatch '^(?<host>(?:[A-Za-z]:)?[^:]+)(?::(?<target>/[^:]*))?(?::(?<mode>ro|rw))?$') {
    Fail "invalid mount '$spec' ($origin) - expected host[:container][:ro], e.g. C:\data or C:\data:/data:ro"
  }
  $hostPath = Resolve-HostPath $Matches['host']
  $target = $Matches['target']
  $mode = $Matches['mode']
  if (-not $target) { $target = ConvertTo-ContainerPath $hostPath }
  Add-Bind $hostPath $target -ReadOnly:($mode -eq 'ro')
}

$cliHarness = ''
$hostNetwork = $false
$showHelp = $false
$allowList = ''
$allowInternet = $false
$allowContainer = $false
$allowConfig = $false
$withDocker = $false
$sysbox = $false
$cliBashSandbox = $false
$cliNoBashSandbox = $false
$cliEnvFile = ''
$noEnvFile = $false
$cliProxyLogs = ''   # '' = not passed, 'on' = --proxy-logs, 'off' = --no-proxy-logs
$cliProxyLogDir = ''
$cliInspect = ''     # '' = not passed, '1' = --inspect
$cliMounts = New-Object System.Collections.Generic.List[string]
$cliCaCerts = New-Object System.Collections.Generic.List[string]
$forward = New-Object System.Collections.Generic.List[string]

$i = 0
while ($i -lt $cliArgs.Count) {
  $a = [string]$cliArgs[$i]
  # Deprecated squid-era names (see run.sh): accepted with a warning.
  if ($a -ceq '--squid-logs' -or $a -ceq '--no-squid-logs' -or $a.StartsWith('--squid-logs=', [StringComparison]::Ordinal)) {
    $newArg = $a.Replace('squid-logs', 'proxy-logs')
    [Console]::Error.WriteLine("run.ps1: warning: $a is deprecated, use $newArg")
    $a = $newArg
  }
  switch -CaseSensitive ($a) {
    '--host-network'    { $hostNetwork = $true; $i++; continue }
    { $_ -eq '-h' -or $_ -eq '--help' } { $showHelp = $true; $i++; continue }
    '--allow-internet'  { $allowInternet = $true; $i++; continue }
    '--allow-container' { $allowContainer = $true; $i++; continue }
    '--allow-config'    { $allowConfig = $true; $i++; continue }
    '--with-docker'     { $withDocker = $true; $i++; continue }
    '--sysbox'          { $sysbox = $true; $i++; continue }
    '--bash-sandbox'    { $cliBashSandbox = $true; $i++; continue }
    '--no-bash-sandbox' { $cliNoBashSandbox = $true; $i++; continue }
    '--env-file' {
      if ($i + 1 -ge $cliArgs.Count) { Fail '--env-file requires a path argument' }
      $cliEnvFile = [string]$cliArgs[$i + 1]; $i += 2; continue
    }
    '--no-env-file'     { $noEnvFile = $true; $i++; continue }
    '--proxy-logs'      { $cliProxyLogs = 'on'; $i++; continue }
    '--no-proxy-logs'   { $cliProxyLogs = 'off'; $i++; continue }
    { $_ -like '--proxy-logs=*' } {
      $cliProxyLogs = 'on'
      $cliProxyLogDir = $a.Substring('--proxy-logs='.Length)
      if (-not $cliProxyLogDir) { Fail '--proxy-logs= requires a path (or use plain --proxy-logs for the default)' }
      $i++; continue
    }
    '--inspect'         { $cliInspect = '1'; $i++; continue }
    '--harness' {
      if ($i + 1 -ge $cliArgs.Count) { Fail '--harness requires a harness name' }
      $cliHarness = [string]$cliArgs[$i + 1]; $i += 2; continue
    }
    '--allow-list' {
      if ($i + 1 -ge $cliArgs.Count) { Fail '--allow-list requires a path argument' }
      $allowList = [string]$cliArgs[$i + 1]; $i += 2; continue
    }
    '--mount' {
      if ($i + 1 -ge $cliArgs.Count) { Fail '--mount requires a host path, or host:container[:ro], argument' }
      $cliMounts.Add([string]$cliArgs[$i + 1]); $i += 2; continue
    }
    '--ca-cert' {
      if ($i + 1 -ge $cliArgs.Count) { Fail '--ca-cert requires a host path to a CA certificate file' }
      $cliCaCerts.Add([string]$cliArgs[$i + 1]); $i += 2; continue
    }
    default { $forward.Add($a); $i++ }
  }
}

if ($allowList -and $allowInternet) { Fail '--allow-list and --allow-internet are mutually exclusive' }
if ($allowList) {
  $allowList = Resolve-HostPath $allowList
  if (-not (Test-Path -LiteralPath $allowList -PathType Leaf)) { Fail "--allow-list file not found: $allowList" }
}
if ($sysbox) {
  Fail '--sysbox is not available with Docker Desktop (sysbox-runc cannot be installed into its VM). Use run.sh on a Linux host for that. For a nested Docker daemon here, pass --with-docker instead.'
}
if ($allowContainer -and $withDocker) {
  Fail '--allow-container and --with-docker/--sysbox are mutually exclusive (one mounts the host''s Docker daemon, the other runs a nested one)'
}

$location = Get-Location
if ($location.Provider.Name -ne 'FileSystem') { Fail "current location isn't a filesystem path: $location" }
$projectDir = $location.ProviderPath
if ($projectDir.StartsWith('\\')) {
  Fail ("$projectDir is a UNC/network path. If it's inside WSL (\\wsl.localhost\...), open a " +
    "WSL shell there and run run.sh instead - same image, native paths, much faster.")
}
$projectTarget = ConvertTo-ContainerPath $projectDir

# Native harnesses on Windows (e.g. Claude Code) keep their login/config under
# %USERPROFILE%, same layout as ~ on Linux/macOS.
$hostHome = $env:USERPROFILE
$homeTarget = ConvertTo-ContainerPath $hostHome

# See run.sh. EXTRA_CONFIG_RO_PATHS is relative to %USERPROFILE%, extendable from
# config\run.local.ps1: $EXTRA_CONFIG_RO_PATHS += '.claude/statusline.ps1'
$EXTRA_MOUNTS = @()
$EXTRA_CONFIG_RO_PATHS = @()
# Additional root CA cert files (host paths) to import into the container's trust store
# at session start - see --ca-cert. run.local.ps1 can list personal defaults; --ca-cert
# adds to them per session.
$CA_CERTS = @()
$HARNESS = $env:HARNESS
if (-not $HARNESS) { $HARNESS = 'claude' }
$CONTAINER_UID = $env:CONTAINER_UID
$CONTAINER_GID = $env:CONTAINER_GID
$ENV_FILE = $env:ENV_FILE
# Not seeded from the environment (see run.sh): nested Docker, the Bash sandbox switch,
# TLS interception and log mirroring count only when run.local.ps1 or a flag sets them.
$WITH_DOCKER = $null
$BASH_SANDBOX = $null
$PROXY_LOGS = $null
$PROXY_LOG_DIR = $null
$INSPECT = $null
$localConfig = Join-Path $PSScriptRoot 'config\run.local.ps1'
if (Test-Path $localConfig) { . $localConfig }
# Deprecated squid-era settings (run.local.ps1 only, like the new names), see run.sh.
$oldSquidLogs = Get-Variable -Name SQUID_LOGS -ValueOnly -ErrorAction SilentlyContinue
if ($oldSquidLogs) {
  [Console]::Error.WriteLine('run.ps1: warning: SQUID_LOGS is deprecated, rename it to PROXY_LOGS (config\run.local.ps1)')
  if (-not $PROXY_LOGS) { $PROXY_LOGS = $oldSquidLogs }
}
$oldSquidLogDir = Get-Variable -Name SQUID_LOG_DIR -ValueOnly -ErrorAction SilentlyContinue
if ($oldSquidLogDir) {
  [Console]::Error.WriteLine('run.ps1: warning: SQUID_LOG_DIR is deprecated, rename it to PROXY_LOG_DIR (config\run.local.ps1)')
  if (-not $PROXY_LOG_DIR) { $PROXY_LOG_DIR = $oldSquidLogDir }
}

$withDockerSrc = '--with-docker passed'
if (-not $withDocker -and [string]$WITH_DOCKER -eq '1') {
  $withDocker = $true
  $withDockerSrc = '$WITH_DOCKER = 1 in run.local.ps1'
}
if ($allowContainer -and $withDocker) {
  Fail '--allow-container and --with-docker (or $WITH_DOCKER = 1 in run.local.ps1) are mutually exclusive'
}

$harnessName = $HARNESS
if ($cliHarness) { $harnessName = $cliHarness }
$harnessConfFile = Join-Path $PSScriptRoot "harnesses\$harnessName\harness.conf"
if (-not (Test-Path -LiteralPath $harnessConfFile -PathType Leaf)) {
  Fail "unknown harness '$harnessName' (no $harnessConfFile)"
}
$image = "agentcontainer:$harnessName"

# TLS interception: --inspect overrides $INSPECT = 1 in run.local.ps1. Off by
# default - see run.sh's header comment for why.
$inspect = $cliInspect -eq '1' -or [string]$INSPECT -eq '1'
# Proxy logs to the host: --proxy-logs / --no-proxy-logs override $PROXY_LOGS = 1 in
# run.local.ps1 (see run.sh's header comment for the mechanism). The per-session
# directory name carries a timestamp and the harness so sessions are greppable/
# sortable afterwards; a second session started in the same second gets the PID
# appended. The directory is only created on the real (non-help) path below.
$proxyLogs = $false
$proxyLogDir = ''
$proxyLogsDesc = ''
if ($cliProxyLogs -eq 'off') {
  $proxyLogsDesc = 'off (--no-proxy-logs passed)'
} elseif ($cliProxyLogs -eq 'on' -or [string]$PROXY_LOGS -eq '1') {
  $proxyLogs = $true
}
if ($proxyLogs) {
  $proxyLogBase = ''
  if ($cliProxyLogDir) { $proxyLogBase = $cliProxyLogDir }
  elseif ($PROXY_LOG_DIR) { $proxyLogBase = [string]$PROXY_LOG_DIR }
  # %LOCALAPPDATA% is the Windows counterpart of XDG's ~/.local/state.
  if ($proxyLogBase) { $proxyLogBase = Resolve-HostPath $proxyLogBase }
  else { $proxyLogBase = Join-Path $env:LOCALAPPDATA 'agentcontainer\logs' }
  $proxyLogDir = Join-Path $proxyLogBase ((Get-Date -Format 'yyyy-MM-dd-HHmmss') + '-' + $harnessName)
  if (Test-Path -LiteralPath $proxyLogDir) { $proxyLogDir = "$proxyLogDir-$PID" }
}

# See harnesses\README.md for the keys. Space-separated lists; last line wins.
function Get-HarnessConf([string]$key) {
  $value = ''
  foreach ($line in [IO.File]::ReadAllLines($harnessConfFile)) {
    if ($line.StartsWith("$key=")) { $value = $line.Substring($key.Length + 1).Trim() }
  }
  return $value
}
function Split-HarnessList([string]$value) {
  return @($value -split '\s+' | Where-Object { $_ })
}
$harnessState = @(Split-HarnessList (Get-HarnessConf 'state'))
$harnessStaged = @(Split-HarnessList (Get-HarnessConf 'staged'))
$harnessTmpfs = @(Split-HarnessList (Get-HarnessConf 'tmpfs'))
$configRoPaths = @(Split-HarnessList (Get-HarnessConf 'config')) + @($EXTRA_CONFIG_RO_PATHS)

# See run.sh: the Bash sandbox (harness's sandboxed_command) is ON by default where the
# harness defines one; --no-bash-sandbox or $BASH_SANDBOX = 0 turns it off,
# --bash-sandbox forces it on and fails if the harness has none.
$bashSandbox = $false
$sandboxedCommand = Get-HarnessConf 'sandboxed_command'
if ($cliNoBashSandbox -or [string]$BASH_SANDBOX -eq '0') {
  if ($cliNoBashSandbox) { $bashSandboxDesc = 'off (--no-bash-sandbox passed)' }
  else { $bashSandboxDesc = 'off (BASH_SANDBOX=0)' }
} elseif ($cliBashSandbox) {
  if (-not $sandboxedCommand) { Fail "--bash-sandbox: harness '$harnessName' has no sandboxed_command in its harness.conf" }
  $bashSandbox = $true
  $bashSandboxDesc = "ON (--bash-sandbox passed): $sandboxedCommand"
} elseif (-not $sandboxedCommand) {
  $bashSandboxDesc = "n/a (harness '$harnessName' has no sandboxed_command; plain command)"
} else {
  $bashSandbox = $true
  $bashSandboxDesc = "ON (default; --no-bash-sandbox to disable): $sandboxedCommand"
}

# See run.sh: --env-file, else ENV_FILE, else the default file if it exists; --no-env-file
# or ENV_FILE=off for none. Docker parses the file; the names are collected for
# entrypoint.sh (kept through the drop to dev) and checked against the variables the sandbox relies on.
if ($noEnvFile -and $cliEnvFile) { Fail '--env-file and --no-env-file are mutually exclusive' }
$defaultEnvFile = Join-Path $env:USERPROFILE '.config\agentcontainer.env'
$envFile = ''
if ($noEnvFile) { $envFileDesc = 'none (--no-env-file passed)' }
elseif ($cliEnvFile) { $envFile = $cliEnvFile; $envFileDesc = '--env-file passed' }
elseif ([string]$ENV_FILE -eq 'off') { $envFileDesc = 'none ($ENV_FILE = off)' }
elseif ($ENV_FILE) { $envFile = [string]$ENV_FILE; $envFileDesc = '$ENV_FILE' }
elseif (Test-Path -LiteralPath $defaultEnvFile -PathType Leaf) { $envFile = $defaultEnvFile; $envFileDesc = 'default' }
else { $envFileDesc = "none ($defaultEnvFile doesn't exist; pass --env-file or set `$ENV_FILE to use another file)" }
$envKeys = New-Object System.Collections.Generic.List[string]
if ($envFile) {
  $envFile = Resolve-HostPath $envFile
  if (-not (Test-Path -LiteralPath $envFile -PathType Leaf)) { Fail "env file not found: $envFile" }
  if ($envFile.StartsWith($projectDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
    [Console]::Error.WriteLine("run.ps1: warning: $envFile is inside $projectDir, which is mounted into the session - the harness can read and edit it")
  }
  foreach ($line in [IO.File]::ReadAllLines($envFile)) {
    $line = $line.TrimEnd("`r")
    if ($line -match '^\s*(#|$)') { continue }
    $key = $line.Split('=')[0]
    if ($key -cnotmatch '^[A-Za-z_][A-Za-z0-9_]*$') { Fail "${envFile}: invalid variable name '$key'" }
    if ($key -cmatch '^(HOME|PATH|USER|SHELL|SUDO_.*|HOST_.*|AGENTCONTAINER_.*|LD_.*|GCONV_PATH|OPENSSL_.*|INSPECT|PROXY_LOGS|PROXY_LOG_DIR|ALLOW_CONTAINER|WITH_DOCKER)$' -or
        $key -match '^(HTTP|HTTPS|NO|ALL)_PROXY$') {
      Fail "${envFile}: '$key' is reserved by the sandbox and can't be set from an env file"
    }
    $envKeys.Add($key)
  }
}
$envKeysJoined = $envKeys -join ','

# harness.conf paths are relative to the home directory, with forward slashes.
function Get-HostHomePath([string]$rel) { return (Join-Path $hostHome ($rel -replace '/', '\')) }

# See run.sh's remap block and the header comment above: off unless forced.
$remapUid = ''
$remapGid = ''
if ($CONTAINER_UID -and $CONTAINER_UID -ne 'off') {
  $remapUid = [string]$CONTAINER_UID
  $remapGid = [string]$CONTAINER_GID
  if (-not $remapGid) { $remapGid = $remapUid }
  if ($remapUid -notmatch '^[0-9]+$' -or $remapGid -notmatch '^[0-9]+$' -or [int64]$remapUid -eq 0 -or [int64]$remapGid -eq 0) {
    Fail "CONTAINER_UID/CONTAINER_GID must be non-zero numbers, or CONTAINER_UID=off (got '$remapUid'/'$remapGid')"
  }
  $remapDesc = "${remapUid}:${remapGid} (set by CONTAINER_UID/CONTAINER_GID)"
} else {
  $remapDesc = 'off (Windows host - dev stays 1000:1000)'
}

if ($showHelp) {
  if ($hostNetwork) { $netDesc = "host (--host-network passed - Docker Desktop VM's network, not Windows')" }
  else { $netDesc = 'bridge (default; pass --host-network to change)' }
  if ($allowInternet) { $listDesc = 'DISABLED (--allow-internet passed - any host/port reachable, nftables egress firewall also off)' }
  elseif ($allowList) { $listDesc = "$allowList (--allow-list passed, overrides image default)" }
  else { $listDesc = 'image default (allowed-domains.txt baked in at build; pass --allow-list to override)' }
  if ($allowContainer) { $sockDesc = "Docker Desktop's /var/run/docker.sock (--allow-container passed - root-equivalent access to its VM and every container in it)" }
  elseif ($withDocker) { $sockDesc = "nested dockerd in the container ($withDockerSrc; --privileged, since sysbox is unavailable on Docker Desktop)" }
  else { $sockDesc = 'none (default; pass --with-docker for a nested dockerd, --allow-container for the host daemon)' }
  if ($allowConfig) { $cfgDesc = 'WRITABLE (--allow-config passed - edits persist on the host)' }
  else { $cfgDesc = "read-only (default; pass --allow-config to let the harness change it)" }
  $harnessDesc = $harnessName
  if ($cliHarness) { $harnessDesc += ' (--harness passed)' }
  $available = (Get-ChildItem -Directory (Join-Path $PSScriptRoot 'harnesses') | ForEach-Object { $_.Name }) -join ' '
  $defaultCommand = Get-HarnessConf 'command'
  if ($envFile) {
    $envDesc = $envKeysJoined
    if (-not $envDesc) { $envDesc = 'no variables' }
    $envDesc = "$envFile (${envFileDesc}: $envDesc)"
  } else { $envDesc = $envFileDesc }

  @"
Usage: run.ps1 [--harness <name>] [--host-network] [--allow-list <path> | --allow-internet]
               [--allow-container | --with-docker] [--allow-config]
               [--mount <path|host:container[:ro]>]... [--ca-cert <path>]...
               [--no-bash-sandbox] [--env-file <path> | --no-env-file]
                [--proxy-logs[=<path>] | --no-proxy-logs] [--inspect]
               [-h|--help] [harness-args... | command...]

Windows/Docker Desktop version of run.sh - same flags, see run.sh --help or README.md
for what each one does. --sysbox is rejected here (sysbox-runc can't run in Docker
Desktop's VM; --with-docker works and falls back to --privileged). Mount specs take Windows host
paths: C:\data (-> /c/data, read-write), C:\data:/data, C:\data:/data:ro.
Available harnesses: $available

Anything else starting with '-' is forwarded to the harness itself (e.g. --continue).
A bare command (e.g. ``run.ps1 bash``) overrides the harness's default command
($defaultCommand).

Effective config on this machine:
  Harness:        $harnessDesc
  Image:          $image
  Network:        $netDesc
  Runtime:        $(if ($allowContainer) { 'plain runc, unprivileged (host socket mounted; no nested dockerd to privilege)' } elseif ($withDocker) { '--privileged (--with-docker; sysbox unavailable on Docker Desktop)' } else { 'plain runc, unprivileged (default; pass --with-docker for a nested dockerd)' })
  Allowlist:      $listDesc
  Docker socket:  $sockDesc
  Harness config: $cfgDesc
  dev UID:GID:    $remapDesc
  Bash sandbox:   $bashSandboxDesc
  Env file:       $envDesc
  Proxy logs:     $(if ($proxyLogs) { "$proxyLogDir (mirrored to the host)" } elseif ($proxyLogsDesc) { $proxyLogsDesc } else { 'container-only (/tmp, discarded on exit; --proxy-logs or $PROXY_LOGS = 1 to save them)' })
  TLS inspect:    $(if ($inspect) { 'ON (--inspect: HTTPS decrypted, bodies logged - expect breakage)' } else { 'off (HTTPS tunneled undecrypted; --inspect to intercept)' })
  Mounts:
    $projectDir -> $projectTarget
"@ | Write-Host
  foreach ($entry in $harnessState) {
    Write-Host "    $(Get-HostHomePath $entry) -> $homeTarget/$entry (dev's `$HOME is $homeTarget)"
  }
  foreach ($entry in $harnessTmpfs) {
    Write-Host "    (tmpfs $homeTarget/$entry - container-local, writable, discarded on exit)"
  }
  if ($allowConfig) {
    foreach ($entry in $harnessStaged) { Write-Host "    $(Get-HostHomePath $entry) -> $homeTarget/$entry" }
  } else {
    foreach ($entry in $configRoPaths) {
      if (Test-Path -LiteralPath (Get-HostHomePath $entry)) {
        Write-Host "    $(Get-HostHomePath $entry) -> $homeTarget/$entry (ro)"
      }
    }
    foreach ($entry in $harnessStaged) {
      Write-Host "    $(Get-HostHomePath $entry) -> copied in from a ro mount (edits discarded on exit)"
    }
  }
  Write-Host '    (no git-over-SSH: agent forwarding is gone by design - use HTTPS remotes / gh auth inside)'
  if (@($EXTRA_MOUNTS).Count -gt 0) {
    foreach ($m in $EXTRA_MOUNTS) { Write-Host "    $m (from config\run.local.ps1)" }
  } else {
    Write-Host '    (no config\run.local.ps1 extra mounts)'
  }
  foreach ($m in $cliMounts) { Write-Host "    $m (from --mount)" }
  $allCaCerts = @($CA_CERTS) + $cliCaCerts
  if (@($allCaCerts).Count -gt 0) {
    Write-Host "  Extra root CAs:  $(@($allCaCerts).Count) to import (run.local.ps1 CA_CERTS + --ca-cert):"
    foreach ($c in $allCaCerts) { Write-Host "    $c" }
  } else {
    Write-Host '  Extra root CAs:  none (pass --ca-cert or set CA_CERTS in run.local.ps1 to trust a private root)'
  }
  exit 0
}

Assert-DockerCli
# No auto-start here (unlike build.ps1): a launcher silently spending a minute or two
# booting Docker Desktop is more confusing than a clear "start Docker Desktop" error.
try {
  Wait-DockerDaemon
  Assert-LinuxEngine
} catch {
  Fail $_.Exception.Message
}
if (-not (Invoke-NativeQuiet docker.exe @('image', 'inspect', $image))) {
  Fail "image $image not found - run $(Join-Path $PSScriptRoot 'build.ps1') $harnessName first."
}

# First run without the harness on the host (README.md): --mount would refuse to start
# on a missing source anyway, so create the state dirs and staged files up front
# instead of making the user do it by hand. '{}' is what an empty JSON config (e.g.
# ~/.claude.json) should contain.
foreach ($entry in $harnessState) {
  $p = Get-HostHomePath $entry
  if (-not (Test-Path -LiteralPath $p)) {
    Write-Host "Creating $p (first run - log in with --allow-config once, see README.md)"
    $null = New-Item -ItemType Directory -Path $p
  }
}
foreach ($entry in $harnessStaged) {
  $p = Get-HostHomePath $entry
  if (Test-Path -LiteralPath $p -PathType Container) {
    Fail "$p is a directory (left over from a failed earlier mount?) - remove it and retry."
  }
  if (-not (Test-Path -LiteralPath $p)) {
    $parent = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $parent)) { $null = New-Item -ItemType Directory -Path $parent }
    if ($entry.EndsWith('.json')) { [IO.File]::WriteAllText($p, '{}') } else { [IO.File]::WriteAllText($p, '') }
  }
}

$dockerArgs = New-Object System.Collections.Generic.List[string]
# --init: docker-init is PID 1, not the harness (see run.sh).
$dockerArgs.AddRange([string[]]@('--rm', '-it', '--init', '-w', $projectTarget, '-e', "HOST_HOME=$homeTarget"))
Add-Bind $projectDir $projectTarget
foreach ($entry in $harnessState) { Add-Bind (Get-HostHomePath $entry) "$homeTarget/$entry" }
# See run.sh: harness.conf `tmpfs` paths are container-local tmpfs mounts covering a
# path inside a state mount (writable in the session, discarded on exit). entrypoint.sh
# chowns them to dev.
foreach ($entry in $harnessTmpfs) { $dockerArgs.AddRange([string[]]@('--tmpfs', "$homeTarget/$entry")) }

if ($remapUid) {
  $dockerArgs.AddRange([string[]]@('-e', "HOST_UID=$remapUid", '-e', "HOST_GID=$remapGid"))
}

# See run.sh: per-entry ro mounts nest inside the rw state mounts; staged files are
# mounted ro and copied into the container's writable layer by entrypoint.sh.
if ($allowConfig) {
  foreach ($entry in $harnessStaged) { Add-Bind (Get-HostHomePath $entry) "$homeTarget/$entry" }
} else {
  foreach ($entry in $configRoPaths) {
    $p = Get-HostHomePath $entry
    if (Test-Path -LiteralPath $p) { Add-Bind $p "$homeTarget/$entry" -ReadOnly }
  }
  foreach ($entry in $harnessStaged) {
    Add-Bind (Get-HostHomePath $entry) "/etc/agentcontainer/staged/$entry" -ReadOnly
  }
}

# See run.sh: Docker-in-Docker is opt-in (--with-docker). By default there is no nested
# dockerd and no --privileged at all. No sysbox on Docker Desktop (refused above), so
# --with-docker always uses --privileged here - note this is privileged within Docker
# Desktop's VM, not over Windows itself. --allow-container needs no privilege of its own
# (it just mounts the VM's socket), and entrypoint.sh then skips the nested dockerd.
# Docker Desktop exposes its daemon socket at /var/run/docker.sock inside its VM, so the
# Linux-style path is right even from a Windows CLI. -v rather than Add-Bind: the source
# is a path inside the VM, not on Windows, so it can't be Test-Path'ed here.
if ($allowContainer) {
  $dockerArgs.AddRange([string[]]@('-v', '/var/run/docker.sock:/var/run/docker.sock', '-e', 'ALLOW_CONTAINER=1'))
} elseif ($withDocker) {
  $dockerArgs.AddRange([string[]]@('--privileged', '-e', 'WITH_DOCKER=1'))
}

# See run.sh: the Bash sandbox (bubblewrap) needs namespace/mount syscalls that Docker's
# default seccomp profile reserves for CAP_SYS_ADMIN, and a fresh /proc that Docker's
# masked /proc paths prevent. --privileged (--with-docker) allows both already.
if ($bashSandbox -and -not $withDocker) {
  $dockerArgs.AddRange([string[]]@('--security-opt', ('seccomp=' + (Join-Path $PSScriptRoot 'lib\seccomp-userns.json')), '--security-opt', 'systempaths=unconfined'))
}

if ($hostNetwork) {
  Write-Warning '--host-network shares the Docker Desktop VM network namespace: the container reaches every service on that VM''s 127.0.0.1, and the nftables egress firewall is NOT installed (it would alter the VM''s ruleset). NET_ADMIN is not added either.'
  $dockerArgs.AddRange([string[]]@('--network', 'host', '-e', 'AGENTCONTAINER_HOST_NETWORK=1'))
} else {
  # The nftables egress firewall in entrypoint.sh needs NET_ADMIN (netns-scoped).
  $dockerArgs.AddRange([string[]]@('--cap-add', 'NET_ADMIN'))
}

if ($allowList) {
  Add-Bind $allowList '/etc/agentcontainer/allowed-hosts.override.txt' -ReadOnly
}
if ($allowInternet) { $dockerArgs.AddRange([string[]]@('-e', 'AGENTCONTAINER_ALLOW_INTERNET=1')) }
if ($inspect) { $dockerArgs.AddRange([string[]]@('-e', 'INSPECT=1')) }

# entrypoint.sh mirrors the proxy's /tmp logs into this read-write per-session mount (see
# run.sh's header comment). Created here, not at resolution time, so --help doesn't
# leave an empty directory behind.
if ($proxyLogs) {
  try {
    New-Item -ItemType Directory -Force -Path $proxyLogDir | Out-Null
  } catch {
    Fail "can't create the proxy log dir $proxyLogDir - if a parent of it is root-owned (an older docker run creating a missing mount source as root), repair it from a WSL/Linux shell: sudo chown -R `"`$USER `" <that parent>"
  }
  Add-Bind $proxyLogDir '/var/log/agentcontainer'
  # Also mount the base itself rw at the same path, so a run.sh started from *inside*
  # a sandbox can create its own session dir there (see run.sh).
  Add-Bind $proxyLogBase (ConvertTo-ContainerPath $proxyLogBase)
}

# Docker Desktop exposes its daemon socket at /var/run/docker.sock inside its VM, so the
# Linux-style path is right even from a Windows CLI. -v rather than Add-Bind: the source
# is a path inside the VM, not on Windows, so it can't be Test-Path'ed here.
if ($bashSandbox) { $dockerArgs.AddRange([string[]]@('-e', 'AGENTCONTAINER_BASH_SANDBOX=1')) }
elseif ($sandboxedCommand) { $dockerArgs.AddRange([string[]]@('-e', 'AGENTCONTAINER_BASH_SANDBOX=0')) }
if ($envFile) {
  $dockerArgs.AddRange([string[]]@('--env-file', $envFile))
  if ($envKeysJoined) { $dockerArgs.AddRange([string[]]@('-e', "AGENTCONTAINER_ENV_KEYS=$envKeysJoined")) }
}

foreach ($m in @($EXTRA_MOUNTS)) { Add-MountSpec ([string]$m) 'config\run.local.ps1' }
foreach ($m in $cliMounts) { Add-MountSpec $m '--mount' }

# --ca-cert / CA_CERTS: bind each CA file read-only under /etc/agentcontainer/ca-certs/;
# entrypoint.sh imports them into the container's trust store at start (see run.sh).
# Must be a file: Add-Bind's existence check alone would also accept a directory.
# Indexed target names, so two files with the same basename don't collide (see run.sh).
$caIndex = 0
foreach ($c in (@($CA_CERTS) + $cliCaCerts)) {
  $caHostPath = Resolve-HostPath ([string]$c)
  if (-not (Test-Path -LiteralPath $caHostPath -PathType Leaf)) {
    Fail "--ca-cert file not found: $caHostPath"
  }
  $caIndex++
  Add-Bind $caHostPath "/etc/agentcontainer/ca-certs/$caIndex-$(Split-Path -Leaf $caHostPath)" -ReadOnly
}

$dockerArgs.Add($image)
$dockerArgs.AddRange($forward)

$finalArgs = $dockerArgs.ToArray()
& docker.exe run @finalArgs
exit $LASTEXITCODE
