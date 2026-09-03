<#
.SYNOPSIS
  Day-to-day control for the XL1 producer on Windows.

.DESCRIPTION
  The producer itself is run by upstream's compose (upstream/compose/node.yml,
  preset profile). This drives that plus the dashboard, so an operator has one
  command rather than two compose files to remember.

.EXAMPLE
  .\xl1ctl.ps1 status
  .\xl1ctl.ps1 logs -Follow
  .\xl1ctl.ps1 doctor
#>
[CmdletBinding()]
param(
  [Parameter(Position = 0)]
  [ValidateSet('status', 'start', 'stop', 'restart', 'logs', 'addr', 'doctor', 'dashboard', 'backup', 'alert')]
  [string]$Command = 'status',
  [switch]$Follow,
  [switch]$Test,
  [int]$Lines = 60
)

$ErrorActionPreference = 'Stop'
$Root        = Split-Path -Parent $PSScriptRoot
$Upstream    = Join-Path $Root 'upstream\compose\node.yml'
$Tuning      = Join-Path $Root 'compose\producer-tuning.yml'
$Preset      = Join-Path $Root 'presets\roles\producer.json'
$PresetRest  = Join-Path $Root 'presets\roles\producer-rest.json'
$DashCompose = Join-Path $Root 'dashboard.yml'
$ProducerEnv = Join-Path $Root 'config\sequence-producer.env'
$Api         = 'http://127.0.0.1:8088/api/status'

function Say  { param($m, $c = 'Gray') Write-Host "  $m" -ForegroundColor $c }
function Head { param($m) Write-Host ''; Write-Host $m -ForegroundColor White }

function Assert-Docker {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    throw 'docker not found. Install Docker Desktop, then re-run.'
  }
  & docker info 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) { throw 'Docker is installed but not responding. Is Docker Desktop running?' }
}

function Start-Producer {
  # XL1_PRESET_ENV_FILE is resolved relative to the compose file, not the shell.
  $env:XL1_IMAGE = 'xl1:local'
  $env:XL1_PRESET_ENV_FILE = '../../config/sequence-producer.env'
  # ...but a volume path is resolved against the FIRST -f file's directory,
  # which is upstream\compose, not the override that declares it. Absolute,
  # so the mount cannot land somewhere else without saying so.
  $env:XL1_PRODUCER_PRESET = $Preset
  # Both roles are mounted; XL1_ROLE in config\sequence-producer.env picks one.
  $env:XL1_PRODUCER_PRESET_REST = $PresetRest
  if (-not (Test-Path $Preset)) { throw "producer preset missing: $Preset" }
  if (-not (Test-Path $PresetRest)) { throw "producer preset missing: $PresetRest" }
  $up = @('up', '-d', 'preset')
  # The preset arrives as a single-file bind mount, and a WSL-made one is worse
  # here than on the dashboard: when the shim is gone Docker creates a directory
  # where the file should be, and the node will not start at all. Recreate it
  # from Windows paths once, deliberately, rather than at the next reboot.
  if (Test-WslBound (Get-ProducerContainer)) {
    Say 'producer mounts were made from WSL -- recreating from Windows paths' 'Yellow'
    $up = @('up', '-d', '--force-recreate', 'preset')
  }
  & docker compose -f $Upstream -f $Tuning --profile preset @up
}

function Get-Snapshot {
  try { Invoke-RestMethod -Uri $Api -TimeoutSec 6 } catch { $null }
}

function Get-WslBoundContainers {
  # A bind mount made from inside WSL is not the same thing as one made from
  # PowerShell, even when both name the same folder. Docker Desktop reaches a
  # WSL path through a per-distro shim it sets up while that distro is running;
  # a C:\ path it reaches through the permanent drive share. After Docker
  # Desktop restarts, the restart policy brings containers back before WSL is
  # up, the shim is not there, and the mount silently resolves to an empty
  # directory -- the dashboard then reports a collector that is in fact writing
  # every minute, and the producer's preset is simply not there.
  #
  # The tell is the mount source: C:\... was created from Windows, /mnt/c/...
  # from inside WSL. Recreating from PowerShell is what fixes it for good.
  return @(@((Get-ProducerContainer), 'xl1-dashboard') | Where-Object { Test-WslBound $_ })
}

