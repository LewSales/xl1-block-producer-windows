<#
.SYNOPSIS
  Apply pending Windows updates and reboot if required.

.DESCRIPTION
  xl1-autoupdate.ps1 handles xl1-cli; this is the OS layer underneath it, the
  same distinction xl1-host-update.sh draws on the Pi. Acts on whichever
  trigger fires first:

    - $Threshold or more updates pending          (default 10)
    - $MaxAgeHours since the last applied install (default 72h)

  Scheduled every 6h by Setup.ps1 as "XL1 Host Update". The script itself
  decides whether 6h-old news is worth acting on yet.

.EXAMPLE
  .\xl1-host-update.ps1            check, and install if due
  .\xl1-host-update.ps1 -Check     report only, change nothing
#>
[CmdletBinding()]
param(
  [int]$Threshold   = 10,
  [int]$MaxAgeHours = 72,
  [switch]$Check
)

$ErrorActionPreference = 'Stop'
$Root     = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $Root 'state'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
$LastFile = Join-Path $StateDir '.host-update-last'

function Log { param($m) Write-Host ("{0} xl1-host-update: {1}" -f (Get-Date -Format o), $m) }

try {
  $session  = New-Object -ComObject Microsoft.Update.Session
  $searcher = $session.CreateUpdateSearcher()
  $found    = $searcher.Search('IsInstalled=0 and IsHidden=0').Updates
} catch {
  Log "update search failed: $($_.Exception.Message) -- leaving updates alone"
  exit 1
}
$pending = @($found).Count

$last = 0
if (Test-Path $LastFile) { $last = [int64](Get-Content $LastFile -Raw) }
$ageHours = ((Get-Date).ToUniversalTime() - [DateTimeOffset]::FromUnixTimeSeconds($last).UtcDateTime).TotalHours

if ($pending -lt $Threshold -and $ageHours -lt $MaxAgeHours) {
  Log "$pending pending (threshold $Threshold), last applied $([math]::Round($ageHours,1))h ago (max ${MaxAgeHours}h) -- nothing to do"
  exit 0
}

Log "$pending pending / last applied $([math]::Round($ageHours,1))h ago -- installing"
if ($Check) { Log '-Check given, stopping here'; exit 0 }

$nowEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

if ($pending -eq 0) {
  # Nothing to install but the age trigger fired -- record the check so the
  # 72h clock resets rather than firing again on every run.
  Set-Content -Path $LastFile -Value $nowEpoch -NoNewline
  Log 'nothing pending to install'
  exit 0
}

$toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
foreach ($u in $found) { $toInstall.Add($u) | Out-Null }

try {
  $downloader = $session.CreateUpdateDownloader()
  $downloader.Updates = $toInstall
  $downloader.Download() | Out-Null

  $installer = $session.CreateUpdateInstaller()
  $installer.Updates = $toInstall
  $result = $installer.Install()
} catch {
  Log "install failed: $($_.Exception.Message)"
  exit 1
}

# ResultCode: 2=succeeded, 3=succeeded with errors, 4=failed, 5=cancelled.
Log "install result code $($result.ResultCode)"
Set-Content -Path $LastFile -Value $nowEpoch -NoNewline

if ($result.RebootRequired) {
  Log 'reboot required -- restarting in 60 seconds'
  # Both containers run restart:unless-stopped, and Docker Desktop is set to
  # start on sign-in, so they come back once the host is up and someone is
  # signed back in -- the same caveat Setup.ps1 already documents for Windows.
  & shutdown.exe /r /t 60 /c 'xl1-host-update: rebooting to finish an applied Windows update'
} else {
  Log 'no reboot required'
}
