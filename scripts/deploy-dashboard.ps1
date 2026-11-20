# Recreate ONLY the dashboard container, under an alert hold.
#
#   .\Build.ps1 -DashboardOnly
#   .\scripts\deploy-dashboard.ps1
#
# The recreate takes the dashboard offline for a few seconds, which the alerter
# reports as dashboard-unreachable. This holds that one key first, and refuses
# to touch the container if the hold cannot be set and read back. On 2026-10-11
# a dashboard deploy went ahead after its hold failed, and the operator was paged
# for a planned restart. -NoHold is the explicit opt-out, for a host without the
# alerter. The producers are never touched: --no-deps, one service.
param(
  [int]$HoldMinutes = 15,
  [switch]$NoHold
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Alert = Join-Path $PSScriptRoot 'xl1-alert.ps1'
$HoldKey = 'dashboard-unreachable'
$Api = 'http://127.0.0.1:8088/api/status'

function Say { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }
function Die { param($m) Write-Host "  x $m" -ForegroundColor Red; exit 1 }

# Same compose files as xl1ctl: forgetting the tailnet override would quietly
# unpublish the second binding.
$DashCompose = Join-Path $Root 'dashboard.yml'
$DashTailnet = Join-Path $Root 'compose\dashboard-tailnet.yml'
$DotEnv = Join-Path $Root '.env'
$DashFiles = @('-f', $DashCompose)
if ((Test-Path $DashTailnet) -and (Test-Path $DotEnv) -and
    (Select-String -Path $DotEnv -Pattern '^\s*DASH_PUBLISH_HOST\s*=\s*\S' -Quiet)) {
  $DashFiles += @('-f', $DashTailnet)
}

# The version the new image carries, to check the container really runs it.
$want = (& docker run --rm --entrypoint node xl1-dashboard:local -e "process.stdout.write(require('/app/package.json').version)" 2>$null)
if (-not $want) { Die 'cannot read the version from xl1-dashboard:local -- build it first (.\Build.ps1 -DashboardOnly)' }
Write-Host ''
Write-Host "deploying dashboard $want" -ForegroundColor White

$held = $false
if ($NoHold) {
  Say '! -NoHold: recreating without an alert hold' 'Yellow'
} else {
  $out = (& powershell -NoProfile -ExecutionPolicy Bypass -File $Alert -Hold $HoldKey -Minutes $HoldMinutes -Reason "dashboard $want deploy" 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) { Die "could not set the $HoldKey alert hold -- refusing to deploy. $($out.Trim())" }
  $holds = (& powershell -NoProfile -ExecutionPolicy Bypass -File $Alert -Holds 2>&1 | Out-String)
  if ($holds -notmatch "(?m)^$HoldKey`t") { Die "the $HoldKey hold did not read back -- refusing to deploy" }
  $held = $true
  Say "ok alert hold set ($HoldKey, $HoldMinutes min)" 'Green'
}

# Docker writes progress to stderr; read the exit code, not the stream.
$ErrorActionPreference = 'Continue'
& docker compose @DashFiles up -d --force-recreate --no-deps dashboard 2>&1 | Out-Null
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { Die "docker compose failed (exit $code); the hold is left to expire so a dashboard left down still pages" }

$serving = $null
foreach ($i in 1..30) {
  Start-Sleep -Seconds 2
  try { $serving = (Invoke-RestMethod -Uri $Api -TimeoutSec 5).build.version; if ($serving) { break } } catch { }
}
if ($serving -ne $want) { Die "serving '$serving', expected '$want'; the hold is left to expire" }
Say "ok serving $serving" 'Green'

# Held keys are not observed, so releasing now cannot produce a "recovered"
# message for a restart the alerter never saw.
if ($held) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $Alert -Release -Key $HoldKey 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Say 'ok alert hold released' 'Green' } else { Say "! could not release the hold; it expires within $HoldMinutes min" 'Yellow' }
}
Write-Host ''
