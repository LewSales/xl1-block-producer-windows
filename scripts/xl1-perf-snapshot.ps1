<#
.SYNOPSIS
  Read-only performance snapshot: the numbers a before/after comparison needs,
  over one consistent window.

.DESCRIPTION
  The Windows half of the Pi's scripts/xl1-perf-snapshot, with the same fields
  and the same JSON shape, so the two machines can be compared line for line.

  Accepted share comes from the chain (trend.jsonl cblocks against heights), not
  from "Published block" log lines, because published means submitted, not
  accepted. Competitor shares come from the dashboard's peers.json chain scan.
  Producer timings and counters come from the one loopback /statz that the
  collector already reads. Nothing here writes a file or touches the producer's
  work path, and the producer env (which holds the mnemonic) is never read.

  -ProbeEvm times an EVM JSON-RPC endpoint the way the time payload uses it
  (eth_blockNumber then eth_getBlockByNumber, sequentially), so a candidate
  XL1_EVM_RPC_URL can be judged before anyone restarts a producer onto it.

.EXAMPLE
  .\xl1-perf-snapshot.ps1 -Hours 72
  .\xl1-perf-snapshot.ps1 -Hours 72 -Json > before.json
  .\xl1-perf-snapshot.ps1 -ProbeEvm https://ethereum-sepolia-rpc.publicnode.com
