<#
.SYNOPSIS
    TH POS connector bootstrap - installs the Pangolin Olm client as a Windows
    service. The TH endpoint is hard-coded, so the operator only pastes the
    Olm ID and Secret from the provisioning sheet (machine / id / secret).

.DESCRIPTION
    Purpose-built for Thailand store POS terminals. Unlike the generic
    Setup-Pangolin.ps1, this script has no menus:

      1. Endpoint is fixed to the TH Pangolin server.
      2. Operator is prompted for Olm ID and Secret (the row for THIS POS).
      3. Latest olm + wintun are downloaded into C:\_CDO\pangolin.
      4. Olm is registered and started as an Automatic Windows service.
      5. A short summary + optional ping test confirm connectivity.

    Run from an ELEVATED PowerShell. One-liner (operator just pastes id/secret):
      irm https://raw.githubusercontent.com/<you>/pangolin-bootstrap/main/Setup-Pangolin-TH.ps1 | iex

    Non-interactive (e.g. from a deployment tool):
      ./Setup-Pangolin-TH.ps1 -Id <olmId> -Secret <olmSecret>

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
    [string]$InstallDir = 'C:\_CDO\pangolin'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'

# --- Fixed TH environment ---------------------------------------------------
$Endpoint   = 'https://th-pangolin.prod.hthai-azure.gillcapitalinternal.com'
$OlmRepo    = 'fosrl/olm'
$OlmService = 'OlmWireguardService'

# --- Wintun (olm needs the TUN driver DLL beside olm.exe) -------------------
$WintunVersion = '0.14.1'
$WintunUrl     = "https://www.wintun.net/builds/wintun-$WintunVersion.zip"
$WintunZipSha  = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'

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

    Write-Info "Fetching Wintun ${WintunVersion}"
    $tmpZip = Join-Path $env:TEMP "wintun-$WintunVersion.zip"
    $tmpDir = Join-Path $env:TEMP "wintun-$WintunVersion"
    Invoke-WebRequest -Uri $WintunUrl -OutFile $tmpZip -TimeoutSec 120

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

# 6. Optional connectivity test ----------------------------------------------
Write-Host ''
$ans = (Read-Host 'Ping an internal host reachable via th-ls-app? (y/N)').Trim().ToLower()
while ($ans -eq 'y' -or $ans -eq 'yes') {
    $target  = Read-Required '    Internal host or IP to ping'
    Write-Step "Pinging $target x3"
    $pingOut = & ping.exe -n 3 -w 1000 $target 2>&1
    foreach ($line in $pingOut) { if ("$line".Trim()) { Write-Host "      $line" -ForegroundColor DarkGray } }
    if ($LASTEXITCODE -eq 0 -and ($pingOut -match '(?i)Reply from')) { Write-Ok "$target is reachable." }
    else { Write-Err2 "$target did not respond." }
    Write-Host ''
    $ans = (Read-Host 'Test another? (y/N)').Trim().ToLower()
}

Write-Host ''
Write-Ok 'Done.'
