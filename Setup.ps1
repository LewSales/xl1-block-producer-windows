<#
.SYNOPSIS
  One-time setup for running an XL1 producer on this PC.

.DESCRIPTION
  Fetches the official xl1-docker-images repository, builds the amd64 images,
  creates the config files, and registers the collector as a scheduled task.

  Safe to re-run: it skips what is already done and never overwrites a config
  file that exists.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Setup.ps1
#>
[CmdletBinding()]
param(
  [string]$CliVersion = '5.3.1',
  [switch]$SkipBuild,
  [switch]$SkipTask
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot

# Native tools write progress to stderr -- git says "Cloning into..." there on a
# perfectly good clone. With ErrorActionPreference=Stop that becomes a
# terminating error and aborts everything after it, which is how a successful
# clone stopped setup before it wrote the config files. Judge native commands by
# their exit code, which is what it actually means.
function Invoke-Native {
  param([scriptblock]$Command, [string]$What)
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & $Command 2>&1 | Out-String | Write-Verbose } finally { $ErrorActionPreference = $prev }
  if ($LASTEXITCODE -ne 0) { Die "$What failed (exit $LASTEXITCODE)" }
}

# Registering a scheduled task needs administrator, and PowerShell cannot
# elevate itself part-way through a script. Asked once, up front, because the
# answer decides what this run can finish -- the Pi's provision.sh refuses at
# line one for the same reason, and the alternative here was letting an operator
# sit through a git fetch and an image build to be told "Access is denied" twice
# at the end, with nothing saying why or what to do about it.
function Test-Elevated {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
      [Security.Principal.WindowsBuiltInRole]::Administrator)
  }
  catch { $false }
}

function Say  { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }
function Head { param($m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Die  { param($m) Write-Host ''; Write-Host "error: $m" -ForegroundColor Red; exit 1 }

$Elevated = Test-Elevated
$Relaunch = "Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','$PSCommandPath'"

Head 'Prerequisites'
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Die 'Docker Desktop is not installed. Install it, start it, then re-run this.'
}
& docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Die 'Docker Desktop is installed but not running. Start it, then re-run this.' }
Say 'Docker responding' 'Green'

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
  Die 'git is not installed. Install Git for Windows, then re-run this.'
}
Say 'git present' 'Green'

