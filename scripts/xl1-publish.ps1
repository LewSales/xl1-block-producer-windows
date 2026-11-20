<#
.SYNOPSIS
  Publish this node's public status to the status repository.

.DESCRIPTION
  Fetches /api/public -- an allow-list projection of the dashboard, so this
  script never has to decide what is safe to publish and cannot get it wrong.
  It copies bytes; the redaction is upstream, in one place, with tests against a
  payload seeded with canary values.

  Writes one file of a shared repository and stages only that file, so several
  publishers sharing the repo cannot overwrite each other. Each run fetches,
  builds its one commit on the branch tip and pushes without force; git errors
  are kept, scrubbed, in the log; persistent failure escalates once.

    config\publish.env    configuration (see publish.env.template)
    "XL1 Publisher"       scheduled task, runs this every 5 minutes

.EXAMPLE
  .\xl1-publish.ps1            publish now
  .\xl1-publish.ps1 -DryRun    fetch and write locally, push nothing
  .\xl1-publish.ps1 -Status    last success, consecutive failures, last error
#>
[CmdletBinding()]
param([switch]$DryRun, [switch]$Status, [string]$Config)

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
# A PAT scoped to just this repo, used only for git itself (clone/fetch/push).
# Task Scheduler's process has no console for Git Credential Manager to prompt
# from and, run elevated, cannot even persist a credential to wincredman to
# reuse next time -- it fails outright, every run, forever. Embedding this in
# the remote URL bypasses the credential helper for this remote entirely.
$GitToken = Setting 'XL1_PUBLISH_GIT_TOKEN' ''
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

# Never let git fall back to an interactive prompt it cannot show -- fail fast
# with a clear error in the log instead of hanging until the task's time limit
# kills it.
$env:GIT_TERMINAL_PROMPT = '0'

# Insert the PAT into the URL so git authenticates without touching any
# credential helper. Left alone (no token configured) when $Repo is not
# https, so an ssh:// remote using its own key keeps working unchanged.
function AuthenticatedRepoUrl { param([string]$RepoUrl, [string]$GitToken)
  if (-not $GitToken -or $RepoUrl -notmatch '^https://') { return $RepoUrl }
  return $RepoUrl -replace '^https://', "https://$GitToken@"
}

# Bound every git step: a hung fetch or push must end this run, not hold the
# next one off.
$GitTimeoutSec   = [int](Setting 'XL1_PUBLISH_GIT_TIMEOUT' '60')
# Consecutive failed runs before the log gets an ERROR line, and how many more
# before it is repeated (72 runs at 5 minutes is six hours).
$EscalateAfter   = [int](Setting 'XL1_PUBLISH_ESCALATE_AFTER' '3')
$EscalateEvery   = [int](Setting 'XL1_PUBLISH_ESCALATE_EVERY' '72')
$PushAttempts    = [int](Setting 'XL1_PUBLISH_PUSH_ATTEMPTS' '8')

# Several publishers share one log; each line says which file it is about.
function Log { param([string]$m, [string]$level = '')
  $line = if ($level) { "[$DataFile] ${level}: $m" } else { "[$DataFile] $m" }
  # Not Write-Output: this is called inside functions whose return values are
  # read, and pipeline output would be returned along with them.
  [Console]::Out.WriteLine($line)
  try {
    $f = Join-Path $Root 'state\.publish-log'
    Add-Content -Path $f -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $line)
    $lines = @(Get-Content -Path $f -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 300) { Set-Content -Path $f -Value $lines[-300..-1] }
  } catch {}
}

# Anything git says goes to the log, so it must never carry a credential: the
# configured token, userinfo in a URL, a GitHub token, or a key=value secret.
function Scrub { param([string]$s)
  if (-not $s) { return '' }
  if ($GitToken) { $s = $s.Replace($GitToken, '<redacted>') }
  $s = $s -replace '([a-zA-Z][a-zA-Z0-9+.-]*://)[^/@\s]+@', '$1<redacted>@'
  $s = $s -replace '(gh[pousr]_|github_pat_)[A-Za-z0-9_]+', '<redacted>'
  $s = $s -replace '(?i)((token|password|passwd|secret|authorization|auth)\s*[=:]\s*)\S+', '$1<redacted>'
  $s = ($s -replace '\s+', ' ').Trim()
  if ($s.Length -gt 600) { $s = $s.Substring(0, 600) }
  return $s
}

