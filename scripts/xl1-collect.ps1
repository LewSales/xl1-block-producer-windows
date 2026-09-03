<#
.SYNOPSIS
  Collect producer state into the JSON the dashboard reads. Windows equivalent
  of xl1-collect.sh.

.DESCRIPTION
  Runs on the Windows host, not in a container -- for the same two reasons as on
  the Pi, both of which matter more here:

    * The dashboard never needs the Docker socket. A read-only socket mount is
      still full control of the daemon, which is not something to hand a
      network-listening service on a machine holding a wallet mnemonic.
    * Docker Desktop runs containers inside a Linux VM, so a container asking
      for CPU or memory gets the VM's, not this PC's. Anything describing the
      host has to be read from the host.

  Scheduled every 30 seconds by Install.ps1.
#>
[CmdletBinding()]
param(
  [string]$StateDir  = '',
  [string]$Container = '',
  [int]$HealthPort = 9099,
  [int]$RaceWindow = 3600,
  [int]$LogLines     = 40,
  [string]$EligibilityWindow = '20m'
)

$ErrorActionPreference = 'Stop'

# Native tools write to stderr as a matter of course -- docker logs sends the
# container's own log there, and git says "Cloning into..." on success. Under
# ErrorActionPreference=Stop PowerShell promotes any of that to a terminating
# error, so a healthy container's log would abort the collector every cycle.
#
# Judge native commands by their exit code, which is what it actually means.
function Invoke-Docker {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try { & docker @args 2>&1 } finally { $ErrorActionPreference = $prev }
}

# $PSScriptRoot is not populated while param() defaults are evaluated in
# PowerShell 5.1 -- it is set when the body starts. A default referring to it
# silently becomes an empty path.
if (-not $StateDir) { $StateDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'state' }

$Out = Join-Path $StateDir 'producer-status.json'
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

