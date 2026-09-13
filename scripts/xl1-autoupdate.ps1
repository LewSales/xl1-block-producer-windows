<#
.SYNOPSIS
  Check the published manifest and rebuild if a newer xl1-cli has shipped.

.DESCRIPTION
  The Pi downloads prebuilt arm64 bundles because building on a Pi 3 B+ is
  impractical. This machine builds its own images in minutes, so it updates the
  way it already builds: pull the repo, run Build.ps1 against the new xl1-cli,
  restart. No release tarballs, nothing to publish, and the same Build.ps1 that
  already refuses an image whose reported version is not the one asked for.

  Reads the same /xl1/latest.json the Pi and the WinLEW APK read, so there is one
  manifest describing what is current rather than one per platform.

.EXAMPLE
  .\xl1-autoupdate.ps1            check, and update if a newer cli has shipped
  .\xl1-autoupdate.ps1 -Check     report only, change nothing
#>
[CmdletBinding()]
param([switch]$Check)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Manifest = if ($env:XL1_UPDATE_MANIFEST) { $env:XL1_UPDATE_MANIFEST } else { 'https://winlew.co/xl1/latest.json' }

function Log { param($m) Write-Host ("{0} xl1-autoupdate: {1}" -f (Get-Date -Format o), $m) }

# What this node runs now, read from the image rather than from a config file --
# a pinned version someone edited is a claim; the image is the fact.
$installed = ''
try {
  $v = & docker run --rm --entrypoint xl1 xl1:local --version 2>$null | Out-String
  if ($v -match '(\d+\.\d+\.\d+)') { $installed = $Matches[1] }
} catch { }
if (-not $installed) {
  Log 'cannot determine the installed xl1-cli version -- refusing to update blind'
  exit 1
}

# A manifest that cannot be fetched changes nothing. Silence here means
# "unknown", never "up to date": a check that fails quietly and reads as healthy
# is how a node sits unpatched for months.
try {
  $doc = Invoke-RestMethod -Uri $Manifest -TimeoutSec 20 -ErrorAction Stop
} catch {
  Log "could not fetch $Manifest -- leaving $installed alone"
  exit 0
}

$want = [string]$doc.cli
if (-not $want) { Log 'manifest has no cli field -- ignoring it rather than guessing'; exit 0 }

# [version] rather than a string compare, so 5.10.0 beats 5.9.0. A string
# compare has that backwards and would refuse every update after 5.9.
$isNewer = $false
try { $isNewer = ([version]$want -gt [version]$installed) } catch {
  Log "cannot compare '$installed' with '$want' -- doing nothing"; exit 0
}
if (-not $isNewer) {
  Log "xl1-cli $installed is current (published $want) -- nothing to do"
  exit 0
}

$notes = if ($doc.notes) { " ($($doc.notes))" } else { '' }
Log "xl1-cli $installed -> $want available$notes"
if ($Check) { Log '-Check given, stopping here'; exit 0 }

# Keep the outgoing image under a version tag before anything replaces it, the
# same way xl1ctl does on the Pi. Without this there is nothing to go back to.
& docker tag xl1:local "xl1:$installed" 2>$null | Out-Null
Log "kept the running image as xl1:$installed in case this goes badly"

Push-Location $Root
try {
  Log 'git pull'
  & git pull --ff-only 2>&1 | ForEach-Object { Log "  $_" }
  if ($LASTEXITCODE -ne 0) { Log 'git pull failed -- nothing rebuilt, still running ' + $installed; exit 1 }

  Log "building xl1-cli $want"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Build.ps1') -CliVersion $want
  if ($LASTEXITCODE -ne 0) {
    # Build.ps1 verifies the built image reports the version asked for and dies
    # if it does not, so a failure here means the old image is still the one
    # tagged xl1:local and the node is untouched.
    Log "build FAILED -- still running $installed; nothing was restarted"
    exit 1
  }
} finally { Pop-Location }

Log 'restarting the producer and dashboard'
# Hand off to xl1ctl rather than reimplementing its compose invocation here --
# this line previously pointed at a $Root\node.yml that never existed (the
# real file is upstream\compose\node.yml) and skipped the XL1_IMAGE /
# XL1_PRESET_ENV_FILE / XL1_PRODUCER_PRESET(_REST) env vars the compose file
# needs, which is exactly the kind of drift a second copy invites.
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\xl1ctl.ps1') restart 2>&1 |
  ForEach-Object { Log "  $_" }

$now = ''
try {
  $v = & docker run --rm --entrypoint xl1 xl1:local --version 2>$null | Out-String
  if ($v -match '(\d+\.\d+\.\d+)') { $now = $Matches[1] }
} catch { }
Log "updated, now running $(if ($now) { $now } else { 'unknown' })"
Log "if this one misbehaves: docker tag xl1:$installed xl1:local  then restart"
