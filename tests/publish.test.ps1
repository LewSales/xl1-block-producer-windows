<#
.SYNOPSIS
  scripts\xl1-publish.ps1 against a real git "origin" shared with a second writer.

.DESCRIPTION
  The Windows twin of the Pi's tests/publish.test.sh. A bare repository stands
  in for xl1-status-data, and a separate clone writes rbpi3.json the way the Pi
  does while this publisher writes windows.json. Covers the failure of
  2026-10-11 -- a stray file committed by `git add .`, after which every rebase
  conflicted -- and the rest of what can go wrong around it.

  The script under test is copied into a scratch root so its shared log lands
  there, not in the repository's state directory.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Here    = $PSScriptRoot
$Source  = Join-Path (Split-Path -Parent $Here) 'scripts\xl1-publish.ps1'
$Work    = Join-Path $env:TEMP ('xl1-publish-test-' + [guid]::NewGuid().ToString('N'))
$script:Failed = 0
function Ok    { param($m) Write-Host "    ok   $m" -ForegroundColor Green }
function Fail  { param($m, $extra = '') Write-Host "    FAIL $m" -ForegroundColor Red; if ($extra) { Write-Host "         $extra" -ForegroundColor Red }; $script:Failed++ }
function Check { param($name, $got, $want) if ("$got" -eq "$want") { Ok $name } else { Fail $name "want: $want   got: $got" } }
function Has   { param($name, $pattern, $text) if ("$text" -match $pattern) { Ok $name } else { Fail $name "no /$pattern/ in: $(("$text" -split "`n" | Select-Object -Last 4) -join ' | ')" } }
function Hasnt { param($name, $pattern, $text) if ("$text" -match $pattern) { Fail $name "found /$pattern/" } else { Ok $name } }

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Write-Host '    skipped: git not installed'; exit 0 }

$env:GIT_AUTHOR_NAME = 't'; $env:GIT_AUTHOR_EMAIL = 't@t'; $env:GIT_COMMITTER_NAME = 't'; $env:GIT_COMMITTER_EMAIL = 't@t'
$env:GIT_CONFIG_GLOBAL = Join-Path $Work 'gitconfig'
New-Item -ItemType Directory -Path $Work -Force | Out-Null
'' | Set-Content -Path $env:GIT_CONFIG_GLOBAL
& git config --global init.defaultBranch main
& git config --global core.autocrlf false

$Root   = Join-Path $Work 'root'
New-Item -ItemType Directory -Path (Join-Path $Root 'scripts'), (Join-Path $Root 'state') -Force | Out-Null
$Script = Join-Path $Root 'scripts\xl1-publish.ps1'
Copy-Item $Source $Script
$Origin = Join-Path $Work 'origin.git'
$OriginUrl = 'file:///' + ($Origin -replace '\\', '/')
$Wc     = Join-Path $Work 'wc'
$Pi     = Join-Path $Work 'pi'
$Payload = Join-Path $Work 'payload.json'
$Cfg    = Join-Path $Work 'publish.env'
$Log    = Join-Path $Root 'state\.publish-log'
$enc    = New-Object System.Text.UTF8Encoding($false)
function W { param($path, $text) [System.IO.File]::WriteAllText($path, $text, $enc) }
function Gq { & git @args 2>&1 | Out-Null }

function Setup {
  foreach ($d in $Origin, $Wc, $Pi, (Join-Path $Work 'seed')) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
  if (Test-Path $Log) { Remove-Item $Log -Force }
  Gq init -q --bare $Origin
  $seed = Join-Path $Work 'seed'
  Gq init -q $seed
  W (Join-Path $seed 'rbpi3.json') '{"label":"rbpi3","v":0}'
  W (Join-Path $seed 'windows.json') '{"label":"windows","v":0}'
  W (Join-Path $seed 'race.json') '{"r":0}'
  Gq -C $seed add .; Gq -C $seed commit -qm seed; Gq -C $seed push -q $OriginUrl HEAD:main
  Gq clone -q $OriginUrl $Pi
  Payload 1
  W $Cfg @"
XL1_PUBLISH_REPO=$OriginUrl
XL1_PUBLISH_BRANCH=main
XL1_PUBLISH_PATH=.
XL1_PUBLISH_FILE=windows.json
XL1_PUBLISH_PAGE=
XL1_PUBLISH_WORKDIR=$Wc
XL1_PUBLISH_URL=file:///$($Payload -replace '\\', '/')
XL1_PUBLISH_GIT_TIMEOUT=30
"@
}
function Payload { param($v) W $Payload "{`"schema`":1,`"label`":`"windows`",`"v`":$v}" }
# The other node: a separate clone that writes rbpi3.json and pushes.
function Pi-Writes { param($v)
  Gq -C $Pi pull -q --rebase origin main
  W (Join-Path $Pi 'rbpi3.json') "{`"label`":`"rbpi3`",`"v`":$v}"
  Gq -C $Pi commit -qam "rbpi3 $v"; Gq -C $Pi push -q origin HEAD:main
}
function Publish { param([string[]]$Extra = @())
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script -Config $Cfg @Extra 2>&1 | Out-String
  $script:Rc = $LASTEXITCODE
  return $out
}
function OriginFile { param($f) (& git --git-dir=$Origin show "main:$f" 2>$null) -join "`n" }
function LastFiles { ((& git --git-dir=$Origin show --format= --name-only main 2>$null) | Where-Object { $_ }) -join ' ' }
function Ahead { (& git -C $Wc rev-list --count refs/remotes/origin/main..HEAD 2>$null).Trim() }
function State { param($k) $f = Join-Path $Wc '.git\xl1-publish.state'; if (Test-Path $f) { foreach ($l in Get-Content $f) { if ($l.StartsWith("$k=")) { return $l.Substring($k.Length + 1) } } }; '' }
function LogText { if (Test-Path $Log) { (Get-Content $Log) -join "`n" } else { '' } }
function Count { (& git --git-dir=$Origin rev-list --count main).Trim() }

Write-Host '  first publish clones and pushes only windows.json'
Setup; $o = Publish
Check 'exit 0' $script:Rc 0
Check 'origin has the payload' (OriginFile 'windows.json') '{"schema":1,"label":"windows","v":1}'
Check 'commit touches only windows.json' (LastFiles) 'windows.json'
Check 'rbpi3.json untouched' (OriginFile 'rbpi3.json') '{"label":"rbpi3","v":0}'
Check 'state: failures 0' (State 'failures') 0

Write-Host '  both writers keep publishing without overwriting each other'
Pi-Writes 1; Payload 2; $o = Publish
Check 'exit 0 after the other node pushed' $script:Rc 0
Pi-Writes 2; Payload 3; $o = Publish; Pi-Writes 3
Check 'windows.json is ours' (OriginFile 'windows.json') '{"schema":1,"label":"windows","v":3}'
Check 'rbpi3.json is theirs' (OriginFile 'rbpi3.json') '{"label":"rbpi3","v":3}'

Write-Host '  no change: nothing committed'
$n0 = Count; $o = Publish
Check 'exit 0' $script:Rc 0
Check 'no new commit' (Count) $n0
Has 'says no change' 'no change since the last publish' $o

Write-Host '  an unrelated modified file in the working copy is never committed'
W (Join-Path $Wc 'rbpi3.json') '{"stale":true}'; Payload 4; $o = Publish
Check 'exit 0' $script:Rc 0
Check 'commit touches only windows.json' (LastFiles) 'windows.json'
Check 'rbpi3.json still theirs' (OriginFile 'rbpi3.json') '{"label":"rbpi3","v":3}'
Has 'stray edit logged as WARN' 'WARN: working copy had local edits to files this node does not own \(rbpi3.json' (LogText)

Write-Host '  the 2026-10-11 failure: a local commit carrying another node''s file, origin moved on'
W (Join-Path $Wc 'rbpi3.json') '{"stale":true}'; W (Join-Path $Wc 'windows.json') '{"old":true}'
Gq -C $Wc commit -qam 'windows at old'
Pi-Writes 4; Payload 5; $o = Publish
Check 'exit 0 (recovers instead of conflicting forever)' $script:Rc 0
Check 'windows.json published' (OriginFile 'windows.json') '{"schema":1,"label":"windows","v":5}'
Check 'rbpi3.json not overwritten' (OriginFile 'rbpi3.json') '{"label":"rbpi3","v":4}'
Check 'the foreign commit is preserved on a branch' (@(& git -C $Wc branch --list 'publisher-preserved-*').Count) 1
Has 'and reported as ERROR' 'ERROR: 1 unpublished local commit\(s\) touched files this node does not own \(rbpi3.json' (LogText)
Check 'nothing left unpushed' (Ahead) 0

Write-Host '  diverged with only our own snapshots: superseded, last kept on a ref'
W (Join-Path $Wc 'windows.json') '{"older":true}'; Gq -C $Wc commit -qam 'windows older'
Pi-Writes 5; Payload 6; $o = Publish
Check 'exit 0' $script:Rc 0
& git -C $Wc rev-parse -q --verify refs/xl1-publish/superseded 2>&1 | Out-Null
Check 'superseded ref kept' $LASTEXITCODE 0
Has 'noted' 'NOTICE: 1 unpublished snapshot\(s\) of windows.json superseded' (LogText)
Check 'rbpi3.json not overwritten' (OriginFile 'rbpi3.json') '{"label":"rbpi3","v":5}'

Write-Host '  an unfinished rebase left by an interrupted run is cleared'
W (Join-Path $Wc 'rbpi3.json') '{"x":1}'; Gq -C $Wc commit -qam conflicting
Pi-Writes 6
Gq -C $Wc fetch -q origin; Gq -C $Wc rebase -q origin/main
Check 'test set-up: rebase in progress' ((Test-Path (Join-Path $Wc '.git\rebase-merge')) -or (Test-Path (Join-Path $Wc '.git\rebase-apply'))) True
Payload 7; $o = Publish
Check 'exit 0' $script:Rc 0
Check 'windows.json published' (OriginFile 'windows.json') '{"schema":1,"label":"windows","v":7}'
Check 'rbpi3.json not overwritten' (OriginFile 'rbpi3.json') '{"label":"rbpi3","v":6}'
Check 'no rebase left behind' ((Test-Path (Join-Path $Wc '.git\rebase-merge')) -or (Test-Path (Join-Path $Wc '.git\rebase-apply'))) False

$hook = Join-Path $Origin 'hooks\pre-receive'
Write-Host '  a push rejected once is rebuilt on the new tip and retried, never forced'
$flag = (Join-Path $Work 'rejected-once') -replace '\\', '/'
W $hook "#!/bin/sh`nif [ ! -f '$flag' ]; then touch '$flag'; echo 'rejected once by test hook' >&2; exit 1; fi`n"
Payload 8; $o = Publish
Check 'exit 0 on the retry' $script:Rc 0
Check 'published' (OriginFile 'windows.json') '{"schema":1,"label":"windows","v":8}'
Remove-Item $hook

Write-Host '  failed pushes: git''s error kept (credentials scrubbed), escalated once, nothing left to diverge'
W $hook "#!/bin/sh`necho 'denied by test hook: https://bot:ghp_SECRETSECRET123@github.com/x token=hunter2' >&2`nexit 1`n"
Remove-Item $Log -ErrorAction SilentlyContinue
foreach ($i in 1..4) { Payload "9$i"; $null = Publish }
Payload 95; $o = Publish
Check 'exit 1' $script:Rc 1
$lt = LogText
Has "git's own error reaches the log" 'denied by test hook' $lt
Hasnt 'no token in the log' 'ghp_SECRET|hunter2|bot:' $lt
Hasnt 'no token in the output' 'ghp_SECRET|hunter2|bot:' $o
Check 'ERROR line exactly once in 5 failures' (@($lt -split "`n" | Where-Object { $_ -match 'ERROR: publishing windows.json has failed' }).Count) 1
Check 'state: failures 5' (State 'failures') 5
Check 'no local commit left ahead of origin' (Ahead) 0
Remove-Item $hook
Remove-Item $Log -ErrorAction SilentlyContinue
Payload 10; $o = Publish
Check 'recovers: exit 0' $script:Rc 0
Has 'recovery noted once' 'NOTICE: publishing windows.json recovered after 5 failed run' (LogText)
Check 'state: failures back to 0' (State 'failures') 0

Write-Host '  fetch failure: fails without leaving a commit behind'
Rename-Item $Origin 'origin.moved'; Payload 11; $o = Publish
Check 'exit 1' $script:Rc 1
Has "says fetch failed with git's reason" 'fetch failed: \S+' $o
Rename-Item (Join-Path $Work 'origin.moved') 'origin.git'
Check 'no local commit created' (Ahead) 0

Write-Host '  a bad payload is never published'
$n0 = Count
W $Payload '{"error":"boom"}'; $o = Publish
Check 'exit 1' $script:Rc 1
Check 'no new commit' (Count) $n0

Write-Host '  overlapping runs: the second skips'
Payload 12
$sha = [System.Security.Cryptography.SHA1]::Create()
$key = (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Wc.ToLowerInvariant())) | ForEach-Object { $_.ToString('x2') })).Substring(0, 16)
$m = $null; foreach ($ns in 'Global', 'Local') { try { $m = New-Object System.Threading.Mutex($false, "$ns\xl1-publish-$key"); break } catch {} }
$null = $m.WaitOne(0)
$o = Publish
$m.ReleaseMutex(); $m.Dispose()
Check 'exit 0' $script:Rc 0
Has 'says another run is in progress' 'another publish is still running' $o
Check 'nothing published by the skipped run' (Count) $n0

Write-Host '  -Status prints the run state'
$o = Publish @('-Status')
Has 'shows lastSuccess' '(?m)^lastSuccess=' $o

Write-Host '  -DryRun writes locally and commits nothing'
Payload 13; $o = Publish @('-DryRun')
Check 'exit 0' $script:Rc 0
Check 'no new commit' (Count) $n0

Remove-Item $Work -Recurse -Force -ErrorAction SilentlyContinue
if ($script:Failed) { exit 1 } else { exit 0 }
