<#
.SYNOPSIS
  Run every check in this bundle. Windows equivalent of the Pi's tests/run.sh.

.DESCRIPTION
  Nothing here needs Docker, a producer, or the network. The dashboard's SDK is
  stubbed when it is not installed: server.mjs imports it at load time, but none
  of the decisions under test touch it, and requiring a 100 MB install to test a
  version comparison makes a suite people skip.

  dashboard/ is shared source with the Pi bundle, so tests/dashboard.test.mjs is
  the same file there. Keep it that way -- a divergence here is how the two
  copies quietly stop being the same dashboard.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
$script:Failed = 0

function Step { param($m) Write-Host "`n==> $m" -ForegroundColor White }
function Ok   { param($m) Write-Host "  [ok] $m" -ForegroundColor Green }
function Bad  { param($m) Write-Host "  [!!] $m" -ForegroundColor Red; $script:Failed++ }
function Skip { param($m) Write-Host "  $m" -ForegroundColor DarkGray }

# ------------------------------------------------------------ PowerShell parse
#
# The parser, not execution. Every one of these scripts talks to Docker or the
# scheduler, so running them is not a test -- but a syntax error in the
# collector only shows up as a status file that silently stops updating.
Step 'PowerShell syntax'
foreach ($f in @(
  (Join-Path $Root 'Setup.ps1'),
  (Join-Path $Root 'Build.ps1'),
  (Join-Path $Root 'Tests.ps1'),
  (Join-Path $Root 'scripts\xl1ctl.ps1'),
  (Join-Path $Root 'scripts\xl1-collect.ps1'),
  (Join-Path $Root 'scripts\xl1-alert.ps1'),
  (Join-Path $Root 'tests\alert.test.ps1')
)) {
  if (-not (Test-Path $f)) { Bad "$(Split-Path -Leaf $f) -- missing"; continue }
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errors) | Out-Null
  if ($errors.Count) { Bad "$(Split-Path -Leaf $f) -- $($errors[0].Message)" }
  else { Ok (Split-Path -Leaf $f) }
}

# ------------------------------------------------------------------ JavaScript
$node = Get-Command node -ErrorAction SilentlyContinue

Step 'JavaScript syntax'
if (-not $node) {
  Skip 'node not on PATH; JavaScript checks skipped'
} else {
  foreach ($f in @(
    (Join-Path $Root 'dashboard\server.mjs'),
    (Join-Path $Root 'tests\dashboard.test.mjs')
  )) {
    & node --check $f 2>$null
    if ($LASTEXITCODE -eq 0) { Ok (Split-Path -Leaf $f) } else { Bad "$(Split-Path -Leaf $f) -- syntax error" }
  }

  # The panel is one inline script. A syntax error there is a blank page with
  # the message only in a console nobody has open.
  foreach ($page in @('index.html', 'public.html')) {
    $path = Join-Path $Root "dashboard\$page"
    if (-not (Test-Path $path)) { Bad "$page -- missing"; continue }
    $html = (Get-Content $path -Raw)
    $m = [regex]::Match($html, '(?s)<script>(.*)</script>')
    if ($m.Success) {
      $tmp = Join-Path $env:TEMP "xl1-panel-$PID.mjs"
      Set-Content -Path $tmp -Value $m.Groups[1].Value -Encoding UTF8
      & node --check $tmp 2>$null
      if ($LASTEXITCODE -eq 0) { Ok "$page inline script parses" } else { Bad "$page inline script does not parse" }
      Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    } else { Bad "$page has no inline script" }
  }
}

# ------------------------------------------------------------ compose wiring
#
# The dashboard keeps everything it knows in the bind-mounted state directory:
# the collector's snapshot, the standings tally, thirty days of trend, and the
# alerter's state. A compose file that has lost that mount still starts, still
# passes a health check, and still serves a page -- one that has silently
# forgotten every number on it and begins re-scanning the chain from nothing.
#
# That is exactly what an edit to the ports block did here once, by replacing
# the lines between `ports:` and `extra_hosts:` -- which is where `volumes:`
# happened to live. It reached a commit. This is the guard.
Step 'Compose wiring'
$dashYml = Join-Path $Root 'dashboard.yml'
if (-not (Test-Path $dashYml)) { Bad 'dashboard.yml -- missing' }
else {
  $yml = Get-Content $dashYml -Raw
  foreach ($needle in @(
    @{ pattern = './state:/var/lib/xl1'; what = 'the state directory is bind-mounted' },
    @{ pattern = '127.0.0.1:8088:8088';  what = 'the dashboard is published on loopback' }
  )) {
    if ($yml -match [regex]::Escape($needle.pattern)) { Ok $needle.what }
    else { Bad "dashboard.yml -- $($needle.what) is gone" }
  }
}

# ----------------------------------------------------------------- attribution
#
# Someone shown a screenshot of this should not come away thinking XYO shipped
# it. Asserted so a refactor cannot quietly drop the disclaimer.
Step 'Attribution'
foreach ($pair in @(
  @{ file = 'dashboard\index.html'; needle = 'not affiliated with' },
  @{ file = 'README.md';            needle = 'Not affiliated with' }
)) {
  $path = Join-Path $Root $pair.file
  if (Select-String -Path $path -Pattern $pair.needle -SimpleMatch -Quiet) {
    Ok "$($pair.file) states it is unofficial"
  } else {
    Bad "$($pair.file) no longer says it is unaffiliated with XYO"
  }
}

# ------------------------------------------------------------ alert behaviour
#
# The alerter is the one part of this bundle that is supposed to speak when
# nobody is watching, so the cases that matter are the ones where it stayed
# quiet: conditions live and nothing reported, and recoveries announced for
# conditions it could not see. Served over a loopback socket, so the fetch path
# under test is the one the scheduled task uses.
Step 'Alert behaviour'
$alertTest = Join-Path $Root 'tests\alert.test.ps1'
if (-not (Test-Path $alertTest)) { Bad 'tests\alert.test.ps1 -- missing' }
else {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $alertTest
  if ($LASTEXITCODE -eq 0) { Ok 'alert tests passed' } else { Bad 'alert tests failed' }
}

# ---------------------------------------------------------- dashboard behaviour
Step 'Dashboard behaviour'
if (-not $node) {
  Skip 'node not on PATH; dashboard tests skipped'
} else {
  $sdk = Join-Path $Root 'dashboard\node_modules\@xyo-network\xl1-sdk'
  $stubbed = $false
  if (-not (Test-Path $sdk)) {
    New-Item -ItemType Directory -Path $sdk -Force | Out-Null
    Copy-Item (Join-Path $Root 'tests\stubs\xl1-sdk-stub.mjs') (Join-Path $sdk 'index.mjs') -Force
    Set-Content -Path (Join-Path $sdk 'package.json') -Encoding UTF8 `
      -Value '{"name":"@xyo-network/xl1-sdk","version":"0.0.0-stub","type":"module","main":"index.mjs","exports":"./index.mjs"}'
    $stubbed = $true
    Skip 'using a stubbed SDK (real one not installed)'
  }

  try {
    & node --test (Join-Path $Root 'tests\dashboard.test.mjs')
    if ($LASTEXITCODE -eq 0) { Ok 'dashboard tests passed' } else { Bad 'dashboard tests failed' }
  } finally {
    # Only what this script created. A real install is the operator's.
    if ($stubbed) { Remove-Item (Join-Path $Root 'dashboard\node_modules') -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

Write-Host ''
if ($script:Failed) {
  Write-Host "$($script:Failed) check(s) failed`n" -ForegroundColor Red
  exit 1
}
Write-Host "everything passed`n" -ForegroundColor Green
