<#
.SYNOPSIS
  Publish this node's public status to the status repository.

.DESCRIPTION
  Fetches /api/public -- an allow-list projection of the dashboard, so this
  script never has to decide what is safe to publish and cannot get it wrong.
  It copies bytes; the redaction is upstream, in one place, with tests against a
  payload seeded with canary values.

  Writes into one directory of a shared repository, and only that directory, so
  two nodes publishing to the same repo cannot overwrite each other.

    config\publish.env    configuration (see publish.env.template)
    "XL1 Publisher"       scheduled task, runs this every 5 minutes

.EXAMPLE
  .\xl1-publish.ps1            publish now
  .\xl1-publish.ps1 -DryRun    fetch and write locally, push nothing
#>
[CmdletBinding()]
param([switch]$DryRun, [string]$Config)

# Not Stop. A publisher that throws leaves a half-written working copy, and the
# next run inherits it. Every failure below is caught and reported instead.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Root    = Split-Path -Parent $PSScriptRoot
# One script, several destinations. -Config names one directly, which is what a
# scheduled task needs: a task cannot set an environment variable for its own
# action, and quoting a -Command that does is its own small nightmare.
$EnvFile =
  if ($Config)                  { $Config }
  elseif ($env:XL1_PUBLISH_ENV) { $env:XL1_PUBLISH_ENV }
  else                          { Join-Path $Root 'config\publish.env' }

function Import-EnvFile {
  param([string]$Path)
  $map = @{}
  if (-not (Test-Path $Path)) { return $map }
  foreach ($line in Get-Content -Path $Path) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $v = $t.Substring($i + 1).Trim()
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
      $v = $v.Substring(1, $v.Length - 2)
    }
    $map[$t.Substring(0, $i).Trim()] = $v
  }
  return $map
}
# A config file that exists and cannot be read is a different fault from one
# that was never written. Left alone they look identical -- every setting stays
# at its default and the script reports "nothing to publish to" and exits 0,
# which is a silent failure wearing the costume of a healthy no-op.
if ((Test-Path $EnvFile) -and -not (Get-Content -Path $EnvFile -TotalCount 1 -ErrorAction SilentlyContinue)) {
  $probe = $null
  try { $probe = Get-Content -Path $EnvFile -TotalCount 1 -ErrorAction Stop } catch {
    Write-Warning "xl1-publish: $EnvFile exists but cannot be read -- $($_.Exception.Message)"
    exit 1
  }
}
$cfg = Import-EnvFile $EnvFile

# Setting falls back to the default when a value is empty, because an env line
# reading FOO= is almost always somebody leaving a field blank rather than
# choosing "". For a few variables empty IS the choice -- server.mjs carries the
# same note about DASH_TOKEN -- and the page path is one of them: empty means
# "this destination already owns its pages, do not write one".
#
# Without the distinction it fell back to the default, and the node wrote a
# second copy of the producer page into the data directory, where nothing
# served it and it would have gone quietly stale beside live data.
function SettingOptional { param([string]$Name, $Default = '')
  $e = [Environment]::GetEnvironmentVariable($Name)
  if ($e) { return $e }
  if ($cfg.ContainsKey($Name)) { return $cfg[$Name] }
  return $Default
}

function Setting { param([string]$Name, $Default = '')
  $e = [Environment]::GetEnvironmentVariable($Name)
  if ($e) { return $e }
  if ($cfg.ContainsKey($Name) -and $cfg[$Name] -ne '') { return $cfg[$Name] }
  return $Default
}

$Url     = Setting 'XL1_PUBLISH_URL' 'http://127.0.0.1:8088/api/public'
$Token   = Setting 'XL1_PUBLISH_TOKEN' ''
$Repo    = Setting 'XL1_PUBLISH_REPO' ''
$Branch  = Setting 'XL1_PUBLISH_BRANCH' 'main'
$SubPath = Setting 'XL1_PUBLISH_PATH' 'xl1/windows'
$WorkDir = Setting 'XL1_PUBLISH_WORKDIR' (Join-Path $Root 'state\publish')
# The file this node writes. One repository can hold several nodes' data when
# each writes its own name -- which is what lets the site own every page while
# the nodes own only what they measure.
$DataFile = Setting 'XL1_PUBLISH_FILE' 'status.json'
# The page to publish beside it. Empty means the destination already has its own
# page and this node has no business overwriting it.
$PagePath = SettingOptional 'XL1_PUBLISH_PAGE' (Join-Path $Root 'dashboard\public.html')
$Name    = Setting 'XL1_PUBLISH_GIT_NAME' 'xl1-publisher'
$Email   = Setting 'XL1_PUBLISH_GIT_EMAIL' 'xl1-publisher@users.noreply.github.com'

# Optional: a URL that accepts the status document directly -- object storage, a
# Worker, anything that takes an HTTP PUT. Git ships the PAGE well, because a
# page is reviewed and versioned and changes rarely. It ships the DATA badly:
# every publish becomes a commit, a build and a CDN propagation, and the number
# on screen is minutes behind the node that produced it. When this is set the
# data goes straight there and the page reads it live.
$LiveUrl    = Setting 'XL1_PUBLISH_LIVE_URL' ''
$LiveAuth   = Setting 'XL1_PUBLISH_LIVE_AUTH' ''
$LiveMethod = Setting 'XL1_PUBLISH_LIVE_METHOD' 'PUT'

