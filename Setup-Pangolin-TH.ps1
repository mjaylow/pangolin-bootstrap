<#
.SYNOPSIS
    TH POS connector bootstrap - installs the Pangolin Olm client as a Windows
    service. The TH endpoint is hard-coded, so the operator only pastes the
    Olm ID and Secret from the provisioning sheet (machine / id / secret).

.DESCRIPTION
    Purpose-built for Thailand store POS terminals. Unlike the generic
    Setup-Pangolin.ps1, this script has no menus:

      0. Optionally install the Windows OpenSSH Server (prompted, default No).
      1. Endpoint is fixed to the TH Pangolin server.
      2. Operator is prompted for Olm ID and Secret (the row for THIS POS).
      3. Latest olm + wintun are downloaded into C:\_CDO\pangolin.
      4. Olm is registered and started as an Automatic Windows service.
      5. A short summary confirms the service state.

    Run from an ELEVATED PowerShell. One-liner (operator just pastes id/secret):
      irm https://raw.githubusercontent.com/<you>/pangolin-bootstrap/main/Setup-Pangolin-TH.ps1 | iex

    Non-interactive (e.g. from a deployment tool):
      ./Setup-Pangolin-TH.ps1 -Id <olmId> -Secret <olmSecret> -InstallSsh n

.NOTES
    Endpoint : https://th-pangolin.prod.hthai-azure.gillcapitalinternal.com
    Pairs with: New-PosOlmClients.ps1 (which generates the id/secret sheet).
#>

[CmdletBinding()]
param(
    # Olm credentials for THIS POS (from the machine/id/secret sheet).
    # Leave empty to be prompted.
    [string]$Id     = '',
    [string]$Secret = '',

    # Install root.
    [string]$InstallDir = 'C:\_CDO\pangolin',

    # Whether to also install the Windows OpenSSH Server for remote access.
    # Empty -> ask interactively. Pass 'y'/'n' (or -InstallSsh y) for unattended runs.
    [string]$InstallSsh = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

# --- Fixed TH environment ---------------------------------------------------
$Endpoint   = 'https://th-pangolin.prod.hthai-azure.gillcapitalinternal.com'
$OlmRepo    = 'fosrl/olm'
$OlmService = 'OlmWireguardService'

# --- Wintun (olm needs the TUN driver DLL beside olm.exe) -------------------
$WintunVersion = '0.14.1'
$WintunZipSha  = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'
# POS firewalls often allow GitHub but block wintun.net, so try the copy
# vendored in this repo first, then fall back to the canonical source. The
# SHA-256 below is verified after download regardless of which source served it.
$WintunUrls    = @(
    "https://raw.githubusercontent.com/mjaylow/pangolin-bootstrap/main/vendor/wintun-$WintunVersion.zip",
    "https://www.wintun.net/builds/wintun-$WintunVersion.zip"
)

# --- console helpers --------------------------------------------------------
function Write-Step  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info  { param([string]$m) Write-Host "    $m"     -ForegroundColor Gray }
function Write-Ok    { param([string]$m) Write-Host "    [ OK ] $m"   -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "    [WARN] $m"   -ForegroundColor Yellow }
function Write-Err2  { param([string]$m) Write-Host "    [FAIL] $m"   -ForegroundColor Red }

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Err2 'This script must run in an ELEVATED PowerShell (service install requires admin).'
        Write-Info 'Right-click PowerShell > Run as administrator, then re-run.'
        exit 1
    }
}

function Get-Arch {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'ARM64' { 'arm64' }
        default { 'amd64' }
    }
}

function Get-LatestOlmVersion {
    $api = "https://api.github.com/repos/$OlmRepo/releases/latest"
    Write-Info "Querying latest release: $api"
    $rel = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'pangolin-bootstrap' } -TimeoutSec 30
    $tag = $rel.tag_name -replace '^v', ''
    if (-not $tag) { throw "Could not resolve latest olm version" }
    return $tag
}