#>
[CmdletBinding()]
param(
  [double]$Hours = 24,
  [switch]$Json,
  [string]$ProbeEvm = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$Root       = Split-Path -Parent $PSScriptRoot
$StateDir   = Join-Path $Root 'state'
$TrendFile  = Join-Path $StateDir 'dashboard\trend.jsonl'
$PeersFile  = Join-Path $StateDir 'dashboard\peers.json'
$StatusFile = Join-Path $StateDir 'producer-status.json'
$DashEnv    = Join-Path $Root 'config\dashboard.env'
$HealthPort = if ($env:XL1_HEALTH_HOST_PORT) { $env:XL1_HEALTH_HOST_PORT } else { 9099 }

function Round2([double]$v) { [math]::Round($v, 2) }

# The reward address is public; dashboard.env carries it for the balance panel.
$self = ''
if (Test-Path $DashEnv) {
  $line = Get-Content $DashEnv | Where-Object { $_ -match '^XL1_REWARD_ADDRESS=' } | Select-Object -First 1
  if ($line) { $self = ($line -replace '^XL1_REWARD_ADDRESS=', '' -replace '["'' ]', '').ToLower() -replace '^0x', '' }
}

$out = [ordered]@{
  generatedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  windowHours = $Hours
}

# Accepted share: cblocks is the chain-counted production total, so its delta
# over the height delta is the share of heights this producer actually won.
if (Test-Path $TrendFile) {
  $rows = foreach ($l in [IO.File]::ReadLines($TrendFile)) {
    try { $r = $l | ConvertFrom-Json } catch { continue }
    if ($null -ne $r.t -and $null -ne $r.height -and $null -ne $r.cblocks) { $r }
  }
  $rows = @($rows)
  if ($rows.Count -gt 0) {
    $last  = $rows[-1]
    $cut   = $last.t - $Hours * 3600e3
    $first = $rows | Where-Object { $_.t -ge $cut } | Select-Object -First 1
    $heights = $last.height - $first.height
    $won     = $last.cblocks - $first.cblocks
    $out.accepted = [ordered]@{
      spanHours = Round2 (($last.t - $first.t) / 3.6e6)
      heights   = $heights
      won       = $won
      sharePct  = if ($heights -gt 0) { Round2 (100 * $won / $heights) } else { $null }
    }
  }
}

# Competition from the dashboard's chain scan, over the whole days the window
# covers (peers.json keeps per-day counts, not timestamps).
if (Test-Path $PeersFile) {
  $peers = Get-Content $PeersFile -Raw | ConvertFrom-Json
  if ($null -ne $peers.days) {
    $dayCount = [math]::Max(1, [math]::Ceiling($Hours / 24))
    $days = @($peers.days.PSObject.Properties | Sort-Object Name | Select-Object -Last $dayCount)
    $counts = @{}; $scanned = 0
    foreach ($d in $days) {
      $scanned += $d.Value.scanned
      foreach ($p in $d.Value.counts.PSObject.Properties) {
        if ($counts.ContainsKey($p.Name)) { $counts[$p.Name] += $p.Value } else { $counts[$p.Name] = $p.Value }
      }
    }
    $ranked = @($counts.GetEnumerator() | Sort-Object Value -Descending)
    $comp = [ordered]@{
      days         = @($days | ForEach-Object { $_.Name })
      scanned      = $scanned
      producers    = $ranked.Count
      evenSplitPct = if ($ranked.Count) { Round2 (100 / $ranked.Count) } else { $null }
      shares       = @($ranked | ForEach-Object {
        [ordered]@{ address = $_.Key; won = $_.Value
                    sharePct = if ($scanned) { Round2 (100 * $_.Value / $scanned) } else { $null }
                    self = ($_.Key -eq $self) }
      })
    }
    # The bucket starting at 60 s holds the heartbeat blocks: no transaction
    # arrived, so the chain waited out the 60 s heartbeat interval.
    $g = $peers.gaps
    if ($null -ne $g -and $g.count) {
      $i = [array]::IndexOf(@($g.edges), 60)
      if ($i -ge 0 -and $i -lt @($g.buckets).Count) { $comp.heartbeatSharePct = [math]::Round(100 * $g.buckets[$i] / $g.count, 1) }
    }
    $out.competition = $comp
  }
}

# Producer counters and timings since the actor started.
try {
  $statz = Invoke-RestMethod -Uri "http://127.0.0.1:$HealthPort/statz" -TimeoutSec 2
  $counts = [ordered]@{}
  foreach ($k in 'blockProductionChecks', 'failedChecks', 'concurrentChecksSkipped', 'blockProductionAttempts',
                 'idleAttempts', 'blocksPublished', 'rejectedPublishes', 'candidateRecoveries') {
    $counts[$k] = $statz.counts.$k
  }
  $timings = [ordered]@{}
  foreach ($p in ($statz.timings.PSObject.Properties | Sort-Object Name)) {
    $timings[$p.Name] = [ordered]@{ p50Ms = $p.Value.p50Ms; p95Ms = $p.Value.p95Ms; maxMs = $p.Value.maxMs; count = $p.Value.count }
  }
  $out.statz = [ordered]@{ actorUptimeHours = Round2 ($statz.actorUptimeMs / 3.6e6); counts = $counts; timings = $timings }
} catch {
  # A wedged or absent status server omits the field rather than reporting zeros.
}

if (Test-Path $StatusFile) {
  $status = Get-Content $StatusFile -Raw | ConvertFrom-Json
  $out.race = $status.race
  $out.cliVersion = $status.cliVersion
}

if ($ProbeEvm) {
  function Invoke-Rpc([string]$method, $params) {
    $body = @{ jsonrpc = '2.0'; id = 1; method = $method; params = $params } | ConvertTo-Json -Compress
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri $ProbeEvm -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 4
    return @($sw.Elapsed.TotalMilliseconds, $r.result)
  }
  $samples = @(); $height = $null; $errors = 0
  for ($n = 0; $n -lt 10; $n++) {
    try {
      $a = Invoke-Rpc 'eth_blockNumber' @()
      $b = Invoke-Rpc 'eth_getBlockByNumber' @($a[1], $false)
      $samples += $a[0] + $b[0]
      $height = [Convert]::ToInt64($a[1].Substring(2), 16)
    } catch { $errors++ }
    Start-Sleep -Milliseconds 500
  }
  $sorted = @($samples | Sort-Object)
  $pick = { param($p) if ($sorted.Count) { [math]::Round($sorted[[math]::Min($sorted.Count - 1, [int][math]::Floor($sorted.Count * $p))]) } else { $null } }
  $out.evmProbe = [ordered]@{ url = $ProbeEvm; anchorP50Ms = (& $pick 0.5); anchorP90Ms = (& $pick 0.9); lastHeight = $height; errors = $errors }
}

if ($Json) { $out | ConvertTo-Json -Depth 6; return }

"XL1 perf snapshot  $($out.generatedAt)  window $Hours h  cli $(if ($out.cliVersion) { $out.cliVersion } else { '?' })"
if ($out.accepted) {
  $a = $out.accepted
  "  accepted   $($a.won) of $($a.heights) heights = $($a.sharePct)%  (span $($a.spanHours) h, chain-counted)"
}
if ($out.competition) {
  $c = $out.competition
  $hb = if ($null -ne $c.heartbeatSharePct) { ", heartbeat blocks $($c.heartbeatSharePct)%" } else { '' }
  "  field      $($c.producers) producers, even split $($c.evenSplitPct)%, days $($c.days[0])..$($c.days[-1])$hb"
  foreach ($s in $c.shares) {
    '    {0} {1}...  {2,6}  {3}%' -f $(if ($s.self) { '*' } else { ' ' }), $s.address.Substring(0, 10), $s.won, $s.sharePct
  }
}
if ($out.statz) {
  $k = $out.statz.counts
  "  statz      $($out.statz.actorUptimeHours) h: checks $($k.blockProductionChecks), failed $($k.failedChecks), skipped $($k.concurrentChecksSkipped), published $($k.blocksPublished), rejected $($k.rejectedPublishes), recoveries $($k.candidateRecoveries)"
  foreach ($e in $out.statz.timings.GetEnumerator()) {
    '    {0,-32} p50 {1,5}  p95 {2,5}  max {3,6}  n {4}' -f $e.Key, $e.Value.p50Ms, $e.Value.p95Ms, $e.Value.maxMs, $e.Value.count
  }
}
if ($out.race) {
  $r = $out.race
  $lost = 0; foreach ($p in $r.lost.PSObject.Properties) { $lost += $p.Value }
  "  race 1h    built $($r.built), retries $($r.retries), logged losses $lost"
}
if ($out.evmProbe) {
  $e = $out.evmProbe
  "  evm probe  $($e.url): anchor p50 $($e.anchorP50Ms) ms, p90 $($e.anchorP90Ms) ms, height $($e.lastHeight), errors $($e.errors)/10"
}
