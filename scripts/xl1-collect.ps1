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

# Log lines stamped at or after $Since -- a UTC RFC 3339 time, or a duration
# such as '20m' -- read BACKWARD with --tail and filtered here, never with
# `docker logs --since`. --since reads the json-file forward from its first
# entry and stops dead at the first damaged one: an entry broken on 2026-10-13
# at 12:00Z (the laptop sleeping or crashing mid-write) made every --since read
# return nothing for days, buildsThisRun stayed 0, and the alerter paged "never
# built a block" on nodes that were landing blocks. --tail reads from the end,
# so it sees the recent log whatever is wrong further up.
# -Stamped keeps docker's timestamp prefix on each line; without it the
# message alone is returned, as `docker logs` without --timestamps would.
# Docker's stamped lines back in the order they were written. `docker logs`
# sends the container's stdout and stderr on separate streams, and PowerShell
# 5.1's 2>&1 does not keep them interleaved: stderr arrives in batches after
# the stdout around it. xl1-cli writes "Generated time payload" to stderr and
# "Building block" to stdout, so in arrival order the payload time preceded
# its build on about 2% of height rows (6-7 of 360 on 2026-10-22) and the rest
# had none. Docker stamps each line with nanoseconds but drops trailing zeros,
# so the fraction is padded before comparing; equal stamps keep arrival order.
# [Array]::Sort on precomputed keys, not Sort-Object: 8000 lines took ~1.3 s
# the pipeline way, for each of four containers in a 30 s cycle.
function Sort-LogStamped {
  param([string[]]$Lines)
  if (-not $Lines) { return }
  $keys = New-Object string[] $Lines.Count
  for ($i = 0; $i -lt $Lines.Count; $i++) {
    $stamp = if ($Lines[$i] -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d+))?Z ') {
      $Matches[1] + '.' + "$($Matches[2])".PadRight(9, '0').Substring(0, 9)
    } else { '' }
    # The arrival index makes every key unique, so the unstable sort is deterministic.
    $keys[$i] = $stamp + '|' + $i.ToString('D7')
  }
  $sorted = [string[]]$Lines.Clone()
  [Array]::Sort($keys, $sorted, [StringComparer]::Ordinal)
  $sorted
}

function Get-LogSince {
  param([string]$Since, [int]$Tail = 5000, [switch]$Stamped, [string]$Name = '')
  $target = if ($Name) { $Name } else { $Container }
  $cut = if ($Since -match '^(\d+)([smh])$') {
    $span = @{ s = 'FromSeconds'; m = 'FromMinutes'; h = 'FromHours' }[$Matches[2]]
    (Get-Date).ToUniversalTime().Subtract([timespan]::$span([double]$Matches[1])).ToString('yyyy-MM-ddTHH:mm:ss')
  } else { $Since.Substring(0, [Math]::Min(19, $Since.Length)) }
  $lines = @(Invoke-Docker logs --timestamps --tail $Tail $target | ForEach-Object { "$_" } | Where-Object {
    $_ -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})\S*Z ' -and [string]::CompareOrdinal($Matches[1], $cut) -ge 0
  })
  Sort-LogStamped $lines | ForEach-Object { if ($Stamped) { $_ } else { $_ -replace '^\S+Z ', '' } }
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
  # Compact: only the dashboard reads this file, and the per-height rows made the
  # indented form ten times the size of the data in it.
  $json = $Object | ConvertTo-Json -Depth 7 -Compress
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