function Get-OlmBinary {
    param([string]$Version, [string]$Arch, [string]$DestDir)
    $asset   = "olm_windows_${Arch}.exe"
    $url     = "https://github.com/$OlmRepo/releases/download/$Version/$asset"
    $outPath = Join-Path $DestDir 'olm.exe'
    Write-Info "Download: $url"
    Invoke-WebRequest -Uri $url -OutFile $outPath -Headers @{ 'User-Agent' = 'pangolin-bootstrap' } -TimeoutSec 120
    if (-not (Test-Path $outPath)) { throw "Download failed: $outPath not found" }
    Write-Ok ("Saved olm.exe ({0:N1} MB)" -f ((Get-Item $outPath).Length / 1MB))
    return $outPath
}

function Install-Wintun {
    param([string]$DestDir, [string]$Arch)
    $dllPath = Join-Path $DestDir 'wintun.dll'
    if (Test-Path $dllPath) { Write-Info 'wintun.dll already present - skipping.'; return }

    $tmpZip = Join-Path $env:TEMP "wintun-$WintunVersion.zip"
    $tmpDir = Join-Path $env:TEMP "wintun-$WintunVersion"

    $headers     = @{ 'User-Agent' = 'pangolin-bootstrap' }
    $downloaded  = $false
    foreach ($u in $WintunUrls) {
        try {
            Write-Info "Fetching Wintun ${WintunVersion}: $u"
            Invoke-WebRequest -Uri $u -OutFile $tmpZip -Headers $headers -TimeoutSec 120
            $downloaded = $true
            break
        } catch {
            Write-Warn2 "Source unreachable ($u): $($_.Exception.Message)"
        }
    }
    if (-not $downloaded) { throw "Could not download wintun from any source (tried: $($WintunUrls -join ', '))" }

    $sha = (Get-FileHash -Path $tmpZip -Algorithm SHA256).Hash
    if ($sha -ne $WintunZipSha.ToUpper()) {
        Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
        throw "Wintun zip SHA-256 mismatch. Expected $WintunZipSha got $sha"
    }
    Write-Ok 'Wintun zip verified (SHA-256 match).'

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $src = Join-Path $tmpDir "wintun\bin\$Arch\wintun.dll"
    if (-not (Test-Path $src)) { throw "wintun.dll not found in archive for arch '$Arch'" }
    Copy-Item -Path $src -Destination $dllPath -Force
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Installed wintun.dll -> $dllPath"
}

