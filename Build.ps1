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
  powershell -ExecutionPolicy Bypass -File .\Build.ps1 -CliVersion 5.3.1   # pin an older one
#>
[CmdletBinding()]
param(
  [string]$CliVersion  = '5.3.2',
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

# Keep the newest few tagged versions, plus whatever is running and whatever
# rollback points at, so repeated builds cannot fill Docker Desktop's disk with
# every version ever built. Removing a tag never removes an image still tagged
# something else, so this cannot delete xl1:local out from under the producer.
function Invoke-VersionPrune {
  param([string]$KeepA, [string]$KeepB, [int]$Keep = 3)
  # A prune is cleanup, not a build step -- it must never abort the script it
  # runs at the end of. `docker rmi` on an image still referenced elsewhere (a
  # stray extra tag, a stopped container) writes to stderr, which is a
  # terminating error while EAP is Stop; flipped the same way Get-ImageVersion
  # in xl1ctl.ps1 does, for the same reason.
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $versions = @(& docker images xl1 --format '{{.Tag}}' 2>$null |
      Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Descending)
    for ($i = $Keep; $i -lt $versions.Count; $i++) {
      $v = $versions[$i]
      if ($v -eq $KeepA -or $v -eq $KeepB) { continue }
      & docker rmi "xl1:$v" 2>$null | Out-Null
    }
  } finally { $ErrorActionPreference = $eap }
}

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
    # COREPACK_ENABLE_DOWNLOAD_PROMPT=0: corepack asks before fetching pnpm, and
    # with no TTY on stdin that question is never answered -- the container sits
    # there forever, which reads as a slow network rather than as a hang.
    # The pnpm store lives in a named volume rather than in the container, so a
    # compile that dies half way through the download -- which on a slow link is
    # most of them -- resumes from what it already has instead of fetching
    # upstream's entire dev tree again.
    & docker run --rm -e COREPACK_ENABLE_DOWNLOAD_PROMPT=0 -e PNPM_HOME=/pnpm -e npm_config_store_dir=/pnpm/store `
      -v xl1-pnpm-store:/pnpm -v "${Upstream}:/w" -w /w $img sh -lc $cmd
    if ($LASTEXITCODE -ne 0) { Die 'entrypoint compile failed' }
  }
  else { Say 'entrypoint already compiled' }

  # Name the outgoing image before the build below overwrites xl1:local --
  # xl1-autoupdate.ps1 already does this before calling here, but a manual run
  # (this docstring's own example: -CliVersion 5.3.1) did not, so a bad build
  # left no way back except redownloading or rebuilding the old version from
  # scratch, over the network, with the node already down.
  # On the very first build ever, xl1:local does not exist -- docker run then
  # tries to pull it as a registry image, fails, and writes to stderr, which is
  # a terminating error while EAP is Stop (script-level, above). None of that
  # is a fault here; it just means there is nothing yet to keep.
  $prevVersion = $null
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $prevCheck = (& docker run --rm --platform $Platform --entrypoint xl1 xl1:local --version 2>$null | Out-String)
    if ($LASTEXITCODE -eq 0 -and $prevCheck -match '(\d+\.\d+\.\d+)') {
      $prevVersion = $Matches[1]
      & docker tag xl1:local "xl1:$prevVersion" 2>$null | Out-Null
    }
  } finally { $ErrorActionPreference = $eap }
  if ($prevVersion) {
    Say "kept the running image as xl1:$prevVersion in case this build goes badly" 'Yellow'
  }

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

  # Tag what just landed too, so it is itself a fallback for the next build,
  # and xl1ctl versions/rollback have something to see.
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & docker tag xl1:local "xl1:$CliVersion" 2>$null | Out-Null } finally { $ErrorActionPreference = $eap }

  # Only record a target when the build actually changed something -- re-running
  # Build.ps1 at the version already installed must not leave rollback pointing
  # at itself, or the recovery path becomes a no-op at the worst moment.
  if ($prevVersion -and $prevVersion -ne $CliVersion) {
    $rollbackFile = Join-Path $Root 'state\rollback'
    New-Item -ItemType Directory -Force -Path (Split-Path $rollbackFile) | Out-Null
    Set-Content -Path $rollbackFile -Value $prevVersion -NoNewline
    Say "if this build misbehaves: .\scripts\xl1ctl.ps1 rollback (back to $prevVersion)" 'Yellow'
  }

  Invoke-VersionPrune -KeepA $CliVersion -KeepB $prevVersion
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
