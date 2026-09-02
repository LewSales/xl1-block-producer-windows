<#
.SYNOPSIS
  Build the amd64 images this bundle runs. Windows-native.

.DESCRIPTION
  No WSL and no bash. The only compile step that needs Node runs inside a
  container, so Docker Desktop is the sole prerequisite.

  Two images:
    xl1:local            the producer, from XYO's own Dockerfile in upstream/
    xl1-dashboard:local  the dashboard, from the shared source in this project

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Build.ps1
  powershell -ExecutionPolicy Bypass -File .\Build.ps1 -CliVersion 5.3.1
#>
[CmdletBinding()]
param(
  [string]$CliVersion  = '5.3.1',
  [string]$NodeVersion = '24.14.1',
  [switch]$ProducerOnly,
  [switch]$DashboardOnly
)

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$Upstream = Join-Path $Root 'upstream'
$Dash     = Join-Path $Root 'dashboard'

function Say  { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }
function Head { param($m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Die  { param($m) Write-Host ''; Write-Host "error: $m" -ForegroundColor Red; exit 1 }

& docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Docker Desktop is not running.' }

# Everything here targets the machine it runs on. Stated explicitly because the
# sibling Pi bundle cross-builds arm64, and the two are easy to confuse.
$Platform = 'linux/amd64'

if (-not $DashboardOnly) {
  Head "Producer image (xl1-cli $CliVersion, $Platform)"
  if (-not (Test-Path (Join-Path $Upstream 'docker\Dockerfile'))) {
    Die "upstream\ is missing. Run Setup.ps1 first -- it clones xl1-docker-images."
  }

  # Their Dockerfile COPYs dist/node, which is produced by a pnpm compile. Doing
  # that in a container keeps Node and pnpm off the Windows side entirely.
  if (-not (Test-Path (Join-Path $Upstream 'dist\node\entrypoint.mjs'))) {
    Say 'compiling the entrypoint (in a container -- no Node needed on Windows)'
    $img = 'node:' + $NodeVersion + '-bookworm-slim'
    $cmd = 'corepack enable && pnpm install --frozen-lockfile --prefer-offline && pnpm xy compile'
    & docker run --rm -v "${Upstream}:/w" -w /w $img sh -lc $cmd
    if ($LASTEXITCODE -ne 0) { Die 'entrypoint compile failed' }
  }
  else { Say 'entrypoint already compiled' }

  $dockerfile = Join-Path $Upstream 'docker\Dockerfile'
  $buildArgs = @(
    'build', '--platform', $Platform, '-f', $dockerfile,
    '--build-arg', ('NODE_VERSION=' + $NodeVersion),
    '--build-arg', ('XL1_CLI_VERSION=' + $CliVersion),
    '-t', 'xl1:local', $Upstream
  )
  & docker @buildArgs
  if ($LASTEXITCODE -ne 0) { Die 'producer image build failed' }

  # The image states its own version. Anything else is a claim about what was
  # built; this is the build answering for itself.
  $v = (& docker run --rm --platform $Platform --entrypoint xl1 xl1:local --version 2>&1 | Out-String)
  if ($v -notmatch [regex]::Escape($CliVersion)) {
    Die "asked for xl1-cli $CliVersion but the image reports: $($v.Trim())"
  }
  Say "xl1 $CliVersion verified in-image" 'Green'
}

if (-not $ProducerOnly) {
  Head "Dashboard image ($Platform)"
  if (-not (Test-Path (Join-Path $Dash 'server.mjs'))) {
    Die "dashboard\ is missing. Run Setup.ps1 -- it fetches the shared dashboard source."
  }
  # Stamp the build so the running page can identify itself. --dirty matters:
  # a dashboard built from uncommitted edits must not claim to be the commit it
  # was branched from, or a deploy that shipped something else looks identical
  # to one that did not.
  # Bare short sha, not `git describe`: describe prefers the nearest tag and
  # yields something GitHub cannot resolve as a commit, breaking the dashboard's
  # own "read the code" link the moment a release is tagged.
  #
  # PowerShell 5.1 turns anything a native command writes to stderr into a
  # terminating error while ErrorActionPreference is Stop, and git writes its
  # line-ending advice there -- which aborted a build over a warning about
  # .gitignore. The exit code is what these two calls are read for anyway.
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $commit = (git -C $Root rev-parse --short=8 HEAD 2>$null)
  if ($commit) { git -C $Root diff --quiet 2>$null; if ($LASTEXITCODE -ne 0) { $commit = "$commit-dirty" } }
  $ErrorActionPreference = $eap
  if (-not $commit) { $commit = 'unknown' }
  $builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  & docker build --platform $Platform --build-arg "DASH_COMMIT=$commit" --build-arg "DASH_BUILT_AT=$builtAt" -t xl1-dashboard:local $Dash
  if ($LASTEXITCODE -ne 0) { Die 'dashboard image build failed' }

  # A 100 MB image that throws on startup is caught here or by an operator.
  Say 'smoke testing'
  $id = (& docker run -d --rm --platform $Platform -p 127.0.0.1:18088:8088 xl1-dashboard:local 2>$null)
  $ok = $false
  foreach ($i in 1..30) {
    Start-Sleep -Seconds 1
    try { $null = Invoke-WebRequest -Uri 'http://127.0.0.1:18088/healthz' -TimeoutSec 2 -UseBasicParsing; $ok = $true; break }
    catch { }
  }
  if ($id) { & docker rm -f $id 2>&1 | Out-Null }
  if (-not $ok) { Die 'the dashboard image did not answer /healthz' }
  Say 'dashboard answers /healthz' 'Green'
}

Head 'Done'
& docker images --format '  {{.Repository}}:{{.Tag}}  {{.Size}}' |
  Where-Object { $_ -match 'xl1' -and $_ -match ':local\s' }
Write-Host ''