function Install-OpenSSHFromGitHub {
    # Fallback path: pull the PowerShell/Win32-OpenSSH release zip from GitHub and
    # run its install-sshd.ps1. Used when Add-WindowsCapability is unavailable
    # (e.g. POS terminals with Windows Update / Features-on-Demand blocked). Same
    # source policy as olm/wintun: GitHub is reachable where other sources are not.
    $repo    = 'PowerShell/Win32-OpenSSH'
    $arch    = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'win64' }
    $headers = @{ 'User-Agent' = 'pangolin-bootstrap' }
    $api     = "https://api.github.com/repos/$repo/releases/latest"
    Write-Info "Querying latest Win32-OpenSSH release: $api"
    $rel   = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30
    $asset = $rel.assets | Where-Object { $_.name -like "OpenSSH-$arch*.zip" } | Select-Object -First 1
    if (-not $asset) { throw "No OpenSSH-$arch zip in latest $repo release" }

    $tmpZip = Join-Path $env:TEMP $asset.name
    $tmpDir = Join-Path $env:TEMP 'Win32-OpenSSH'
    Write-Info "Download: $($asset.browser_download_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $tmpZip -Headers $headers -TimeoutSec 180

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force
    $sshSrc = Get-ChildItem -Path $tmpDir -Directory |
              Where-Object { $_.Name -like 'OpenSSH-*' } | Select-Object -First 1
    if (-not $sshSrc) { throw 'Extracted OpenSSH folder not found in archive' }

    $target = Join-Path $env:ProgramFiles 'OpenSSH'
    if (-not (Test-Path $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
    Copy-Item -Path (Join-Path $sshSrc.FullName '*') -Destination $target -Recurse -Force

    $installScript = Join-Path $target 'install-sshd.ps1'
    if (-not (Test-Path $installScript)) { throw "install-sshd.ps1 missing in $target" }
    & powershell.exe -ExecutionPolicy Bypass -File $installScript | Out-Null

    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "OpenSSH Server installed from GitHub -> $target"
}

function Install-OpenSSHServer {
    # Ensure the Windows OpenSSH Server is installed, running and starts on boot.
    # Fastest path first (native Add-WindowsCapability); GitHub release zip as a
    # fallback when Windows Update / Features-on-Demand is unreachable.
    $sshService = 'sshd'

    if (Get-Service -Name $sshService -ErrorAction SilentlyContinue) {
        Write-Info 'OpenSSH Server already present - skipping install.'
    } else {
        $installed = $false
        try {
            Write-Info 'Installing OpenSSH Server via Add-WindowsCapability (fastest path)...'
            $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction Stop |
                   Where-Object { $_.Name -like 'OpenSSH.Server*' } | Select-Object -First 1
            if ($cap -and $cap.State -ne 'Installed') {
                Add-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
            }
            if (Get-Service -Name $sshService -ErrorAction SilentlyContinue) {
                $installed = $true
                Write-Ok 'OpenSSH Server installed (Windows capability).'
            }
        } catch {
            Write-Warn2 "Add-WindowsCapability unavailable ($($_.Exception.Message))."
        }
        if (-not $installed) {
            Write-Info 'Falling back to Win32-OpenSSH GitHub release...'
            Install-OpenSSHFromGitHub
        }
    }

    # Automatic startup so the box is reachable after a reboot with no logon.
    try {
        Set-Service -Name $sshService -StartupType Automatic -ErrorAction Stop
        Start-Service -Name $sshService -ErrorAction Stop
        $mode = (Get-CimInstance Win32_Service -Filter "Name='$sshService'" -ErrorAction SilentlyContinue).StartMode
        Write-Ok "OpenSSH Server ('$sshService') running, startup=$(if ($mode) { $mode } else { 'Auto' })."
    } catch {
        Write-Warn2 "Could not start/configure ${sshService}: $($_.Exception.Message)"
    }

    # Open the inbound firewall port if no rule exists yet.
    if (-not (Get-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue)) {
        try {
            New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' `
                -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
            Write-Ok 'Firewall rule for inbound TCP 22 created.'
        } catch {
            Write-Warn2 "Could not create SSH firewall rule: $($_.Exception.Message)"
        }
    }
}

function Resolve-SshChoice {
    # Decide whether to install OpenSSH Server. Honour an explicit -InstallSsh
    # value (for unattended runs); otherwise prompt, defaulting to No.
    param([string]$Pref)
    if ($Pref) { return ($Pref.Trim().ToLower() -in 'y','yes','true','1') }
    $ans = (Read-Host 'Install OpenSSH Server for remote access? (y/N)').Trim().ToLower()
    return ($ans -in 'y','yes')
}

function Invoke-Exe {
    param([string]$Exe, [string[]]$ExeArgs)
    Write-Info ("> olm {0}" -f ($ExeArgs -join ' '))
    $out = & $Exe @ExeArgs 2>&1 | Out-String
    foreach ($line in ($out -split "`r?`n")) { if ($line.Trim()) { Write-Host "      $line" -ForegroundColor DarkGray } }
    return $out
}

function Read-Required {
    param([string]$Prompt)
    do { $v = (Read-Host $Prompt).Trim() } while (-not $v)
    return $v
}

# ---------------------------------------------------------------------------
Write-Host '======================================================' -ForegroundColor White
Write-Host '   TH POS connector bootstrap (Olm)' -ForegroundColor White
Write-Host '======================================================' -ForegroundColor White
Write-Info "Endpoint : $Endpoint"
Write-Info "Host     : $env:COMPUTERNAME"

Assert-Admin
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 0. OpenSSH Server (optional) -----------------------------------------------
Write-Step 'OpenSSH Server (optional)'
if (Resolve-SshChoice -Pref $InstallSsh) {
    Install-OpenSSHServer
} else {
    Write-Info 'Skipping OpenSSH Server install.'
}

# 1. Credentials (from the machine/id/secret sheet) --------------------------
Write-Step 'Olm credentials for THIS POS'
Write-Info 'Copy the id and secret from the row matching this POS machine.'
if (-not $Id)     { $Id     = Read-Required '  Olm ID' }
if (-not $Secret) { $Secret = Read-Required '  Olm Secret' }

$arch = Get-Arch
Write-Info "Architecture: windows_$arch"

# 2. Prep install dir --------------------------------------------------------
Write-Step "Preparing $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Ok "Created $InstallDir"
} else {
    Write-Info "$InstallDir already exists."
}