function Test-WslBound {
  param([string]$Container)
  # --format '{{json .Mounts}}' rather than a Go template with a quoted string
  # in it: PowerShell strips the inner quotes on the way to docker.exe, and the
  # template then fails to parse. And an inspect of a container that does not
  # exist writes to stderr, which is a terminating error while EAP is Stop.
  $eap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $json = & docker inspect $Container --format '{{json .Mounts}}' 2>$null
  $ErrorActionPreference = $eap
  if ($LASTEXITCODE -ne 0 -or -not $json) { return $false }
  foreach ($m in @(($json | ConvertFrom-Json))) {
    if ($m -and $m.Type -eq 'bind' -and $m.Source -and $m.Source.StartsWith('/')) { return $true }
  }
  return $false
}

function Get-ProducerContainer {
  $n = (& docker ps -a --filter 'name=preset' --format '{{.Names}}' | Select-Object -First 1)
  if ($n) { return $n }
  return 'xl1-node-preset-1'
}

switch ($Command) {

  'start' {
    Assert-Docker
    if (-not (Test-Path $ProducerEnv)) { throw "$ProducerEnv is missing. Copy the template in config\ and fill it in." }
    Head 'Starting'
    Start-Producer
    # up -d leaves an already-running container alone, which is right unless the
    # thing wrong with it is the mount it was created with. Start-Producer makes
    # the same call for the node.
    $dashUp = @('up', '-d')
    if (Test-WslBound 'xl1-dashboard') {
      Say 'dashboard mounts were made from WSL -- recreating from Windows paths' 'Yellow'
      $dashUp = @('up', '-d', '--force-recreate')
    }
    & docker compose -f $DashCompose @dashUp
    Say 'producer and dashboard started' 'Green'
    Say 'dashboard: http://127.0.0.1:8088'
  }

  'stop' {
    Assert-Docker
    Head 'Stopping'
    $env:XL1_IMAGE = 'xl1:local'
    $env:XL1_PRESET_ENV_FILE = '../../config/sequence-producer.env'
    $env:XL1_PRODUCER_PRESET = $Preset
    $env:XL1_PRODUCER_PRESET_REST = $PresetRest
    & docker compose -f $Upstream -f $Tuning --profile preset stop preset
    & docker compose -f $DashCompose stop
    Say 'stopped' 'Green'
  }

  'restart' {
    Assert-Docker
    Head 'Restarting'
    Start-Producer
    # up --force-recreate, not restart. A restart keeps the container it has,
    # including a bind mount that no longer reaches the host -- which is the one
    # failure the dashboard's own error message tells people to run this for.
    # The dashboard keeps nothing in the container worth preserving; its history
    # is in state\dashboard, on the host side of that mount.
    & docker compose -f $DashCompose up -d --force-recreate
    Say 'restarted' 'Green'
  }

  'logs' {
    Assert-Docker
    $c = Get-ProducerContainer
    if ($Follow) { & docker logs -f --tail $Lines $c } else { & docker logs --tail $Lines $c }
  }

  'dashboard' {
    Head 'Dashboard'
    Say 'http://127.0.0.1:8088'
    Start-Process 'http://127.0.0.1:8088'
  }

  'addr' {
    # The signing address is derived from the mnemonic and is the one that must
    # be authorised on the network. Nothing else in the running system shows it.
    Assert-Docker
    Head 'Addresses'
    $s = Get-Snapshot
    if ($s -and $s.chain.balances.producer) {
      Say ('signs as  {0}' -f $s.chain.balances.producer.address) 'Green'
    }
    if ($s -and $s.chain.balances.reward) {
      Say ('rewards   {0}' -f $s.chain.balances.reward.address)
      Say ('balance   {0} XL1' -f $s.chain.balances.reward.xl1) 'Green'
    }
    if (-not $s) { Say 'dashboard API not responding; cannot resolve addresses' 'Yellow' }
  }

  'backup' {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest  = Join-Path $Root ('xl1-backup-' + $stamp + '.zip')
    Head 'Backup'
    Say 'This archives config\, which contains your seed phrase.' 'Yellow'
    Say 'It is NOT encrypted. Store it where you would store a password.' 'Yellow'
    Compress-Archive -Path (Join-Path $Root 'config\*') -DestinationPath $dest -Force
    Say ('written to ' + $dest) 'Green'
  }

  'alert' {
    # A thin front door onto scripts\xl1-alert.ps1, so the alerter is
    # discoverable from the one command an operator already knows. It reads the
    # dashboard's own /api/status, which is why this says nothing about Docker.
    $alert = Join-Path $PSScriptRoot 'xl1-alert.ps1'
    if (-not (Test-Path $alert)) { Say 'scripts\xl1-alert.ps1 is missing' 'Red'; break }

    if ($Test) {
      Head 'Alert test'
      Say 'Sending one notification through every configured channel.'
      & $alert -Test
    }
    else {
      Head 'Alerts'
      $cfgFile = Join-Path $Root 'config\alert.env'
      if (-not (Test-Path $cfgFile)) {
        Say 'config\alert.env does not exist -- nothing is configured' 'Yellow'
        Say 'Copy config\alert.env.template to config\alert.env and fill in a channel.' 'Yellow'
      }
      # Firing conditions only. Delivery is not re-tried here: this shows what
      # the alerter would say, and sending a copy every time someone looked
      # would make the channel useless.
      & $alert -Status
      Say ''
      Say 'Send a test notification with:  .\xl1ctl.ps1 alert -Test' 'Gray'
    }
  }

  'doctor' {
    Head 'Diagnosis'
    $issues = 0

    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
      Say 'FAIL  docker not installed' 'Red'; $issues++
    }
    else {
      & docker info 2>&1 | Out-Null
      if ($LASTEXITCODE -ne 0) { Say 'FAIL  Docker Desktop is not running' 'Red'; $issues++ }
      else { Say 'ok    Docker responding' 'Green' }
    }

    if (-not (Test-Path $Upstream)) {
      Say 'FAIL  upstream\ is missing. Run Setup.ps1 to fetch xl1-docker-images.' 'Red'; $issues++
    } else { Say 'ok    upstream compose present' 'Green' }

    if (-not (Test-Path $ProducerEnv)) {
      Say 'FAIL  config\sequence-producer.env missing' 'Red'; $issues++
    }
    elseif (-not (Select-String -Path $ProducerEnv -Pattern '^XL1_MNEMONIC=\s*[A-Za-z]' -Quiet)) {
      Say 'FAIL  no mnemonic set -- the producer cannot sign' 'Red'; $issues++
    }
    else { Say 'ok    credentials present' 'Green' }

    $stray = Join-Path $Root 'sequence-producer.env'
    if ((Test-Path $stray) -and ((Get-FileHash $stray).Hash -ne (Get-FileHash $ProducerEnv).Hash)) {
      Say 'FAIL  sequence-producer.env in the project root differs from config\ -- only config\ is read' 'Red'
      $issues++
    }

    $snap = Join-Path $Root 'state\producer-status.json'
    if (-not (Test-Path $snap)) {
      Say 'FAIL  collector has never run. Is the scheduled task installed?' 'Red'; $issues++
    }
    else {
      $age = [int]((Get-Date) - (Get-Item $snap).LastWriteTime).TotalSeconds
      if ($age -gt 120) { Say ('FAIL  collector snapshot is ' + $age + 's old') 'Red'; $issues++ }
      else { Say ('ok    collector fresh (' + $age + 's)') 'Green' }
    }

    # Fine today, broken after the next Docker Desktop restart. Worth failing on
    # while everything still looks healthy, because by the time it matters the
    # symptom is a dashboard blaming a collector that is working perfectly.
    $wsl = @(Get-WslBoundContainers)
    if ($wsl.Count) {
      Say ('FAIL  bind mounts made from WSL: ' + ($wsl -join ', ')) 'Red'
      Say '      they do not survive a Docker Desktop restart -- run xl1ctl restart from PowerShell' 'Red'
      $issues++
    }
    else { Say 'ok    bind mounts created from Windows paths' 'Green' }

    $s = Get-Snapshot
    if (-not $s) { Say 'FAIL  dashboard API not responding' 'Red'; $issues++ }
    else {
      Say 'ok    dashboard responding' 'Green'
      # The two halves of the state directory, checked against each other. The
      # host side above says the collector is writing; this says whether the
      # dashboard can see what it wrote. Both halves report themselves healthy
      # when the mount between them is detached, so only the disagreement finds
      # it.
      if ((Test-Path $snap) -and -not $s.node.ok) {
        Say 'FAIL  the dashboard cannot read the collector snapshot that exists on disk' 'Red'
        Say ('      ' + $s.node.error) 'Red'
        Say '      the state\ bind mount is detached; xl1ctl restart recreates the container' 'Red'
        $issues++
      }
      if ($s.node.eligibility.blocked -and -not $s.node.eligibilityIgnored) {
        Say ('FAIL  producer ineligible: ' + $s.node.eligibility.reason) 'Red'; $issues++
      }
      foreach ($p in $s.problems) { Say ('warn  ' + $p) 'Yellow' }
    }

    Write-Host ''
    if ($issues -eq 0) { Say 'nothing obviously wrong' 'Green' } else { Say ($issues.ToString() + ' problem(s) found') 'Red' }
    exit $(if ($issues -gt 0) { 1 } else { 0 })
  }

  default {
    Assert-Docker
    Head 'Containers'
    & docker ps --filter 'name=preset' --filter 'name=xl1-dashboard' --format 'table {{.Names}}\t{{.Status}}'

    $s = Get-Snapshot
    if (-not $s) { Say 'dashboard API not responding (it may still be starting)' 'Yellow'; break }

    Head 'Producer'
    Say ('state      ' + $s.status) $(if ($s.status -eq 'ok') { 'Green' } else { 'Yellow' })
    foreach ($p in $s.problems) { Say ('  - ' + $p) 'Yellow' }

    Head 'Chain'
    Say ('block      ' + $s.chain.currentBlock + '   finalized ' + $s.chain.finalizedBlock + '   lag ' + $s.chain.finalizationLag)
    if ($s.derived.secondsPerBlock) { Say ('rate       ' + $s.derived.secondsPerBlock + 's/block') }
    # Chain-counted, not log-counted. The collector's blocksPublished greps for
    # "published block", a string xl1-cli does not emit, so it read 0 forever --
    # the same defect the dashboard's headline count was moved off.
    if ($null -ne $s.derived.blocksByWindow.day24h) {
      Say ('won 24h    ' + $s.derived.blocksByWindow.day24h)
    }
    if ($null -ne $s.peers.self.blocks) {
      Say ('won total  ' + $s.peers.self.blocks + '   (' + $s.peers.self.sharePercent + '% of ' + $s.peers.scannedBlocks + ' scanned)')
    }
    if ($s.derived.lastBlock) {
      Say ('last block #' + $s.derived.lastBlock + '  (' + $s.derived.blocksSinceLast + ' blocks ago)') 'Green'
    }
    else { Say 'last block none landed yet' 'Yellow' }

    if ($s.chain.balances.reward) {
      Head 'Rewards'
      Say ('balance    ' + $s.chain.balances.reward.xl1 + ' XL1') 'Green'
    }
  }
}