function Quote-Arg { param([string]$a)
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  return '"' + (($a -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"'
}

# Run git with its output kept and its stderr (scrubbed, bounded) in
# $script:GitErr. Until 2026-10-12 every git error here went to Out-Null.
$script:GitOut = ''; $script:GitErr = ''
function G {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'git'
  $psi.Arguments = (@($args | ForEach-Object { Quote-Arg ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $psi.WorkingDirectory = (Get-Location).Path
  $p = [System.Diagnostics.Process]::Start($psi)
  $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($GitTimeoutSec * 1000)) {
    try { $p.Kill() } catch {}
    $script:GitOut = ''; $script:GitErr = "timed out after ${GitTimeoutSec}s"
    return 124
  }
  $p.WaitForExit()
  $script:GitOut = $o.Result
  $script:GitErr = Scrub $e.Result
  return $p.ExitCode
}

# ------------------------------------------------------------- run state
# Beside the working copy, never inside what gets committed.
$StateFile = Join-Path $WorkDir '.git\xl1-publish.state'
function Read-State {
  $h = @{}
  if (Test-Path $StateFile) {
    foreach ($l in Get-Content -Path $StateFile -ErrorAction SilentlyContinue) {
      $i = $l.IndexOf('='); if ($i -gt 0) { $h[$l.Substring(0, $i)] = $l.Substring($i + 1) }
    }
  }
  return $h
}
function Write-State { param($h)
  if (-not (Test-Path (Join-Path $WorkDir '.git'))) { return }
  $text = (@($h.Keys | Sort-Object | ForEach-Object { "$_=$($h[$_])" }) -join "`n") + "`n"
  try {
    [System.IO.File]::WriteAllText("$StateFile.tmp", $text, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -Path "$StateFile.tmp" -Destination $StateFile -Force
  } catch {}
}
function NowIso { (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }

if ($Status) {
  if (Test-Path $StateFile) { Get-Content -Path $StateFile } else { "no state recorded yet ($StateFile)" }
  exit 0
}

# A failed run: logged every time as WARN, escalated to ERROR once failures
# persist, repeated only rarely after that.
function Fail { param([string]$msg)
  $s = Read-State
  $n = 1 + [int]("0" + $s['failures'])
  if (-not $s['failingSince']) { $s['failingSince'] = NowIso }
  $s['failures'] = $n; $s['lastError'] = $msg; $s['lastAttempt'] = NowIso
  Write-State $s
  Log $msg 'WARN'
  if ($n -eq $EscalateAfter -or ($n -gt $EscalateAfter -and (($n - $EscalateAfter) % $EscalateEvery) -eq 0)) {
    Log "publishing $DataFile has failed $n runs in a row since $($s['failingSince']); last error: $msg" 'ERROR'
  }
  exit 1
}
function Succeed { param([string]$msg)
  $s = Read-State
  $n = [int]("0" + $s['failures'])
  if ($n -gt 0) { Log "publishing $DataFile recovered after $n failed run(s) since $($s['failingSince'])" 'NOTICE' }
  $s['failures'] = 0; $s['failingSince'] = ''; $s['lastSuccess'] = NowIso; $s['lastAttempt'] = NowIso
  Write-State $s
  Log $msg
  exit 0
}

# ------------------------------------------------------------- one at a time
# A scheduled run and a hand-run in one working copy is how a half-finished
# checkout gets committed. Keyed by working copy, so the site, race and other
# publishers never wait on each other.
$sha = [System.Security.Cryptography.SHA1]::Create()
$key = (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($WorkDir.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
$script:Mutex = $null
foreach ($ns in 'Global', 'Local') {
  try { $script:Mutex = New-Object System.Threading.Mutex($false, "$ns\xl1-publish-$key"); break } catch {}
}
if ($script:Mutex) {
  $got = $false
  try { $got = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
  if (-not $got) { Log "another publish is still running in $WorkDir -- skipping this run"; exit 0 }
}

if (-not $Repo -and -not $DryRun) {
  Log 'XL1_PUBLISH_REPO is empty -- nothing to publish to. See config\publish.env.template.'
  exit 0
}
$haveRepo = Test-Path (Join-Path $WorkDir '.git')

# ------------------------------------------------------------------ fetch
$fetchUrl = if ($Token) { "$Url`?token=$Token" } else { $Url }
$json = $null
try { $json = Invoke-WebRequest -Uri $fetchUrl -TimeoutSec 20 -UseBasicParsing }
catch { if ($haveRepo) { Fail "could not read $Url -- $($_.Exception.Message)" }; Log "could not read $Url -- $($_.Exception.Message)"; exit 1 }

$text = $json.Content
if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
# Parsed before it is written, so a truncated or error response is never
# published over a good one. A stale page is recoverable; a corrupt one is the
# page telling everybody the node is broken when it is not.
try {
  $doc = $text | ConvertFrom-Json
  if (-not $doc.schema) { throw 'no schema field -- is this /api/public?' }
} catch { if ($haveRepo) { Fail "refused to publish: $($_.Exception.Message)" }; Log "refused to publish: $($_.Exception.Message)"; exit 1 }

# ------------------------------------------------------------------ working copy
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
Push-Location $WorkDir
try {
  $authRepo = AuthenticatedRepoUrl $Repo $GitToken
  if (-not $haveRepo) {
    # Shallow and single-branch: this repository is a delivery mechanism, and
    # its history is of no use on a producer.
    if ((G clone --quiet --depth 1 --branch $Branch --single-branch $authRepo .) -ne 0) { Log "clone of $Repo failed: $script:GitErr"; exit 1 }
  }
  # Idempotent: keeps an already-cloned working copy in step with a token that
  # was added, rotated, or removed from config since the clone.
  G remote set-url origin $authRepo | Out-Null
  G config user.name $Name | Out-Null
  G config user.email $Email | Out-Null
  # The data is written byte for byte; git must not rewrite line endings and
  # make an unchanged document look changed (or a changed one look clean).
  G config core.autocrlf false | Out-Null

  # The only paths this node owns. Nothing else is ever staged: three writers
  # share one repository, and on 2026-10-11 the Pi's `git add .` committed
  # another node's file, after which every rebase conflicted for hours.
  $dataRel = if ($SubPath -eq '.' -or -not $SubPath) { $DataFile } else { ($SubPath.TrimEnd('/', '\') -replace '\\', '/') + '/' + $DataFile }
  $owned = @($dataRel)
  $pageRel = $null
  if ($PagePath -and (Test-Path $PagePath)) {
    $pageRel = if ($SubPath -eq '.' -or -not $SubPath) { 'index.html' } else { ($SubPath.TrimEnd('/', '\') -replace '\\', '/') + '/index.html' }
    $owned += $pageRel
  }
  $enc = New-Object System.Text.UTF8Encoding($false)
  function Write-Owned {
    $full = Join-Path $WorkDir ($dataRel -replace '/', '\')
    $dir = Split-Path -Parent $full
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    # UTF-8 without BOM. PowerShell's -Encoding utf8 means "with BOM" on 5.1, and
    # a BOM makes the document unparseable to JSON.parse in the browser.
    [System.IO.File]::WriteAllText($full, $text, $enc)
    if ($pageRel) {
      # The page travels with the data so a page fix reaches the site on the
      # next publish. Pointed at the live endpoint, if there is one, by a
      # literal swap of one line.
      $html = [System.IO.File]::ReadAllText($PagePath)
      if ($LiveUrl) { $html = $html.Replace("const DATA_URL = 'status.json'", "const DATA_URL = '$LiveUrl'") }
      [System.IO.File]::WriteAllText((Join-Path $WorkDir ($pageRel -replace '/', '\')), $html, $enc)
    }
  }

  # A dry run writes this node's files into the working copy as it stands and
  # stops: no fetch, no reset, no commit.
  if ($DryRun) { Write-Owned; Log "dry run: wrote $dataRel (nothing pushed)"; exit 0 }

  # --- 1. Leftovers from an interrupted run. The lock above means no other run
  # is in here, so an unfinished rebase or merge, or a stale index lock, is debris.
  if ((Test-Path '.git\rebase-merge') -or (Test-Path '.git\rebase-apply')) {
    Log "found an unfinished rebase in $WorkDir; aborting it" 'WARN'
    if ((G rebase --abort) -ne 0) { if ((G reset --quiet --merge) -ne 0) { Fail "could not clear an unfinished rebase: $script:GitErr" } }
  }
  if (Test-Path '.git\MERGE_HEAD') {
    Log "found an unfinished merge in $WorkDir; aborting it" 'WARN'
    if ((G merge --abort) -ne 0) { Fail "could not clear an unfinished merge: $script:GitErr" }
  }
  if (Test-Path '.git\index.lock') {
    Log 'removing a stale .git\index.lock left by an interrupted run' 'WARN'
    Remove-Item '.git\index.lock' -Force -ErrorAction SilentlyContinue
  }

  # --- 2. Where the shared branch is now. Nothing is committed until this works,
  # so a network failure leaves no local commit behind to diverge later.
  $up = "refs/remotes/origin/$Branch"
  if ((G fetch --quiet origin "+refs/heads/${Branch}:$up") -ne 0) { Fail "fetch failed: $script:GitErr" }

  # --- 3. Local commits the branch does not have: decide what they are before
  # moving past them.
  $ahead = 0
  if ((G rev-list --count "$up..HEAD") -eq 0) { $ahead = [int]("0" + $script:GitOut.Trim()) }
  if ($ahead -gt 0) {
    G log --format= --name-only "$up..HEAD" | Out-Null
    $foreign = @($script:GitOut -split "`r?`n" | Where-Object { $_ -and ($owned -notcontains $_) } | Sort-Object -Unique)
    $stampRef = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    if ($foreign.Count) {
      # Not ours to drop: keep them on a branch, say so as ERROR, publish from the tip.
      if ((G branch -f "publisher-preserved-$stampRef" HEAD) -ne 0) {
        Fail "could not preserve $ahead unpublished local commit(s) touching $($foreign -join ' ') -- leaving the working copy alone"
      }
      Log "$ahead unpublished local commit(s) touched files this node does not own ($($foreign -join ' ')); kept on branch publisher-preserved-$stampRef, publishing from origin/$Branch" 'ERROR'
    } else {
      # Older snapshots of this node's own file, superseded by the payload about
      # to be written. The last is kept on a ref, so nothing is lost silently.
      G update-ref refs/xl1-publish/superseded HEAD | Out-Null
      Log "$ahead unpublished snapshot(s) of $dataRel superseded by this run (last kept at refs/xl1-publish/superseded)" 'NOTICE'
    }
  }

  # --- 4. Stray edits to tracked files: never staged, but logged, and replaced
  # by the branch's copy when the working copy moves to the tip.
  G status --porcelain --untracked-files=no | Out-Null
  $stray = @($script:GitOut -split "`r?`n" | Where-Object { $_.Length -gt 3 } | ForEach-Object { $_.Substring(3) } | Where-Object { $owned -notcontains $_ })
  if ($stray.Count) { Log "working copy had local edits to files this node does not own ($($stray -join ' ')); replacing them with origin/$Branch" 'WARN' }

  # Straight to the live endpoint, before the git push: this is the copy people
  # actually read, and it should not wait on a commit.
  if ($LiveUrl) {
    try {
      $headers = @{ 'content-type' = 'application/json' }
      if ($LiveAuth) { $headers['authorization'] = $LiveAuth }
      Invoke-WebRequest -Uri $LiveUrl -Method $LiveMethod -Headers $headers `
        -Body ([Text.Encoding]::UTF8.GetBytes($text)) -TimeoutSec 20 -UseBasicParsing | Out-Null
      Log 'live endpoint updated'
    } catch {
      # Never fatal. The git copy below is the fallback.
      Log "live endpoint failed -- $($_.Exception.Message)"
    }
  }

  $stamp = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + 'Z'
  # The node's own name for itself, taken from the payload rather than from
  # configuration -- a history of "." tells a reader nothing.
  $who = if ($doc.label) { $doc.label } elseif ($SubPath -and $SubPath -ne '.') { $SubPath } else { 'status' }

  # Write this node's files on the branch tip and commit them, and only them.
  # Returns 3 when there is nothing new to commit.
  function Commit-OnTip {
    if ((G reset --quiet --hard $up) -ne 0) { Fail "could not move the working copy to origin/${Branch}: $script:GitErr" }
    Write-Owned
    $addArgs = @('add', '--') + $owned
    if ((G @addArgs) -ne 0) { Fail "could not stage $($owned -join ' '): $script:GitErr" }
    if ((G diff --cached --quiet) -eq 0) { return 3 }
    if ((G commit --quiet -m "$who at $stamp") -ne 0) { Fail "commit failed: $script:GitErr" }
    return 0
  }

  if ((Commit-OnTip) -eq 3) { Succeed 'no change since the last publish' }

  # Three writers push to one branch. A push rejected for being behind is
  # rebuilt on the new tip -- it touches only this node's file, so there is
  # nothing to merge -- and retried with a short random backoff, never forced.
  $perr = ''
  for ($attempt = 1; $attempt -le $PushAttempts; $attempt++) {
    if ((G push --quiet origin "HEAD:refs/heads/$Branch") -eq 0) { Succeed "published $who" }
    $perr = $script:GitErr
    if ($attempt -eq $PushAttempts) { break }
    Start-Sleep -Milliseconds (300 + (Get-Random -Maximum 700))
    if ((G fetch --quiet origin "+refs/heads/${Branch}:$up") -ne 0) { Fail "push rejected ($perr); then fetch failed: $script:GitErr" }
    if ((Commit-OnTip) -eq 3) { Succeed 'no change since the last publish' }
  }
  # Back to the tip so a failed push leaves no local commit to diverge from.
  G reset --quiet --hard $up | Out-Null
  Fail "push rejected $PushAttempts times: $perr"
}
finally { Pop-Location }
