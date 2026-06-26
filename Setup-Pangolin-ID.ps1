<#
.SYNOPSIS
    Pangolin connector bootstrap (ID / Indonesia) - installs Newt and/or Olm as
    Windows services, with the Indonesia endpoint pre-filled as the default.

.DESCRIPTION
    Indonesia (ID) variant of Setup-Pangolin.ps1. Identical flow, but the
    Pangolin endpoint defaults to the ID server so the operator can just press
    Enter at the endpoint prompt. IDs and secrets are still supplied per run.

      1. Optionally install the Windows OpenSSH Server for remote access
      2. Pick what to install (Newt only / Newt + Olm / Olm only)
      3. Provide the site/client IDs and secrets (endpoint defaults to ID)
      4. Latest Windows binaries are downloaded into C:\_CDO\pangolin
      5. Each client is registered and started as a native Windows service
      6. A summary is printed, then an optional 3-count ping test

    Run from an elevated PowerShell. Bootstrap one-liner:
      irm https://raw.githubusercontent.com/<you>/pangolin-bootstrap/main/Setup-Pangolin-ID.ps1 | iex

.NOTES
    Endpoint : https://id-pangolin.prod.hthai-azure.gillcapitalinternal.com
    Clients  : newt = site/network connector, olm = client-to-Newt tunnel
#>