Head 'Official producer images'
$Upstream = Join-Path $Root 'upstream'
if (Test-Path (Join-Path $Upstream '.git')) {
  Say 'updating upstream/ (XYOracleNetwork/xl1-docker-images)'
  Invoke-Native { git -C $Upstream fetch --depth 1 origin main } 'git fetch'
  Invoke-Native { git -C $Upstream reset --hard origin/main } 'git reset'
}
else {
  Say 'cloning XYOracleNetwork/xl1-docker-images'
  Invoke-Native { git clone --depth 1 https://github.com/XYOracleNetwork/xl1-docker-images.git $Upstream } 'git clone'
}
Say 'upstream ready' 'Green'

Head 'Configuration'
$cfg = Join-Path $Root 'config'
New-Item -ItemType Directory -Force -Path $cfg, (Join-Path $Root 'state') | Out-Null

$producerEnv = Join-Path $cfg 'sequence-producer.env'
if (Test-Path $producerEnv) {
  Say 'config\sequence-producer.env already exists -- left untouched'
}
else {
  # Copy the upstream example rather than shipping our own: it is the authority
  # on which variables the entrypoint actually reads.
  $example = Join-Path $Upstream 'examples\env\sequence-producer.env.example'
  if (-not (Test-Path $example)) { Die "upstream example missing at $example" }
  Copy-Item $example $producerEnv
  Say 'created config\sequence-producer.env from the upstream example' 'Yellow'
  Say 'You must fill in XL1_MNEMONIC and XL1_REWARD_ADDRESS before starting.' 'Yellow'
}

# An env file sitting beside this script is not the one anything reads, and
# editing it looks like it worked. Say so, and say which file is live.
$stray = Join-Path $Root 'sequence-producer.env'
if (Test-Path $stray) {
  if ((Get-FileHash $stray).Hash -eq (Get-FileHash $producerEnv).Hash) {
    Say 'sequence-producer.env in the project root is an identical copy of the live' 'Yellow'
    Say 'one in config\. Nothing reads it. Delete it to avoid editing the wrong file.' 'Yellow'
  }
  else {
    $rootKeys = @{}; $liveKeys = @{}
    foreach ($pair in @(@($stray, $rootKeys), @($producerEnv, $liveKeys))) {
      foreach ($line in (Get-Content $pair[0] -ErrorAction SilentlyContinue)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $i = $t.IndexOf('='); if ($i -lt 1) { continue }
        $pair[1][$t.Substring(0, $i).Trim()] = $t.Substring($i + 1).Trim()
      }
    }
    $differing = @(($rootKeys.Keys + $liveKeys.Keys | Sort-Object -Unique) |
      Where-Object { $rootKeys[$_] -ne $liveKeys[$_] })
    Say 'WARNING: sequence-producer.env in the project root DIFFERS from config\.' 'Red'
    if ($differing.Count) { Say ('         differing key(s): ' + ($differing -join ', ')) 'Red' }
    Say 'Only config\sequence-producer.env is read. If your edits are in the root' 'Red'
    Say 'copy, move them across before starting the producer.' 'Red'
  }
}

$dashEnv = Join-Path $cfg 'dashboard.env'
if (Test-Path $dashEnv) { Say 'config\dashboard.env already exists -- left untouched' }
else {
  Copy-Item (Join-Path $cfg 'dashboard.env.template') $dashEnv
  Say 'created config\dashboard.env' 'Green'
}

# Every channel in it is empty, so the alerter runs and delivers nothing until
# an operator fills one in. Created anyway: a file that exists gets edited, and
# one that has to be found first does not.
$publishEnv = Join-Path $cfg 'publish.env'
if (Test-Path $publishEnv) { Say 'config\publish.env already exists -- left untouched' }
elseif (Test-Path (Join-Path $cfg 'publish.env.template')) {
  Copy-Item (Join-Path $cfg 'publish.env.template') $publishEnv
  Say 'created config\publish.env' 'Green'
}

$alertEnv = Join-Path $cfg 'alert.env'
if (Test-Path $alertEnv) { Say 'config\alert.env already exists -- left untouched' }
else {
  Copy-Item (Join-Path $cfg 'alert.env.template') $alertEnv
  Say 'created config\alert.env (no channels set -- alerts are off until you edit it)' 'Green'
}

Head 'Dashboard source'
$dashDir = Join-Path $Root 'dashboard'
if (Test-Path (Join-Path $dashDir 'server.mjs')) { Say 'dashboard\ already present' }
else {
  $sibling = Join-Path (Split-Path -Parent $Root) 'xl1-pi\dashboard'
  if (Test-Path (Join-Path $sibling 'server.mjs')) {
    Copy-Item -Recurse -Force $sibling $dashDir
    Say 'copied from the sibling xl1-pi checkout' 'Green'
  }
  else {
    $tmp = Join-Path $env:TEMP ('xl1-dash-' + [guid]::NewGuid().ToString('N'))
    Invoke-Native { git clone --depth 1 https://github.com/LewSales/xl1-block-producer-pi.git $tmp } 'dashboard fetch'
    Copy-Item -Recurse -Force (Join-Path $tmp 'dashboard') $dashDir
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    Say 'fetched from the public repo' 'Green'
  }
}

# Warned rather than fatal, unlike the Pi. Everything up to the scheduled tasks
# -- fetching upstream, building the images, writing the config -- works fine
# without administrator, and re-running elevated afterwards is idempotent. It is
# said here rather than at the end so nobody spends the build finding out.
if (-not $Elevated -and -not $SkipTask) {
  Say ''
  Say 'NOT RUNNING AS ADMINISTRATOR' 'Yellow'
  Say 'Everything below works except registering the scheduled tasks, which is' 'Yellow'
  Say 'what keeps the collector and the alerter running. To do the whole thing:' 'Yellow'
  Say ''
  Say "  $Relaunch" 'Cyan'
  Say ''
  Say 'Continuing without the tasks. Add -SkipTask to silence this.' 'Yellow'
}

if (-not $SkipBuild) {
  Head "Building images (xl1-cli $CliVersion, linux/amd64)"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Build.ps1') -CliVersion $CliVersion
  if ($LASTEXITCODE -ne 0) { Die 'image build failed' }
}

if (-not $SkipTask -and -not $Elevated) {
  Head 'Scheduled tasks'
  Say 'skipped -- needs administrator' 'Yellow'
  Say 'Re-run elevated to register the collector and the alerter:' 'Yellow'
  Say "  $Relaunch" 'Cyan'
  # Deliberately not attempted. Unregister-ScheduledTask is -SilentlyContinue,
  # so a failed re-register used to leave the previous task in place while the
  # output showed two denials -- which reads as "the tasks are broken now"
  # rather than "nothing changed".
}
elseif (-not $SkipTask) {
  Head 'Scheduled tasks'
  # The dashboard never gets the Docker socket, so something on the host must
  # write the snapshot it reads. On the Pi that is a systemd timer; here it is
  # Task Scheduler, every 30 seconds, whether or not anyone is logged in.
  $taskName = 'XL1 Collector'
  $script   = Join-Path $Root 'scripts\xl1-collect.ps1'
  $argline  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $script + '"'
  $action   = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argline

  # One minute, not thirty seconds: Task Scheduler's minimum repetition interval
  # is one minute and it rejects anything shorter outright -- which is what
  # "Interval:PT30S ... out of range" meant. The dashboard treats a snapshot as
  # stale at two minutes, so a one-minute cadence still leaves margin.
  $every = New-TimeSpan -Minutes 1
  $forever = New-TimeSpan -Days 3650
  $tNow   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) `
              -RepetitionInterval $every -RepetitionDuration $forever
  $tBoot  = New-ScheduledTaskTrigger -AtStartup

  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
  try {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($tNow, $tBoot) `
      -Settings $settings -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName $taskName
    Say 'registered and started "XL1 Collector" (every 60s)' 'Green'
  }
  catch {
    Say "could not register the scheduled task: $($_.Exception.Message)" 'Yellow'
    Say 'Run this elevated, or start the collector by hand:' 'Yellow'
    Say "  powershell -File `"$script`"" 'Yellow'
  }

  # The Pi's xl1-alert.timer, in the only scheduler this machine has. Separate
  # from the collector because they fail independently: an alerter that cannot
  # reach its webhook must not stop the snapshot the dashboard reads, and a
  # collector that dies is a condition the alerter is supposed to report.
  $alertTask   = 'XL1 Alerter'
  $alertScript = Join-Path $Root 'scripts\xl1-alert.ps1'
  $alertArgs   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $alertScript + '"'
  $alertAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $alertArgs
  # Two minutes after the collector's first run, so the first evaluation reads a
  # snapshot rather than reporting a collector that has not written one yet.
  $aNow  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
             -RepetitionInterval $every -RepetitionDuration $forever
  $aBoot = New-ScheduledTaskTrigger -AtStartup
  try {
    Unregister-ScheduledTask -TaskName $alertTask -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $alertTask -Action $alertAction -Trigger @($aNow, $aBoot) `
      -Settings $settings -RunLevel Highest -Force | Out-Null
    Start-ScheduledTask -TaskName $alertTask
    Say 'registered and started "XL1 Alerter" (every 60s)' 'Green'
    if (-not (Test-Path $alertEnv) -or
        -not (Select-String -Path $alertEnv -Pattern '^(XL1_ALERT_(NTFY_TOPIC|WEBHOOK|EMAIL|DEADMAN_URL))=\s*\S' -Quiet)) {
      Say 'it delivers nothing until a channel is set in config\alert.env' 'Gray'
    }
  }
  catch {
    Say "could not register the alerter task: $($_.Exception.Message)" 'Yellow'
    Say "  powershell -File `"$alertScript`"" 'Yellow'
  }

  # The public page. Registered here rather than left as a snippet to paste,
  # because a page nobody scheduled is one that updates when somebody remembers
  # -- and a stale status page is worse than none, reporting yesterday with
  # today's confidence.
  $pubTask   = 'XL1 Publisher'
  $pubScript = Join-Path $Root 'scripts\xl1-publish.ps1'
  # Only when there is actually somewhere to publish to. This used to register
  # the task whenever the script existed, which meant a node with no destination
  # ran a publisher every five minutes that did nothing -- and a node whose
  # destination had been RETIRED went on publishing to it, reporting success the
  # whole time. That is how the public Windows page sat an hour stale while the
  # task said State Ready, LastTaskResult 0.
  $pubConfigured = (Test-Path $publishEnv) -and
                   (Select-String -Path $publishEnv -Pattern '^XL1_PUBLISH_REPO=\s*\S' -Quiet)
  if ((Test-Path $pubScript) -and $pubConfigured) {
    $pubArgs   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $pubScript + '"'
    $pubAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $pubArgs
    $pNow  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) `
               -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever
    $pBoot = New-ScheduledTaskTrigger -AtStartup
    try {
      Unregister-ScheduledTask -TaskName $pubTask -Confirm:$false -ErrorAction SilentlyContinue
      Register-ScheduledTask -TaskName $pubTask -Action $pubAction -Trigger @($pNow, $pBoot) `
        -Settings $settings -RunLevel Highest -Force | Out-Null
      Start-ScheduledTask -TaskName $pubTask
      Say 'registered and started "XL1 Publisher" (every 5m)' 'Green'
    }
    catch {
      Say "could not register the publisher task: $($_.Exception.Message)" 'Yellow'
      Say "  powershell -File `"$pubScript`"" 'Yellow'
    }
  }
  elseif (Test-Path $pubScript) {
    # No destination, so no task -- and remove one left over from when there
    # was, rather than leaving it running against a repository nobody serves.
    if (Get-ScheduledTask -TaskName $pubTask -ErrorAction SilentlyContinue) {
      try {
        Unregister-ScheduledTask -TaskName $pubTask -Confirm:$false -ErrorAction Stop
        Say 'removed "XL1 Publisher" -- config\publish.env names no repository' 'Green'
      }
      catch { Say "could not remove the old publisher task: $($_.Exception.Message)" 'Yellow' }
    }
    else {
      Say 'no XL1_PUBLISH_REPO in config\publish.env -- standalone publisher not registered' 'Gray'
    }
  }

  # The winlew.co site data. A second destination, not a replacement: the task
  # above keeps feeding the standalone status repo, and this one writes
  # windows.json into the site repo beside the Pi's file. One script, two
  # configs, selected with -Config, so the two cannot drift apart in behaviour.
  #
  # This had no task at all. The config existed and was only ever run by hand --
  # exactly the "updates when somebody remembers" failure the comment above
  # warns about. The public page sat an hour stale announcing that the node had
  # stopped publishing, while the node was healthy and winning blocks.
  $siteTask = 'XL1 Site Publisher'
  $siteEnv  = Join-Path $Root 'config\publish-site.env'
  if ((Test-Path $pubScript) -and (Test-Path $siteEnv)) {
    $siteArgs   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                  $pubScript + '" -Config "' + $siteEnv + '"'
    $siteAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $siteArgs
    # Offset from the other publisher rather than firing alongside it: both read
    # the same dashboard, and there is no reason to ask it for the same document
    # twice in the same second.
    $sNow  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(4) `
               -RepetitionInterval (New-TimeSpan -Minutes 5) -RepetitionDuration $forever
    $sBoot = New-ScheduledTaskTrigger -AtStartup
    try {
      Unregister-ScheduledTask -TaskName $siteTask -Confirm:$false -ErrorAction SilentlyContinue
      # -ErrorAction Stop, because Register-ScheduledTask reports "Access is
      # denied" as a NON-terminating error: without it the catch never runs and
      # the script cheerfully says it registered a task that does not exist.
      Register-ScheduledTask -TaskName $siteTask -Action $siteAction -Trigger @($sNow, $sBoot) `
        -Settings $settings -RunLevel Highest -Force -ErrorAction Stop | Out-Null
      Start-ScheduledTask -TaskName $siteTask
      Say 'registered and started "XL1 Site Publisher" (every 5m)' 'Green'
    }
    catch {
      Say "could not register the site publisher task: $($_.Exception.Message)" 'Yellow'
      Say "  powershell -File `"$pubScript`" -Config `"$siteEnv`"" 'Yellow'
    }
  }

  # GeoHackers, if this machine is also running that bot. Same publisher, a
  # third config, reading the bot's API instead of the dashboard. Registered
  # only when the config exists, so a node that does not run GeoHackers never
  # sees a task for it.
  $ghTask = 'XL1 GeoHackers Publisher'
  $ghEnv  = Join-Path $Root 'config\publish-geohackers.env'
  if ((Test-Path $pubScript) -and (Test-Path $ghEnv)) {
    $ghArgs   = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' +
                $pubScript + '" -Config "' + $ghEnv + '"'
    $ghAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $ghArgs
    # Ten minutes, not five. The bot's counts move when somebody runs a command,
    # not on a timer, so polling it as often as the chain buys nothing.
    $gNow  = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) `
               -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration $forever
    $gBoot = New-ScheduledTaskTrigger -AtStartup
    try {
      Unregister-ScheduledTask -TaskName $ghTask -Confirm:$false -ErrorAction SilentlyContinue
      Register-ScheduledTask -TaskName $ghTask -Action $ghAction -Trigger @($gNow, $gBoot) `
        -Settings $settings -RunLevel Highest -Force -ErrorAction Stop | Out-Null
      Start-ScheduledTask -TaskName $ghTask
      Say 'registered and started "XL1 GeoHackers Publisher" (every 10m)' 'Green'
    }
    catch {
      Say "could not register the geohackers publisher task: $($_.Exception.Message)" 'Yellow'
      Say "  powershell -File `"$pubScript`" -Config `"$ghEnv`"" 'Yellow'
    }
  }
}

Head 'Next'
Write-Host ''
Say '1. Fill in your credentials:'
Say "     notepad `"$producerEnv`""
Say ''
Say '2. If another machine runs a producer on the SAME mnemonic, stop it first.' 'Yellow'
Say '   Two producers signing with one wallet is the mistake worth avoiding.' 'Yellow'
Say '   Different mnemonics are independent nodes and can run side by side.' 'Yellow'
Say '     ssh <other-host> "sudo systemctl disable --now xl1-producer"' 'Yellow'
Say ''
Say '3. Start here:'
Say '     .\scripts\xl1ctl.ps1 start'
Say '     .\scripts\xl1ctl.ps1 doctor'

# Last thing on screen, because it is the thing that will otherwise be
# discovered a week later as a dashboard whose data stopped updating.
if (-not $Elevated -and -not $SkipTask) {
  Write-Host ''
  Say '4. The scheduled tasks are NOT registered. Without them the collector' 'Yellow'
  Say '   stops feeding the dashboard and nothing sends alerts. Re-run elevated:' 'Yellow'
  Say "     $Relaunch" 'Cyan'
}
Write-Host ''
