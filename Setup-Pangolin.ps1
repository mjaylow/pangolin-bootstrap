<#
.SYNOPSIS
    HThai Pangolin connector bootstrap - installs Newt and/or Olm as Windows services.

.DESCRIPTION
    Interactive installer for Pangolin tunnel clients (fosrl/newt, fosrl/olm) on
    HThai head office and store servers.

      1. Pick what to install (Newt only / Newt + Olm / Olm only)
      2. Provide the site/client IDs, secrets and endpoint
      3. Latest Windows binaries are downloaded into C:\_CDO\pangolin
      4. Each client is registered and started as a native Windows service
      5. A summary is printed
      6. Optionally run a 3-count ping test against an internal host

    Run from an elevated PowerShell. Bootstrap one-liner:
      irm https://raw.githubusercontent.com/<you>/pangolin-bootstrap/main/Setup-Pangolin.ps1 | iex

.NOTES
    Entity : HThai (Gill Capital)
    Clients: newt = site/network connector, olm = client-to-Newt tunnel
#>

[CmdletBinding()]
param(
    # Pangolin endpoint. Hardcoded default for HThai; leave as $null/empty to force a prompt.
    # >>> SET THIS to the HThai Pangolin endpoint, e.g. https://th-pangolin.prod.hthai-azure.gillcapitalinternal.com
    [string]$Endpoint = '',

    # Install root. Matches the Cambodia/H&M convention.
    [string]$InstallDir = 'C:\_CDO\pangolin'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference     = 'SilentlyContinue'   # suppress the slow/buggy IWR progress bar

# --- Repos / asset naming (confirmed from fosrl get-newt.sh / get-olm.sh) ----
$Repos = @{
    newt = @{ Repo = 'fosrl/newt'; Display = 'Newt (site connector)' }
    olm  = @{ Repo = 'fosrl/olm';  Display = 'Olm (client tunnel)'  }
}

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
    $headers = @{ 'User-Agent' = 'hthai-pangolin-bootstrap' }
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
    $headers = @{ 'User-Agent' = 'hthai-pangolin-bootstrap' }
    Invoke-WebRequest -Uri $url -OutFile $outPath -Headers $headers -TimeoutSec 120
    if (-not (Test-Path $outPath)) { throw "Download failed: $outPath not found" }
    $size = '{0:N1} MB' -f ((Get-Item $outPath).Length / 1MB)
    Write-Ok "Saved $Key.exe ($size)"
    return $outPath
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

    Write-Step "Configuring $disp as a Windows service"

    # Release any lock from a previously-running instance before (re)installing.
    Write-Info 'Stopping existing instance (ignored if not present)...'
    try { Invoke-Exe -Exe $Exe -ExeArgs @('stop') | Out-Null } catch { Write-Info 'nothing to stop.' }

    Write-Info 'Registering service...'
    try { Invoke-Exe -Exe $Exe -ExeArgs @('install') | Out-Null }
    catch { Write-Info 'install reported an issue (often: already installed) - continuing.' }

    Write-Info 'Starting with supplied credentials...'
    Invoke-Exe -Exe $Exe -ExeArgs @('start', '--id', $Id, '--secret', $Secret, '--endpoint', $Endpoint) | Out-Null

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

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host '======================================================' -ForegroundColor White
Write-Host '   HThai - Pangolin connector bootstrap (Newt / Olm)' -ForegroundColor White
Write-Host '======================================================' -ForegroundColor White

Assert-Admin
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12  # older Windows Server

# 1. What to install
Write-Step 'What do you want to install on this server?'
Write-Host '    1) Newt only'
Write-Host '    2) Newt + Olm'
Write-Host '    3) Olm only'
do { $choice = (Read-Host 'Select 1-3').Trim() } while ($choice -notin '1','2','3')

$doNewt = $choice -in '1','2'
$doOlm  = $choice -in '2','3'

# 2. Endpoint + credentials
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

# 3. Prep install dir
Write-Step "Preparing $InstallDir"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Ok "Created $InstallDir"
} else {
    Write-Info "$InstallDir already exists."
}

$arch = Get-Arch
Write-Info "Architecture: windows_$arch"

# 4. Download + install
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
    $r   = Install-Client -Key 'olm' -Exe $exe -Id $olmId -Secret $olmSecret -Endpoint $Endpoint
    $r | Add-Member -NotePropertyName Version -NotePropertyValue $ver
    $results += $r
}

# 5. Summary
Write-Host ''
Write-Host '======================================================' -ForegroundColor White
Write-Host '   SUMMARY' -ForegroundColor White
Write-Host '======================================================' -ForegroundColor White
Write-Info  "Host       : $env:COMPUTERNAME"
Write-Info  "Install dir: $InstallDir"
Write-Info  "Endpoint   : $Endpoint"
Write-Host ''
foreach ($r in $results) {
    $tag = if ($r.Running) { '[ RUNNING ]' } else { '[ CHECK ]' }
    $col = if ($r.Running) { 'Green' } else { 'Yellow' }
    Write-Host ("  {0,-11} {1,-22} v{2,-9} {3}" -f $tag, $r.Component, $r.Version, $r.Status) -ForegroundColor $col
}
Write-Host ''
Write-Warn2 'Security: secrets were typed into this console. Regenerate them in Pangolin once migration is verified.'
Write-Info  'Confirm each site/client shows Online in the Pangolin dashboard.'

# 6. Optional ping test
Write-Host ''
$ans = (Read-Host 'Run a connectivity ping test now? (y/N)').Trim().ToLower()
while ($ans -eq 'y' -or $ans -eq 'yes') {
    Write-Host ''
    Write-Host '    Target:' -ForegroundColor Gray
    Write-Host '      1) Head office server'
    Write-Host '      2) SQL / Data Director server'
    Write-Host '      3) Other'
    do { $t = (Read-Host '    Select 1-3').Trim() } while ($t -notin '1','2','3')
    $label = switch ($t) { '1' {'Head office'} '2' {'SQL / Data Director'} default {'Custom host'} }
    $ip = Read-Required "    Internal IP for $label"

    Write-Step "Pinging $label ($ip) x3"
    try {
        $ok = Test-Connection -ComputerName $ip -Count 3 -ErrorAction Stop
        foreach ($p in $ok) {
            $rtt = if ($null -ne $p.ResponseTime) { $p.ResponseTime } else { $p.Latency }
            Write-Host ("      reply from {0}  time={1}ms" -f $ip, $rtt) -ForegroundColor DarkGray
        }
        Write-Ok "$label ($ip) is reachable."
    } catch {
        Write-Err2 "$label ($ip) did not respond: $($_.Exception.Message)"
    }

    Write-Host ''
    $ans = (Read-Host 'Test another host? (y/N)').Trim().ToLower()
}

Write-Host ''
Write-Ok 'Done.'