# 3. Download olm + wintun ---------------------------------------------------
Write-Step 'Olm'
$ver = Get-LatestOlmVersion
Write-Ok "Latest olm version: $ver"
$exe = Get-OlmBinary -Version $ver -Arch $arch -DestDir $InstallDir
Install-Wintun -DestDir $InstallDir -Arch $arch

# 4. Install + start as a service --------------------------------------------
Write-Step 'Configuring Olm as a Windows service'
Write-Info 'Stopping existing instance (ignored if not present)...'
try { Invoke-Exe -Exe $exe -ExeArgs @('stop') | Out-Null } catch { Write-Info 'nothing to stop.' }

Write-Info 'Registering service...'
try { Invoke-Exe -Exe $exe -ExeArgs @('install') | Out-Null }
catch { Write-Info 'install reported an issue (often: already installed) - continuing.' }

Write-Info 'Starting with supplied credentials...'
Invoke-Exe -Exe $exe -ExeArgs @('start', '--id', $Id, '--secret', $Secret, '--endpoint', $Endpoint) | Out-Null

Write-Info "Setting '$OlmService' startup type to Automatic..."
$startMode = 'unknown'
try {
    Set-Service -Name $OlmService -StartupType Automatic -ErrorAction Stop
    $startMode = (Get-CimInstance Win32_Service -Filter "Name='$OlmService'" -ErrorAction SilentlyContinue).StartMode
    if (-not $startMode) { $startMode = 'Auto' }
    Write-Ok "Startup type: $startMode"
} catch {
    Write-Warn2 "Could not set startup type on ${OlmService}: $($_.Exception.Message)"
}

Start-Sleep -Seconds 2
Write-Info 'Status:'
$status  = Invoke-Exe -Exe $exe -ExeArgs @('status')
$running = $status -match '(?i)running'

# 5. Summary -----------------------------------------------------------------
Write-Host ''
Write-Host '======================================================' -ForegroundColor White
Write-Host '   SUMMARY' -ForegroundColor White
Write-Host '======================================================' -ForegroundColor White
Write-Info  "Host       : $env:COMPUTERNAME"
Write-Info  "Install dir: $InstallDir"
Write-Info  "Endpoint   : $Endpoint"
Write-Info  "Olm ID     : $Id"
Write-Info  "Version    : v$ver   startup=$startMode"
$tag = if ($running) { '[ RUNNING ]' } else { '[ CHECK ]' }
$col = if ($running) { 'Green' } else { 'Yellow' }
Write-Host ("  {0} Olm {1}" -f $tag, ($status.Trim() -split "`r?`n" | Select-Object -Last 1)) -ForegroundColor $col
Write-Host ''
if ($running) { Write-Ok 'Olm service is running.' }
else          { Write-Warn2 "Olm installed but status does not clearly show 'running' - verify in Pangolin (Clients > Machines)." }
Write-Info 'Confirm this client shows Connected in the Pangolin dashboard.'

Write-Host ''
Write-Ok 'Done.'