# PowerShell 5.1's -Encoding utf8 means "UTF-8 with BOM", and a BOM makes the
# document unparseable to JSON.parse -- the dashboard reported exactly that, by
# name, rather than going quiet, which is the only reason this took one attempt.
function Write-Json($Object, [string]$Path) {
  $json = $Object | ConvertTo-Json -Depth 6
  # Validate before publishing so the dashboard never reads a half-written file.
  try { $null = $json | ConvertFrom-Json }
  catch { Write-Error 'produced invalid JSON; kept previous snapshot'; exit 1 }
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-CacheAge([string]$Path) {
  if (-not (Test-Path $Path)) { return [int]::MaxValue }
  [int]((Get-Date) - (Get-Item $Path).LastWriteTime).TotalSeconds
}

# Cache format version. Bump when any file below changes shape, so a shipped
# change self-invalidates instead of an operator being told which file to delete.
$CacheSchema = 1
$SchemaStamp = Join-Path $StateDir '.cache-schema'
if ((-not (Test-Path $SchemaStamp)) -or ((Get-Content $SchemaStamp -Raw).Trim() -ne "$CacheSchema")) {
  foreach ($stale in '.cli-version', '.eligibility', '.last-published') {
    Remove-Item -Force -EA SilentlyContinue (Join-Path $StateDir $stale)
  }
  Set-Content -Path $SchemaStamp -Value $CacheSchema -NoNewline
}

if (-not $Container) {
  $found = (Invoke-Docker ps -a --filter 'name=preset' --format '{{.Names}}' | Select-Object -First 1)
  $Container = if ($found) { $found } else { 'xl1-node-preset-1' }
}

$collectedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

# ---------------------------------------------------------------- host metrics
function Get-HostMetrics {
  $os   = Get-CimInstance Win32_OperatingSystem
  $cs   = Get-CimInstance Win32_ComputerSystem
  $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($env:SystemDrive)'"

  $totalB = [int64]$cs.TotalPhysicalMemory
  $freeB  = [int64]$os.FreePhysicalMemory * 1KB
  # Win32_Processor.LoadPercentage is coarse and reads 0 at anything near idle —
  # measured 0, 0, 2 while the performance counter said 5.1. The counter is the
  # accurate source, but its path is localised, so a non-English Windows throws
  # and falls back rather than reporting nothing.
  $cpu = $null
  try { $cpu = [math]::Round((Get-Counter '\Processor(_Total)\% Processor Time' -ErrorAction Stop).CounterSamples.CookedValue, 1) } catch { }
  if ($null -eq $cpu) { $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average }

  [ordered]@{
    hostname       = $env:COMPUTERNAME
    platform       = 'windows'
    uptimeSeconds  = [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
    cpuPercent     = $(if ($null -ne $cpu) { [math]::Round([double]$cpu, 1) } else { $null })
    cpuCount       = [int]$cs.NumberOfLogicalProcessors
    memory = [ordered]@{
      totalBytes     = $totalB
      availableBytes = $freeB
      usedPercent    = if ($totalB) { [int](100 - ($freeB / $totalB * 100)) } else { $null }
    }
    disk = [ordered]@{
      totalBytes  = [int64]$disk.Size
      freeBytes   = [int64]$disk.FreeSpace
      usedPercent = if ($disk.Size) { [int](100 - ($disk.FreeSpace / $disk.Size * 100)) } else { $null }
    }
  }
}

# ------------------------------------------------------------------- container
$doc = [ordered]@{ collectedAt = $collectedAt }

$inspect = Invoke-Docker inspect $Container --format `
  '{{.State.Status}}|{{.State.Running}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.Config.Image}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Image}}' 2>$null

if ($LASTEXITCODE -ne 0 -or -not $inspect) {
  # A container that does not exist is a first-class state, not a missing field.
  $doc.container = $null
  $doc.error     = "container $Container not found"
  $doc.host      = Get-HostMetrics
  Write-Json $doc "$Out.tmp"
  Move-Item -Force "$Out.tmp" $Out
  exit 0
}

$f = $inspect.Trim() -split '\|'
$started = [datetime]::Parse($f[2])
$up = (Get-Date) - $started.ToLocalTime()
# [int] in PowerShell ROUNDS, it does not truncate, so a container up 1h31m
# reported "2h 31m" -- an uptime that ran ahead of the truth by up to half an
# hour and, on the day scale, by twelve. The Pi's shell arithmetic truncates,
# which is what makes the two panels disagree about the same container.
$uptime = if ($up.TotalDays -ge 1) { '{0}d {1}h' -f [int][Math]::Floor($up.TotalDays), $up.Hours }
          elseif ($up.TotalHours -ge 1) { '{0}h {1}m' -f [int][Math]::Floor($up.TotalHours), $up.Minutes }
          else { '{0}m' -f [int][Math]::Floor($up.TotalMinutes) }

$doc.container = [ordered]@{
  name = $Container; state = $f[0]; running = ($f[1] -eq 'true')
  uptime = $uptime; restartCount = [int]$f[3]; image = $f[4]; health = $f[5]
}
$imageId = $f[6]

# Seconds since this container started. The uptime string above is for reading;
# this is for comparing against a grace period, and parsing "1h 12m" back into a
# number to do it would be inventing a format to immediately regret.
if ($f[1] -eq 'true') { $doc.runSeconds = [int][Math]::Floor($up.TotalSeconds) }

# ------------------------------------------------------------------------ logs
$since = Join-Path $StateDir '.collect-cursor'
$sinceArg = if (Test-Path $since) { (Get-Content $since -Raw).Trim() } else { $null }
$newLog = if ($sinceArg) { Invoke-Docker logs --since $sinceArg $Container } else { Invoke-Docker logs --tail 2000 $Container }
Set-Content -Path $since -Value $collectedAt -NoNewline

$counterFile = Join-Path $StateDir '.blocks-published'
$total = if (Test-Path $counterFile) { [int](Get-Content $counterFile -Raw).Trim() } else { 0 }
$published = @($newLog | Select-String -Pattern 'published block' -SimpleMatch)
$total += $published.Count
Set-Content -Path $counterFile -Value $total -NoNewline

$doc.blocksPublished = $total

# Blocks this container has attempted to build since IT started, which is a
# different question from how many it has won and the only one that catches a
# producer that came up in the non-producing state. Such a node passes /livez
# forever, so it never goes unhealthy, never exits, and no restart policy
# recovers it -- only an operator does.
#
# Counted per run rather than cumulatively: the question is about this launch.
# On a new container the count is re-derived from its start (the log is short by
# definition at that point) and incremented from the usual slice thereafter, so
# the steady-state cost stays one match over the lines already fetched.
$runFile = Join-Path $StateDir '.run-builds'
$prevStarted = ''; $builds = 0
if (Test-Path $runFile) {
  $parts = (Get-Content $runFile -Raw).Trim() -split "`t"
  if ($parts.Count -ge 2) { $prevStarted = $parts[0]; [int]::TryParse($parts[1], [ref]$builds) | Out-Null }
}
if ($prevStarted -ne $f[2]) {
  $builds = @(Invoke-Docker logs --since $f[2] $Container | Select-String -Pattern 'building block').Count
}
else {
  $builds += @($newLog | Select-String -Pattern 'building block').Count
}
Set-Content -Path $runFile -Value ($f[2] + "`t" + $builds) -NoNewline

$doc.buildsThisRun = $builds

# ---------------------------------------------------------------- latency
#
# The producer already measures this. ProducerActor times every stage and the
# status server serves the snapshot on the health port, so this costs one
# request to 127.0.0.1 against in-memory counters — no chain RPC, no work the
# node was not already doing. A dashboard that pinged the gateway itself would
# add load to the shared endpoint this node competes on, to re-derive a number
# the node had already measured on the path that matters.
#
# headFetch runs on every check: its min is the wire floor to the gateway, its
# p50 includes the local parsing and validation on top. The two together are
# what separate a slow network from a slow box.
try {
  $statz = Invoke-RestMethod -Uri "http://127.0.0.1:$HealthPort/statz" -TimeoutSec 2
  $hf = $statz.timings.headFetch
  $cyc = $statz.timings.productionCycle
  if ($null -ne $hf -and $null -ne $hf.p50Ms) {
    # Every field or none: a partial object leaves the page deciding what a
    # missing percentile means.
    $lat = [ordered]@{
      headFetchMinMs = $hf.minMs
      headFetchP50Ms = $hf.p50Ms
      headFetchP95Ms = $hf.p95Ms
      samples        = $hf.count
    }
    if ($null -ne $cyc) { $lat.cycleP50Ms = $cyc.p50Ms; $lat.cycleP95Ms = $cyc.p95Ms }
    # Where a cycle's time goes, out of the same payload already fetched. These
    # stages NEST — a cycle contains the head fetch and the build, the build
    # contains the mempool calls — so the dashboard shows them as durations, not
    # as a waterfall that sums to the cycle.
    $stages = [ordered]@{}
    foreach ($pair in @(@('headFetch', $statz.timings.headFetch),
                        @('blockProduction', $statz.timings.blockProduction),
                        @('mempoolTx', $statz.timings.mempoolPendingTransactionsFetch),
                        @('mempoolBlocks', $statz.timings.mempoolPendingBlocksFetch),
                        @('submit', $statz.timings.mempoolSubmitBlock))) {
      if ($null -ne $pair[1] -and $null -ne $pair[1].p50Ms) { $stages[$pair[0]] = $pair[1].p50Ms }
    }
    if ($stages.Count -gt 0) { $lat.stages = $stages }
    # Whether the node is keeping up, which is what decides whether a slow cycle
    # is a fault or just a characteristic. Same payload, no extra request.
    if ($null -ne $statz.counts) {
      $lat.skippedChecks = $statz.counts.concurrentChecksSkipped
      $lat.rejectedPublishes = $statz.counts.rejectedPublishes
    }
    $doc.latency = $lat
  }
} catch {
  # A wedged or absent status server omits the field. Reporting zero would read
  # as 'instant', which is the one wrong answer available.
}
$doc.errorCount = @($newLog | Select-String -Pattern '\b(error|fatal|unhandled|exception)\b').Count

# ------------------------------------------------------------ candidate race
#
# Why candidates lose, counted from the slice this run already read. $newLog is
# everything since the last cursor, so the counters accumulate 30 seconds at a
# time into a rolling window rather than re-reading an hour of log every run.
#
# The anchor line matters. behind-finalized-head and block-number-mismatch are
# each logged twice — once by the validation viewer, once by the runner — while
# tx-already-finalized is logged once. Counting the bracketed tag would report
# 52 losses where 26 happened. "No candidate block can be appended" is emitted
# exactly once per rejected candidate and carries the tag.
#
# Wins are NOT counted here. "Published block" means submitted, not accepted;
# the dashboard takes wins from the chain scan instead.
$anchors = @($newLog | Select-String -Pattern 'No candidate block can be appended' -SimpleMatch)
# .Contains, not -like: a tag in square brackets is a wildcard character class.
function Measure-Reason([string]$tag) { @($anchors | Where-Object { $_.Line.Contains("[$tag]") }).Count }

$rBuilt = @($newLog | Select-String -Pattern 'Building block \d+$').Count
$rRetry = @($newLog | Select-String -Pattern '(retry' -SimpleMatch).Count
$rTxFin = Measure-Reason 'tx-already-finalized'
$rBehind = Measure-Reason 'behind-finalized-head'
$rMismatch = Measure-Reason 'block-number-mismatch'

$raceFile = Join-Path $StateDir '.race-buckets'
$nowEpoch = [int][double]::Parse((Get-Date -UFormat %s))
Add-Content -Path $raceFile -Value "$nowEpoch $rBuilt $rRetry $rTxFin $rBehind $rMismatch"

$cutoff = $nowEpoch - $RaceWindow
$kept = @()
foreach ($line in (Get-Content $raceFile -ErrorAction SilentlyContinue)) {
  $f = $line -split ' '
  if ($f.Count -eq 6 -and [int]$f[0] -ge $cutoff) { $kept += ,$f }
}
if ($kept.Count -gt 0) {
  # Rewritten whole then moved, so a kill mid-write cannot leave a half-line
  # that poisons every later sum.
  Set-Content -Path "$raceFile.tmp" -Value ($kept | ForEach-Object { $_ -join ' ' })
  Move-Item -Path "$raceFile.tmp" -Destination $raceFile -Force
  $doc.race = [ordered]@{
    windowSeconds   = $RaceWindow
    observedSeconds = $nowEpoch - [int]$kept[0][0]
    built           = ($kept | ForEach-Object { [int]$_[1] } | Measure-Object -Sum).Sum
    retries         = ($kept | ForEach-Object { [int]$_[2] } | Measure-Object -Sum).Sum
    lost            = [ordered]@{
      txAlreadyFinalized  = ($kept | ForEach-Object { [int]$_[3] } | Measure-Object -Sum).Sum
      behindFinalizedHead = ($kept | ForEach-Object { [int]$_[4] } | Measure-Object -Sum).Sum
      blockNumberMismatch = ($kept | ForEach-Object { [int]$_[5] } | Measure-Object -Sum).Sum
    }
  }
}

$lastPub = Join-Path $StateDir '.last-published'
if ($published.Count -gt 0) {
  $blk = ($published[-1].Line | Select-String -Pattern '\d{2,}' -AllMatches).Matches |
         Select-Object -Last 1 -ExpandProperty Value
  Set-Content -Path $lastPub -Value "$collectedAt`t$blk" -NoNewline
}
if (Test-Path $lastPub) {
  $lp = (Get-Content $lastPub -Raw) -split "`t"
  $doc.lastPublishedAt = $lp[0]
  if ($lp.Count -gt 1 -and $lp[1] -match '^\d+$') { $doc.lastPublishedBlock = [int]$lp[1] }
}

# ----------------------------------------------------------------- eligibility
$eligCache = Join-Path $StateDir '.eligibility'
if ((Get-CacheAge $eligCache) -gt 120) {
  $eligLog = (Invoke-Docker logs --since $EligibilityWindow $Container | Out-String).ToLower()
  $key = ''; $reason = ''
  if ($eligLog) {
    # needle -> key, prose. The key is stable; the prose may be reworded.
    $patterns = [ordered]@{
      'insufficient stake'        = 'insufficient-stake|insufficient stake'
      'add stake to contract'     = 'insufficient-stake|insufficient stake - no intent declared'
      'has no balance'            = 'no-balance|no balance'
      'not in the allowed'        = 'not-allowed|not on the allowed-producer list'
      'not an allowed producer'   = 'not-allowed|not on the allowed-producer list'
      'unseasoned'                = 'unseasoned|stake not yet seasoned'
      'insufficient-self-bond'    = 'self-bond|self-bond below the minimum'
      'behind-finalized-head'     = 'too-slow|blocks rejected: built too slowly for the chain'
    }
    foreach ($needle in $patterns.Keys) {
      if ($eligLog.Contains($needle)) { $key, $reason = $patterns[$needle] -split '\|'; break }
    }
    # Only cache a result we actually derived: an empty log means docker logs
    # failed, and caching "no complaint" from that is indistinguishable from a
    # clean read of the one signal that exists because a blocked producer looks
    # healthy from every other angle.
    Set-Content -Path $eligCache -Value "$key`t$reason" -NoNewline
  }
}
if (Test-Path $eligCache) {
  $e = (Get-Content $eligCache -Raw) -split "`t"
  $doc.eligibility = if ($e[0]) {
    [ordered]@{ blocked = $true; key = $e[0]; reason = $e[1]; window = $EligibilityWindow }
  } else {
    [ordered]@{ blocked = $false; window = $EligibilityWindow }
  }
}

# ----------------------------------------------------------------- cli version
# Keyed on the image ID, not on elapsed time: the version can only change when
# the container is recreated, and a cache keyed on the clock reported the old
# version for hours after an upgrade.
$cliCache = Join-Path $StateDir '.cli-version'
$cachedId = ''; $cliVersion = ''
if (Test-Path $cliCache) { $cachedId, $cliVersion = (Get-Content $cliCache -Raw) -split "`t" }
if ($cachedId -ne $imageId -or (Get-CacheAge $cliCache) -gt 21600) {
  $v = (Invoke-Docker exec $Container xl1 --version | Out-String)
  if ($v -match '(\d+\.\d+\.\d+)') {
    $cliVersion = $Matches[1]
    Set-Content -Path $cliCache -Value "$imageId`t$cliVersion" -NoNewline
  }
}
if ($cliVersion) { $doc.cliVersion = $cliVersion }

# ------------------------------------------------------------------- log tail
#
# With timestamps, because every question the panel gets asked is about *when*:
# did it stop an hour ago or a minute ago, is it still attempting a block a
# minute, did that error arrive before the last publish or after it. Without
# them the 40 lines are a wall of text that could be five seconds or five hours
# old.
#
# Docker stamps UTC to nanoseconds -- 2026-08-30T23:41:12.229348397Z -- which is
# too wide for the panel and in the wrong zone. Rewritten to a local HH:mm:ss.
# The stamp's own date is carried through the conversion rather than a fixed
# offset being applied to every line, so the hour stays right either side of a
# DST boundary.
$doc.recentLog = @(
  Invoke-Docker logs --timestamps --tail $LogLines $Container |
    ForEach-Object { "$_" } |
    Where-Object { $_.Trim() } |
    ForEach-Object {
      # Only lines carrying the docker stamp are rewritten. A wrapped line, or
      # an error from docker itself, passes through intact.
      if ($_ -match '^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z (.*)$') {
        $utc = [datetime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3],
                               [int]$Matches[4], [int]$Matches[5], [int]$Matches[6],
                               [DateTimeKind]::Utc)
        '{0:HH:mm:ss} {1}' -f $utc.ToLocalTime(), $Matches[7]
      } else { $_ }
    }
)
$doc.host = Get-HostMetrics

# Validate before publishing, so the dashboard never reads a half-written file.
Write-Json $doc "$Out.tmp"
Move-Item -Force "$Out.tmp" $Out