# `docker ps --filter name=preset` only ever needs to run again when the
# producer container is actually recreated under a new preset index -- an
# operator-driven event, not a per-cycle one -- so the resolved name is cached
# and only re-derived below if the inspect that follows fails against it.
$autoResolved = -not $Container
function Resolve-ProducerContainer {
  $found = (Invoke-Docker ps -a --filter 'name=preset' --format '{{.Names}}' | Select-Object -First 1)
  if ($found) { $found } else { 'xl1-node-preset-1' }
}
$containerCacheFile = Join-Path $StateDir '.container-name'
if ($autoResolved) {
  $Container = if (Test-Path $containerCacheFile) { (Get-Content $containerCacheFile -Raw).Trim() } else { '' }
  if (-not $Container) { $Container = Resolve-ProducerContainer }
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

$inspectFormat = '{{.State.Status}}|{{.State.Running}}|{{.State.StartedAt}}|{{.RestartCount}}|{{.Config.Image}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.Image}}'
$inspect = Invoke-Docker inspect $Container --format $inspectFormat 2>$null

if (($LASTEXITCODE -ne 0 -or -not $inspect) -and $autoResolved) {
  # The cached name goes stale exactly once, the cycle the producer container
  # is recreated under a new preset index -- re-resolve before reporting an
  # outage that is really just a rename.
  $reresolved = Resolve-ProducerContainer
  if ($reresolved -ne $Container) {
    $Container = $reresolved
    $inspect = Invoke-Docker inspect $Container --format $inspectFormat 2>$null
  }
}

if ($LASTEXITCODE -ne 0 -or -not $inspect) {
  # A container that does not exist is a first-class state, not a missing field.
  $doc.container = $null
  $doc.error     = "container $Container not found"
  $doc.host      = Get-HostMetrics
  Write-Json $doc "$Out.tmp"
  Move-Item -Force "$Out.tmp" $Out
  exit 0
}

if ($autoResolved) { Set-Content -Path $containerCacheFile -Value $Container -NoNewline }

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
# --timestamps here, once, rather than in a second `docker logs` call later
# purely to stamp the recent-log panel -- that used to cost a second CLI
# process and Engine API round trip every single cycle, forever.
$rawNewLog = @(
  $(if ($sinceArg) { Get-LogSince $sinceArg -Stamped } else { Sort-LogStamped @(Invoke-Docker logs --timestamps --tail 2000 $Container | ForEach-Object { "$_" }) }) |
    ForEach-Object { "$_" }
)
Set-Content -Path $since -Value $collectedAt -NoNewline

# Everything below only ever matched on the message, not the stamp just added
# above -- strip it back off once here rather than teaching every pattern a
# second shape.
$tsPattern = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z (.*)$'
$newLog = @($rawNewLog | ForEach-Object { if ($_ -match $tsPattern) { $Matches[1] } else { $_ } })

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
  # Once per container start, so a deeper read is affordable here; the answer
  # that matters is whether it is zero.
  $builds = @(Get-LogSince $f[2] -Tail 20000 | Select-String -Pattern 'building block').Count
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
                        @('submit', $statz.timings.mempoolSubmitBlock),
                        # xl1-cli 5.5.0+ also times the time payload (two sequential
                        # Sepolia calls for the EVM anchor, the largest measured step on
                        # the producing path) and the reward diviner. Older CLIs omit
                        # both keys and the stages simply drop out.
                        @('timePayload', $statz.timings.timePayloadGeneration),
                        @('rewardTransfers', $statz.timings.blockRewardTransfers))) {
      if ($null -ne $pair[1] -and $null -ne $pair[1].p50Ms) { $stages[$pair[0]] = $pair[1].p50Ms }
    }
    if ($stages.Count -gt 0) { $lat.stages = $stages }
    $tp = $statz.timings.timePayloadGeneration
    if ($null -ne $tp -and $null -ne $tp.p95Ms) { $lat.timePayloadP95Ms = $tp.p95Ms }
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
  $eligLog = (Get-LogSince $EligibilityWindow | Out-String).ToLower()
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
#
# The lines come from a small rolling buffer kept on disk, topped up from
# $rawNewLog above -- which already carries every line that has arrived since
# the last cycle, timestamps included -- rather than a second `docker logs
# --tail` fetch every cycle.
$logBufferFile = Join-Path $StateDir '.recent-log'
$bufferedLines = @(if (Test-Path $logBufferFile) { Get-Content $logBufferFile } else { @() })
$combinedLines = @($bufferedLines + @($rawNewLog | Where-Object { $_.Trim() }))
if ($combinedLines.Count -lt $LogLines) {
  # Only reachable right after this buffer is first introduced, right after a
  # state wipe, or after a quiet spell longer than the buffer's own history --
  # a cold start earns one extra fetch rather than shipping a half-full panel.
  $combinedLines = @(Invoke-Docker logs --timestamps --tail $LogLines $Container | ForEach-Object { "$_" } | Where-Object { $_.Trim() })
}
$recentLines = @($combinedLines | Select-Object -Last $LogLines)
Set-Content -Path $logBufferFile -Value $recentLines