try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Log { param([string]$m)
  Write-Output $m
  try {
    $f = Join-Path $Root 'state\.publish-log'
    Add-Content -Path $f -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $m)
    $lines = @(Get-Content -Path $f -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 300) { Set-Content -Path $f -Value $lines[-300..-1] }
  } catch {}
}

if (-not $Repo -and -not $DryRun) {
  Log 'XL1_PUBLISH_REPO is empty -- nothing to publish to. See config\publish.env.template.'
  exit 0
}

# ------------------------------------------------------------------ fetch
$fetchUrl = if ($Token) { "$Url`?token=$Token" } else { $Url }
$json = $null
try { $json = Invoke-WebRequest -Uri $fetchUrl -TimeoutSec 20 -UseBasicParsing }
catch { Log "could not read $Url -- $($_.Exception.Message)"; exit 1 }

$text = $json.Content
# Parsed before it is written, so a truncated or error response is never
# published over a good one. A stale page is recoverable; a corrupt one is the
# page telling everybody the node is broken when it is not.
try {
  $doc = $text | ConvertFrom-Json
  if (-not $doc.schema) { throw 'no schema field -- is this /api/public?' }
} catch { Log "refused to publish: $($_.Exception.Message)"; exit 1 }

# ------------------------------------------------------------------ working copy
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
$gitDir = Join-Path $WorkDir '.git'
Push-Location $WorkDir
try {
  if (-not (Test-Path $gitDir)) {
    # Shallow and single-branch: this repository is a delivery mechanism, and
    # its history is of no use on a producer.
    & git clone --quiet --depth 1 --branch $Branch --single-branch $Repo . 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { Log "clone of $Repo failed"; exit 1 }
  }
  & git config user.name $Name | Out-Null
  & git config user.email $Email | Out-Null

  $dest = Join-Path $WorkDir $SubPath
  if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }

  # UTF-8 without BOM. PowerShell's -Encoding utf8 means "with BOM" on 5.1, and
  # a BOM makes the document unparseable to JSON.parse in the browser -- the
  # same trap the collector and the alerter each carry a note about.
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText((Join-Path $dest $DataFile), $text, $enc)

  # The page travels with the data so a page fix reaches the site on the next
  # publish, rather than needing somebody to remember to copy it.
  $page = $PagePath
  if ($page -and (Test-Path $page)) {
    $html = [System.IO.File]::ReadAllText($page)
    # Point the page at the live endpoint, if there is one. A literal swap of one
    # line, so the page in the repository stays the readable default and nothing
    # has to be templated.
    if ($LiveUrl) { $html = $html.Replace("const DATA_URL = 'status.json'", "const DATA_URL = '$LiveUrl'") }
    [System.IO.File]::WriteAllText((Join-Path $dest 'index.html'), $html, (New-Object System.Text.UTF8Encoding($false)))
  }

  # Straight to the live endpoint, before the git push: this is the copy people
  # actually read, and it should not wait on a commit.
  if ($LiveUrl -and -not $DryRun) {
    try {
      $headers = @{ 'content-type' = 'application/json' }
      if ($LiveAuth) { $headers['authorization'] = $LiveAuth }
      Invoke-WebRequest -Uri $LiveUrl -Method $LiveMethod -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($text)) -TimeoutSec 20 -UseBasicParsing | Out-Null
      Log 'live endpoint updated'
    } catch {
      # Never fatal. The git copy below is the fallback, and a page that is a few
      # minutes stale beats a publisher that gave up.
      Log "live endpoint failed -- $($_.Exception.Message)"
    }
  }

  if ($DryRun) { Log "dry run: wrote $dest (nothing pushed)"; exit 0 }

  & git add -- $SubPath 2>&1 | Out-Null
  & git diff --cached --quiet 2>&1 | Out-Null
  if ($LASTEXITCODE -eq 0) { Log 'no change since the last publish'; exit 0 }

  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z'
  # The node's own name for itself, taken from the payload rather than from
  # configuration -- a history of "." tells a reader nothing about which machine
  # wrote it, and the path is "." whenever a repo holds a single node.
  $who = if ($doc.label) { $doc.label } elseif ($SubPath -ne '.') { $SubPath } else { 'status' }
  & git commit --quiet -m "$who at $stamp" 2>&1 | Out-Null

  # Two nodes push to one repository. Each writes only its own directory, so a
  # rebase can never conflict -- but it can still be rejected for being behind,
  # which is what this retries.
  $pushed = $false
  foreach ($attempt in 1..3) {
    & git push --quiet origin $Branch 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { $pushed = $true; break }
    & git fetch --quiet origin $Branch 2>&1 | Out-Null
    & git rebase --quiet "origin/$Branch" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
      & git rebase --abort 2>&1 | Out-Null
      Log 'rebase failed -- leaving the working copy alone for the next run'
      exit 1
    }
  }
  if ($pushed) { Log "published $who" } else { Log 'push rejected three times -- giving up until the next run'; exit 1 }
}
finally { Pop-Location }