[CmdletBinding()]
param(
    # Indonesia (ID) Pangolin endpoint, pre-filled as the default. Operators press
    # Enter to accept, or pass -Endpoint to override.
    [string]$Endpoint = 'https://id-pangolin.prod.hthai-azure.gillcapitalinternal.com',

    # Install root (override with -InstallDir).
    [string]$InstallDir = 'C:\_CDO\pangolin',

    # Whether to also install the Windows OpenSSH Server for remote access.
    # Empty -> ask interactively. Pass 'y'/'n' (or -InstallSsh y) for unattended runs.
    [string]$InstallSsh = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # suppress the slow/buggy IWR progress bar

# --- Repos / asset naming (confirmed from fosrl get-newt.sh / get-olm.sh) ----
$Repos = @{
    newt = @{ Repo = 'fosrl/newt'; Display = 'Newt (site connector)'; Service = 'NewtWireguardService' }
    olm  = @{ Repo = 'fosrl/olm';  Display = 'Olm (client tunnel)';  Service = 'OlmWireguardService'  }
}

# --- Wintun (required by Olm only) ------------------------------------------
# Olm creates a real TUN adapter and needs wintun.dll beside olm.exe (this is
# exactly what fosrl's olm_windows_installer.exe bundles). Newt is userspace
# (netstack) and needs nothing. Signed DLL from the canonical WireGuard source.
$WintunVersion = '0.14.1'
$WintunZipSha  = '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51'
# POS/store firewalls often allow GitHub but block wintun.net, so try the copy
# vendored in this repo first, then fall back to the canonical source. The
# SHA-256 below is verified after download regardless of which source served it.
$WintunUrls    = @(
    "https://raw.githubusercontent.com/mjaylow/pangolin-bootstrap/main/vendor/wintun-$WintunVersion.zip",
    "https://www.wintun.net/builds/wintun-$WintunVersion.zip"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Write-Step  { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Info  { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }
function Write-Ok    { param([string]$m) Write-Host "    [ OK ] $m" -ForegroundColor Green }
function Write-Warn2 { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Err2  { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red }

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

function Get-LatestVersion {
    param([string]$Repo)
    $api = "https://api.github.com/repos/$Repo/releases/latest"
    Write-Info "Querying latest release: $api"
    $headers = @{ 'User-Agent' = 'pangolin-bootstrap' }
    $rel = Invoke-RestMethod -Uri $api -Headers $headers -TimeoutSec 30
    $tag = $rel.tag_name -replace '^v', ''
    if (-not $tag) { throw "Could not resolve latest version for $Repo" }
    return $tag
}

function Get-Binary {
    param(
        [string]$Key,    # newt | olm
        [string]$Version,
        [string]$Arch,
        [string]$DestDir
    )
    $repo    = $Repos[$Key].Repo
    $asset   = "${Key}_windows_${Arch}.exe"
    $url     = "https://github.com/$repo/releases/download/$Version/$asset"
    $outPath = Join-Path $DestDir "$Key.exe"

    Write-Info "Download: $url"
    Write-Info "Target  : $outPath"
    $headers = @{ 'User-Agent' = 'pangolin-bootstrap' }
    Invoke-WebRequest -Uri $url -OutFile $outPath -Headers $headers -TimeoutSec 120
    if (-not (Test-Path $outPath)) { throw "Download failed: $outPath not found" }
    $size = '{0:N1} MB' -f ((Get-Item $outPath).Length / 1MB)
    Write-Ok "Saved $Key.exe ($size)"
    return $outPath
}

function Install-Wintun {
    # Ensure wintun.dll sits next to olm.exe so Olm can create its TUN adapter.
    param([string]$DestDir, [string]$Arch)

    $dllPath = Join-Path $DestDir 'wintun.dll'
    if (Test-Path $dllPath) {
        Write-Info "wintun.dll already present ($dllPath) - skipping download."
        return
    }

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
    Write-Ok "Wintun zip verified (SHA-256 match)."

    if (Test-Path $tmpDir) { Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $tmpZip -DestinationPath $tmpDir -Force

    $src = Join-Path $tmpDir "wintun\bin\$Arch\wintun.dll"
    if (-not (Test-Path $src)) { throw "wintun.dll not found in archive for arch '$Arch' ($src)" }
    Copy-Item -Path $src -Destination $dllPath -Force
    Remove-Item $tmpZip -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Ok "Installed wintun.dll -> $dllPath"
}

function Install-OpenSSHFromGitHub {
    # Fallback path: pull the PowerShell/Win32-OpenSSH release zip from GitHub and
    # run its install-sshd.ps1. Used when Add-WindowsCapability is unavailable
    # (e.g. store servers with Windows Update / Features-on-Demand blocked). Same
    # source policy as the newt/olm/wintun downloads: GitHub is reachable where
    # other sources are not.
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

function Invoke-Exe {
    # Run the client exe, echo each line, return combined output text.
    param([string]$Exe, [string[]]$ExeArgs)
    Write-Info ("> {0} {1}" -f (Split-Path $Exe -Leaf), ($ExeArgs -join ' '))
    $out = & $Exe @ExeArgs 2>&1 | Out-String
    foreach ($line in ($out -split "`r?`n")) {
        if ($line.Trim()) { Write-Host "      $line" -ForegroundColor DarkGray }
    }
    return $out
}

function Install-Client {
    param(
        [string]$Key,
        [string]$Exe,
        [string]$Id,
        [string]$Secret,
        [string]$Endpoint
    )
    $disp = $Repos[$Key].Display
    $svc  = $Repos[$Key].Service

    Write-Step "Configuring $disp as a Windows service"

    # Release any lock from a previously-running instance before (re)installing.
    Write-Info 'Stopping existing instance (ignored if not present)...'
    try { Invoke-Exe -Exe $Exe -ExeArgs @('stop') | Out-Null } catch { Write-Info 'nothing to stop.' }

    Write-Info 'Registering service...'
    try { Invoke-Exe -Exe $Exe -ExeArgs @('install') | Out-Null }
    catch { Write-Info 'install reported an issue (often: already installed) - continuing.' }

    Write-Info 'Starting with supplied credentials...'
    Invoke-Exe -Exe $Exe -ExeArgs @('start', '--id', $Id, '--secret', $Secret, '--endpoint', $Endpoint) | Out-Null

    # The client's installer registers the service as Manual start; force Automatic so it
    # comes up on boot without anyone logging in.
    Write-Info "Setting '$svc' startup type to Automatic..."
    $startMode = 'unknown'
    try {
        Set-Service -Name $svc -StartupType Automatic -ErrorAction Stop
        $startMode = (Get-CimInstance Win32_Service -Filter "Name='$svc'" -ErrorAction SilentlyContinue).StartMode
        if (-not $startMode) { $startMode = 'Auto' }
        Write-Ok "Startup type: $startMode"
    } catch {
        Write-Warn2 "Could not set startup type on ${svc}: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds 2
    Write-Info 'Status:'
    $status = Invoke-Exe -Exe $Exe -ExeArgs @('status')

    $running = $status -match '(?i)running'
    if ($running) { Write-Ok "$disp service is running." }
    else          { Write-Warn2 "$disp installed but status does not clearly show 'running' - verify in Pangolin." }

    return [pscustomobject]@{
        Component = $disp
        Exe       = $Exe
        Running   = [bool]$running
        StartMode = $startMode
        Status    = ($status.Trim() -split "`r?`n" | Select-Object -Last 1)
    }
}

function Read-Required {
    param([string]$Prompt)
    do { $v = (Read-Host $Prompt).Trim() } while (-not $v)
    return $v
}

function Resolve-Endpoint {
    param([string]$Default)
    if ($Default) {
        $v = (Read-Host "Endpoint [$Default]").Trim()
        if (-not $v) { return $Default }
        return $v
    }
    Write-Warn2 'No default endpoint is hardcoded in this script.'
    return (Read-Required 'Pangolin endpoint (https://...)')
}

function Resolve-SshChoice {
    # Decide whether to install OpenSSH Server. Honour an explicit -InstallSsh
    # value (for unattended runs); otherwise prompt, defaulting to No.
    param([string]$Pref)
    if ($Pref) { return ($Pref.Trim().ToLower() -in 'y','yes','true','1') }
    $ans = (Read-Host 'Install OpenSSH Server for remote access? (y/N)').Trim().ToLower()
    return ($ans -in 'y','yes')
}

function Uninstall-Client {
    # Stop + remove the Windows service (the client's own 'uninstall' does both),
    # then optionally delete the binary and saved config.
    param([string]$Key, [string]$InstallDir, [bool]$PurgeFiles)

    $disp = $Repos[$Key].Display
    $svc  = $Repos[$Key].Service
    $exe  = Join-Path $InstallDir "$Key.exe"

    Write-Step "Removing $disp"

    if (Test-Path $exe) {
        Write-Info 'Stopping + removing service via client...'
        try { Invoke-Exe -Exe $exe -ExeArgs @('uninstall') | Out-Null }
        catch { Write-Warn2 "client uninstall reported: $($_.Exception.Message)" }
    } else {
        Write-Info "$exe not found - will remove the service by name if present."
    }

    # Fallback / verify via SCM in case the binary was missing or uninstall failed.
    if (Get-Service -Name $svc -ErrorAction SilentlyContinue) {
        Write-Info "Service '$svc' still present; removing via SCM..."
        try { Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue } catch {}
        & sc.exe delete $svc | Out-Null
        Start-Sleep -Seconds 1
    }

    $gone = -not (Get-Service -Name $svc -ErrorAction SilentlyContinue)
    if ($gone) { Write-Ok "$disp service removed." }
    else       { Write-Warn2 "$disp service may still be present - check services.msc ($svc)." }

    if ($PurgeFiles) {
        Write-Info 'Purging files...'
        $targets = @($exe)
        if ($Key -eq 'olm') { $targets += (Join-Path $InstallDir 'wintun.dll') }   # only Olm uses it
        $targets += (Join-Path $env:PROGRAMDATA $Key)                              # service_args.json + logs
        foreach ($p in $targets) {
            if (Test-Path $p) {
                try { Remove-Item $p -Recurse -Force -ErrorAction Stop; Write-Info "deleted $p" }
                catch { Write-Warn2 "could not delete ${p}: $($_.Exception.Message)" }
            }
        }
    }

    return [pscustomobject]@{
        Component = $disp
        Removed   = $gone
        Purged    = [bool]$PurgeFiles
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host '======================================================' -ForegroundColor White
Write-Host '   Pangolin connector bootstrap (Newt / Olm)' -ForegroundColor White
Write-Host '======================================================' -ForegroundColor White

Assert-Admin
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12  # older Windows Server

# 1. Mode
Write-Step 'What do you want to do?'
Write-Host '    1) Install / repair'
Write-Host '    2) Uninstall'
do { $mode = (Read-Host 'Select 1-2').Trim() } while ($mode -notin '1','2')
$isInstall = $mode -eq '1'
$verb = if ($isInstall) { 'install' } else { 'uninstall' }

# 2. Components
Write-Step "Which component(s) to $verb on this server?"
Write-Host '    1) Newt only'
Write-Host '    2) Newt + Olm'
Write-Host '    3) Olm only'
do { $choice = (Read-Host 'Select 1-3').Trim() } while ($choice -notin '1','2','3')

$doNewt = $choice -in '1','2'
$doOlm  = $choice -in '2','3'

$arch = Get-Arch

# ===========================================================================
# UNINSTALL
# ===========================================================================
if (-not $isInstall) {
    $sel = @(); if ($doNewt) { $sel += 'Newt' }; if ($doOlm) { $sel += 'Olm' }
    Write-Step ("About to remove: {0}" -f ($sel -join ' + '))
    $purge = ((Read-Host 'Also delete binaries + saved config (C:\_CDO\pangolin exe, C:\ProgramData\<client>)? (y/N)').Trim().ToLower()) -in 'y','yes'
    $confirm = (Read-Host "Type 'yes' to confirm uninstall").Trim().ToLower()
    if ($confirm -ne 'yes') { Write-Warn2 'Cancelled. Nothing changed.'; return }

    $results = @()
    if ($doNewt) { $results += Uninstall-Client -Key 'newt' -InstallDir $InstallDir -PurgeFiles $purge }
    if ($doOlm)  { $results += Uninstall-Client -Key 'olm'  -InstallDir $InstallDir -PurgeFiles $purge }

    Write-Host ''
    Write-Host '======================================================' -ForegroundColor White
    Write-Host '   SUMMARY (uninstall)' -ForegroundColor White
    Write-Host '======================================================' -ForegroundColor White
    Write-Info "Host: $env:COMPUTERNAME"
    Write-Host ''
    foreach ($r in $results) {
        $tag = if ($r.Removed) { '[ REMOVED ]' } else { '[ CHECK ]' }
        $col = if ($r.Removed) { 'Green' } else { 'Yellow' }
        $files = if ($r.Purged) { 'files purged' } else { 'files kept' }
        Write-Host ("  {0,-11} {1,-22} {2}" -f $tag, $r.Component, $files) -ForegroundColor $col
    }
    Write-Host ''
    Write-Ok 'Done.'
    return
}

# ===========================================================================
# INSTALL
# ===========================================================================
# 0. OpenSSH Server (optional) - so the box can be remotely reachable for the
#    rest of the rollout and any follow-up support, independent of Pangolin.
Write-Step 'OpenSSH Server (optional)'
if (Resolve-SshChoice -Pref $InstallSsh) {
    Install-OpenSSHServer
} else {
    Write-Info 'Skipping OpenSSH Server install.'
}

# 3. Endpoint + credentials
Write-Step 'Connection details'
$Endpoint = Resolve-Endpoint -Default $Endpoint
Write-Info "Endpoint: $Endpoint"

if ($doNewt) {
    Write-Host ''
    Write-Info 'Newt credentials (Pangolin > Sites):'
    $newtId     = Read-Required '  Newt site ID'
    $newtSecret = Read-Required '  Newt secret'
}
if ($doOlm) {
    Write-Host ''
    Write-Info 'Olm credentials (Pangolin > Clients):'
    $olmId     = Read-Required '  Olm client ID'
    $olmSecret = Read-Required '  Olm secret'
}

# 4. Prep install dir
Write-Step "Preparing $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Ok "Created $InstallDir"
} else {
    Write-Info "$InstallDir already exists."
}
Write-Info "Architecture: windows_$arch"

# 5. Download + install
$results = @()

if ($doNewt) {
    Write-Step 'Newt'
    $ver = Get-LatestVersion -Repo $Repos.newt.Repo
    Write-Ok "Latest newt version: $ver"
    $exe = Get-Binary -Key 'newt' -Version $ver -Arch $arch -DestDir $InstallDir
    $r   = Install-Client -Key 'newt' -Exe $exe -Id $newtId -Secret $newtSecret -Endpoint $Endpoint
    $r | Add-Member -NotePropertyName Version -NotePropertyValue $ver
    $results += $r
}

if ($doOlm) {
    Write-Step 'Olm'
    $ver = Get-LatestVersion -Repo $Repos.olm.Repo
    Write-Ok "Latest olm version: $ver"
    $exe = Get-Binary -Key 'olm' -Version $ver -Arch $arch -DestDir $InstallDir
    Install-Wintun -DestDir $InstallDir -Arch $arch   # Olm needs the TUN driver DLL
    $r   = Install-Client -Key 'olm' -Exe $exe -Id $olmId -Secret $olmSecret -Endpoint $Endpoint
    $r | Add-Member -NotePropertyName Version -NotePropertyValue $ver
    $results += $r
}

# 6. Summary
Write-Host ''
Write-Host '======================================================' -ForegroundColor White
Write-Host '   SUMMARY (install)' -ForegroundColor White
Write-Host '======================================================' -ForegroundColor White
Write-Info  "Host       : $env:COMPUTERNAME"
Write-Info  "Install dir: $InstallDir"
Write-Info  "Endpoint   : $Endpoint"
Write-Host ''
foreach ($r in $results) {
    $tag = if ($r.Running) { '[ RUNNING ]' } else { '[ CHECK ]' }
    $col = if ($r.Running) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-11} {1,-22} v{2,-8} startup={3,-9} {4}" -f $tag, $r.Component, $r.Version, $r.StartMode, $r.Status) -ForegroundColor $col
}
Write-Host ''
Write-Warn2 'Security: secrets were typed into this console. Regenerate them in Pangolin once migration is verified.'
Write-Info  'Confirm each site/client shows Online in the Pangolin dashboard.'

# 7. Optional connectivity test
Write-Host ''
$ans = (Read-Host 'Ping an internal service/server reachable over Pangolin? (y/N)').Trim().ToLower()
while ($ans -eq 'y' -or $ans -eq 'yes') {
    $target = Read-Required '    Internal host or IP to ping'

    Write-Step "Pinging $target x3"
    # ping.exe is more robust than Test-Connection, which can throw
    # "Error due to lack of resources" via its WMI/Win32_PingStatus backend.
    $pingOut = & ping.exe -n 3 -w 1000 $target 2>&1
    foreach ($line in $pingOut) {
        if ("$line".Trim()) { Write-Host "      $line" -ForegroundColor DarkGray }
    }
    if ($LASTEXITCODE -eq 0 -and ($pingOut -match '(?i)Reply from')) {
        Write-Ok "$target is reachable."
    } else {
        Write-Err2 "$target did not respond (no successful replies)."
    }

    Write-Host ''
    $ans = (Read-Host 'Test another? (y/N)').Trim().ToLower()
}

Write-Host ''
Write-Ok 'Done.'
