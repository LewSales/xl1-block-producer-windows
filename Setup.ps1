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

function Say  { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }
function Head { param($m) Write-Host ''; Write-Host "==> $m" -ForegroundColor Cyan }
function Die  { param($m) Write-Host ''; Write-Host "error: $m" -ForegroundColor Red; exit 1 }

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
    Say 'WARNING: sequence-producer.env in the project root DIFFERS from config\.' 'Red'
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

if (-not $SkipBuild) {
  Head "Building images (xl1-cli $CliVersion, linux/amd64)"
  & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'Build.ps1') -CliVersion $CliVersion
  if ($LASTEXITCODE -ne 0) { Die 'image build failed' }
}

if (-not $SkipTask) {
  Head 'Collector scheduled task'
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
    Say 'it delivers nothing until a channel is set in config\alert.env' 'Gray'
  }
  catch {
    Say "could not register the alerter task: $($_.Exception.Message)" 'Yellow'
    Say "  powershell -File `"$alertScript`"" 'Yellow'
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
Write-Host ''