$doc.recentLog = @(
  $recentLines | ForEach-Object {
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
# ------------------------------------------------------------------ os updates
#
# The same three figures the Pi reports, so one dashboard card reads both nodes.
# Windows had none of this, which is worse than it sounds: the Pi spent nine days
# reporting "0 updates" off stale lists and the staleness figure is what exposed
# it. A node that reports nothing cannot be caught that way at all.
#
# The count is only meaningful next to the age of the scan that produced it, so
# both are emitted or neither is.
$osCache = Join-Path $StateDir '.os-updates'
# 6h normally, 15m while something is pending -- the same cadence as the Pi. A
# host that was just patched should say so within minutes, not at the end of a
# six-hour cache.
$osPending = $false
if (Test-Path $osCache) {
  $prev = (Get-Content $osCache -Raw) -split "`t"
  $osPending = ($prev[0] -ne '0') -or ($prev[2] -eq 'True')
}
$osInterval = if ($osPending) { 900 } else { 21600 }

if ((Get-CacheAge $osCache) -gt $osInterval) {
  try {
    # Searching is slow and hits the network, which is why it happens on a long
    # cache rather than every collector run.
    $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
    $found    = $searcher.Search('IsInstalled=0 and IsHidden=0').Updates
    $total    = @($found).Count
    # Severity is set on security updates and empty on drivers and feature
    # updates, which is the distinction worth surfacing on a producing node.
    $sec      = @($found | Where-Object { $_.MsrcSeverity }).Count

    # Any one of these means a reboot is owed. Checked together because Windows
    # records them in different places depending on what asked for it.
    $rebootKeys = @(
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    $reboot = [bool](@($rebootKeys | Where-Object { Test-Path $_ }).Count)

    Set-Content -Path $osCache -Value "$total`t$sec`t$reboot" -NoNewline
  } catch {
    # A failed search must not overwrite a good previous answer with a zero.
    # "0 updates" read off a search that never ran is the exact failure this is
    # here to prevent.
    if (-not (Test-Path $osCache)) { Set-Content -Path $osCache -Value "`t`t" -NoNewline }
  }
}

if (Test-Path $osCache) {
  $u, $sv, $rb = (Get-Content $osCache -Raw) -split "`t"
  if ($u -ne '') {
    $os = [ordered]@{
      updates          = [int]$u
      securityUpdates  = [int]$sv
      rebootRequired   = ($rb -eq 'True')
    }
    # How old the scan behind those numbers is.
    #
    # Taken from the cache file's own timestamp, not from the registry: the
    # Results\Detect key modern Windows is supposed to write does not exist on
    # this host, and an age that is silently absent is worse than none -- the
    # dashboard's staleness check simply never fires and a stale zero looks
    # exactly like a fresh one.
    #
    # The file is only rewritten when a search SUCCEEDS, so this is the age of
    # the last good answer. A host that has failed to search for a week reports
    # a week, which is the number that matters.
    $os.updatesAgeHours = [math]::Round((Get-CacheAge $osCache) / 3600, 1)
    $doc.os = $os
  }
}

# ---------------------------------------------------------------------- clock
#
# Whether this machine's timestamps can be compared with another host's. Race
# arrival times are only as good as the clock that stamped them, and Windows
# Time polls rarely -- 32768 s (about nine hours) measured on this host -- so the
# last sync is reported beside a measured offset rather than "synced" assumed.
# One NTP sample is a network round trip, so this is cached for ten minutes.
$clockCache = Join-Path $StateDir '.clock'
if ((Get-CacheAge $clockCache) -gt 600) {
  $prevPref = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $st = (& w32tm /query /status 2>&1 | Out-String)
    $clk = [ordered]@{ checkedAt = $collectedAt }
    if ($st -match 'Source:\s*(\S+)') { $clk.source = ($Matches[1] -replace ',0x\w+$', '') }
    if ($st -match 'Stratum:\s*(\d+)') { $clk.stratum = [int]$Matches[1] }
    if ($st -match 'Root Dispersion:\s*([\d.]+)s') { $clk.rootDispersionMs = [math]::Round([double]$Matches[1] * 1000) }
    if ($st -match 'Poll Interval:\s*\d+\s*\((\d+)s\)') { $clk.pollIntervalSeconds = [int]$Matches[1] }
    if ($st -match 'Last Successful Sync Time:\s*(.+)') {
      try { $clk.lastSyncAt = ([datetime]::Parse($Matches[1].Trim())).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') } catch { }
    }
    # A free-running clock has nothing to be synced to; say so instead of measuring.
    $hasSource = $clk.source -and $clk.source -notmatch 'Local|Free-running|CMOS'
    $clk.synced = [bool]($hasSource -and $clk.lastSyncAt)
    $peer = if ($hasSource) { $clk.source } else { 'time.windows.com' }
    $sc = (& w32tm /stripchart /computer:$peer /samples:1 /dataonly 2>&1 | Out-String)
    if ($sc -match ',\s*([+-]\d+\.\d+)s') { $clk.offsetMs = [math]::Round([double]$Matches[1] * 1000, 1); $clk.offsetAgainst = $peer }
    Set-Content -Path $clockCache -Value ($clk | ConvertTo-Json -Compress) -NoNewline
  } catch { } finally { $ErrorActionPreference = $prevPref }
}
if (Test-Path $clockCache) { try { $doc.clock = Get-Content $clockCache -Raw | ConvertFrom-Json } catch { } }

# ------------------------------------------------------- every local producer
#
# This host runs more than one producer, and everything above describes one of
# them. A producer nobody has a panel for is one nobody is watching -- that is
# how a Mainnet key ran for days building candidates and winning none. Each gets
# the same few counters from its own log, every five minutes.
#
# Wins are NOT counted here, for the same reason as in the race section: the
# chain decides those, and the oxyon.io race view reports them. Only the network
# and the reward address are read from each container's environment, and they
# are picked out by the template itself, so a recovery phrase in the same
# environment never leaves Docker.
$fleetCache = Join-Path $StateDir '.local-producers'
if ((Get-CacheAge $fleetCache) -gt 300) {
  $rows = @()
  $names = @(Invoke-Docker ps -a --filter 'name=preset' --format '{{.Names}}' | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  # Backtick strings, not double quotes: PowerShell 5.1 strips embedded double
  # quotes when it hands an argument to a native program, and the template then
  # matches nothing.
  $envTpl = '{{range .Config.Env}}{{if or (eq (index (split . `=`) 0) `XL1_NETWORK`) (eq (index (split . `=`) 0) `XL1_REWARD_ADDRESS`)}}{{println .}}{{end}}{{end}}'
  foreach ($n in $names) {
    $i = Invoke-Docker inspect $n --format '{{.State.Status}}|{{.State.Running}}|{{.State.StartedAt}}|{{.RestartCount}}'
    if ($LASTEXITCODE -ne 0 -or -not $i) { continue }
    $p = "$i".Trim() -split '\|'
    $envLines = @(Invoke-Docker inspect $n --format $envTpl | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    $net = "$($envLines | Where-Object { $_ -like 'XL1_NETWORK=*' } | Select-Object -First 1)" -replace '^XL1_NETWORK=', ''
    $reward = "$($envLines | Where-Object { $_ -like 'XL1_REWARD_ADDRESS=*' } | Select-Object -First 1)" -replace '^XL1_REWARD_ADDRESS=(0x)?', ''
    $raw = @(Get-LogSince '1h' -Tail 8000 -Name $n -Stamped)
    $msg = @($raw | ForEach-Object { $_ -replace '^\S+Z ', '' })
    $row = [ordered]@{
      # main-653e, seq-23b3, node: the container name without its compose wrapping.
      id                 = ($n -replace '^xl1-', '' -replace '-preset-\d+$', '')
      network            = $(if ($net) { $net } else { $null })
      rewardAddress      = $(if ($reward -match '^[0-9a-fA-F]{40}$') { $reward.ToLower() } else { $null })
      state              = $p[0]
      running            = ($p[1] -eq 'true')
      startedAt          = $p[2]
      restartCount       = [int]$p[3]
      windowSeconds      = 3600
      builds             = @($msg | Where-Object { $_ -match 'Building block \d+$' }).Count
      retries            = @($msg | Where-Object { $_ -match 'Building block \d+ \(retry' }).Count
      validationFailures = @($msg | Where-Object { $_ -like '*Block validation failed*' }).Count
      rejected           = @($msg | Where-Object { $_ -like '*No candidate block can be appended*' }).Count
    }
    $tp = @($msg | ForEach-Object { if ($_ -match 'Generated time payload in (\d+)ms') { [int]$Matches[1] } } | Sort-Object)
    if ($tp.Count) {
      $row.timePayloadP50Ms = $tp[[int][Math]::Floor($tp.Count * 0.5)]
      $row.timePayloadP95Ms = $tp[[Math]::Min($tp.Count - 1, [int][Math]::Floor($tp.Count * 0.95))]
    }
    $lb = $raw | Where-Object { $_ -match 'Building block \d+' } | Select-Object -Last 1
    if ($lb -and $lb -match '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})') { $row.lastBuildAt = "$($Matches[1])Z" }

    # One row per height this producer attempted, newest last: when it started
    # building (this host's clock), how many retries, how many validation
    # failures and rejections, and how long the time payload before it took.
    # oxyon.io joins these to the chain and the race observer by (network,
    # height, producer) to say why a height was lost. Bounded to the last 360.
    $byN = [ordered]@{}; $cur = $null; $tpLast = $null
    foreach ($line in $raw) {
      if ($line -notmatch '^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?)Z (.*)$') { continue }
      $stamp = $Matches[1]; $text = $Matches[2]
      if ($text -match 'Generated time payload in (\d+)ms') { $tpLast = [int]$Matches[1]; continue }
      if ($text -match 'Building block (\d+)( \(retry (\d+)\))?$') {
        $n = $Matches[1]
        if (-not $byN.Contains($n)) {
          $at = [DateTimeOffset]::Parse("${stamp}Z").ToUnixTimeMilliseconds()
          $byN[$n] = @([long]$n, [long]$at, 0, 0, 0, $tpLast)
        }
        if ($Matches[3]) { $byN[$n][2] = [Math]::Max([int]$byN[$n][2], [int]$Matches[3]) }
        $cur = $n; $tpLast = $null; continue
      }
      if ($cur -and $text -like '*Block validation failed*') { $byN[$cur][3] = [int]$byN[$cur][3] + 1; continue }
      if ($cur -and $text -like '*No candidate block can be appended*') { $byN[$cur][4] = [int]$byN[$cur][4] + 1 }
    }
    $hr = @($byN.Values)
    if ($hr.Count) {
      $row.heights = [ordered]@{
        columns = @('n', 'buildAt', 'retries', 'validationFailures', 'rejected', 'timePayloadMs')
        rows    = [object[]]@($hr | Select-Object -Last 360 | ForEach-Object { ,([object[]]$_) })
      }
    }
    $rows += ,$row
  }
  # Only cache an answer docker actually gave: an empty list from a failed `ps`
  # would read as "this host runs no producers".
  if ($names.Count) { Set-Content -Path $fleetCache -Value (ConvertTo-Json -InputObject @($rows) -Depth 4 -Compress) -NoNewline }
}
if (Test-Path $fleetCache) {
  try {
    # Rebuilt as plain ordered maps: an array read back by ConvertFrom-Json and
    # written again under PowerShell 5.1 serialises as {"value":[...],"Count":n}.
    $doc.localProducers = [object[]]@(Get-Content $fleetCache -Raw | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object {
      $h = [ordered]@{}; foreach ($pr in $_.PSObject.Properties) { $h[$pr.Name] = $pr.Value }; $h
    })
  } catch { }
}

$doc.host = Get-HostMetrics

# Validate before publishing, so the dashboard never reads a half-written file.
Write-Json $doc "$Out.tmp"
Move-Item -Force "$Out.tmp" $Out
