<#
.SYNOPSIS
  Tell someone when the producer's state changes.

.DESCRIPTION
  The Windows half of the Pi's scripts/xl1-alert.sh, and deliberately the same
  program: same conditions, same keys, same transition rules, same state file
  format. Two alerters that disagreed about what "degraded" means would be worse
  than one, and an operator running both machines should not have to learn the
  difference.

  Reads the dashboard's own /api/status rather than re-deriving anything. The
  dashboard already reconciles four sources and decides what each of them means;
  a second opinion is a second thing to keep correct.

  Fires on transitions, not on conditions. A node that has been ineligible for a
  week should say so once, not every minute -- an alert channel that cries every
  minute is one nobody reads, which is the same as having no alerts.

    config\alert.env      configuration (see alert.env.template)
    "XL1 Alerter"         scheduled task, runs this every 60s

.EXAMPLE
  .\xl1-alert.ps1 -Test      send a test notification through every channel
  .\xl1-alert.ps1 -Status    show what is currently firing, send nothing
#>
[CmdletBinding()]
param(
  [switch]$Test,
  [switch]$Status
)

# Not 'Stop'. Every delivery below is best-effort by design, and a webhook that
# is refusing connections must not stop the run before the state file is written
# -- that would re-fire every condition at full priority on the next pass.
$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Root     = Split-Path -Parent $PSScriptRoot
$StateDir = Join-Path $Root 'state'
$EnvFile  = if ($env:XL1_ALERT_ENV) { $env:XL1_ALERT_ENV } else { Join-Path $Root 'config\alert.env' }

# ------------------------------------------------------------------- config
#
# The same KEY=VALUE file the Pi sources into its environment. Parsed rather
# than executed: this is configuration, and a config file that can run commands
# is a config file that eventually does.
function Import-EnvFile {
  param([string]$Path)
  $map = @{}
  if (-not (Test-Path $Path)) { return $map }
  foreach ($line in Get-Content -Path $Path) {
    $t = $line.Trim()
    if ($t -eq '' -or $t.StartsWith('#')) { continue }
    $i = $t.IndexOf('=')
    if ($i -lt 1) { continue }
    $k = $t.Substring(0, $i).Trim()
    $v = $t.Substring($i + 1).Trim()
    # Values may be quoted for the shell's benefit on the Pi side; the quotes
    # are the shell's, not the value's.
    if ($v.Length -ge 2 -and (($v[0] -eq '"' -and $v[-1] -eq '"') -or ($v[0] -eq "'" -and $v[-1] -eq "'"))) {
      $v = $v.Substring(1, $v.Length - 2)
    }
    $map[$k] = $v
  }
  return $map
}

$cfg = Import-EnvFile $EnvFile
# Environment wins over the file, so a scheduled task or a one-off shell can
# override without editing operator config.
function Setting {
  param([string]$Name, $Default = '')
  $fromEnv = [Environment]::GetEnvironmentVariable($Name)
  if ($fromEnv) { return $fromEnv }
  if ($cfg.ContainsKey($Name) -and $cfg[$Name] -ne '') { return $cfg[$Name] }
  return $Default
}
function SettingInt {
  param([string]$Name, [int]$Default)
  $raw = Setting $Name ''
  $n = 0
  if ([int]::TryParse($raw, [ref]$n)) { return $n }
  return $Default
}

$Url          = Setting 'XL1_ALERT_URL' 'http://127.0.0.1:8088/api/status'
$Token        = Setting 'XL1_ALERT_TOKEN' ''
$StateFile    = Setting 'XL1_ALERT_STATE' (Join-Path $StateDir '.alert-state')
$Cooldown     = SettingInt 'XL1_ALERT_COOLDOWN' 21600
$StallBlocks  = SettingInt 'XL1_ALERT_STALL_BLOCKS' 90
$LaunchGrace  = SettingInt 'XL1_ALERT_LAUNCH_GRACE' 900
$NodeName     = Setting 'XL1_ALERT_NAME' $env:COMPUTERNAME
$DeadmanUrl   = Setting 'XL1_ALERT_DEADMAN_URL' ''
$NtfyTopic    = Setting 'XL1_ALERT_NTFY_TOPIC' ''
$NtfyServer   = (Setting 'XL1_ALERT_NTFY_SERVER' 'https://ntfy.sh').TrimEnd('/')
$Webhook      = Setting 'XL1_ALERT_WEBHOOK' ''
$Email        = Setting 'XL1_ALERT_EMAIL' ''
$SmtpServer   = Setting 'XL1_ALERT_SMTP_SERVER' ''
$SmtpPort     = SettingInt 'XL1_ALERT_SMTP_PORT' 587
$SmtpFrom     = Setting 'XL1_ALERT_SMTP_FROM' ''
$SmtpUser     = Setting 'XL1_ALERT_SMTP_USER' ''
$SmtpPass     = Setting 'XL1_ALERT_SMTP_PASS' ''

# TLS 1.2 is not the default under Windows PowerShell 5.1, and ntfy.sh and every
# webhook endpoint worth using refuse anything older. Without this line the only
# symptom is "the underlying connection was closed" against a service that is
# perfectly healthy.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# ------------------------------------------------------------------- delivery

# A log that survives the run, because a scheduled task's console goes nowhere.
# Capped rather than rotated: this is a diary of transitions, not a log of work.
function Write-AlertLog {
  param([string]$Line)
  try {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $f = Join-Path $StateDir '.alert-log'
    Add-Content -Path $f -Value ("{0}  {1}" -f (Get-Date -Format 'o'), $Line)
    $lines = @(Get-Content -Path $f -ErrorAction SilentlyContinue)
    if ($lines.Count -gt 500) { Set-Content -Path $f -Value $lines[-500..-1] }
  } catch {}
}

function Send-Alert {
  param([string]$Priority, [string]$Title, [string]$Body)
  $sent = 0

  if ($NtfyTopic) {
    # ntfy needs no account and pushes to a phone app, which is why it is the
    # channel documented first. Tags drive the icon shown on the phone.
    $tag = switch ($Priority) {
      'urgent'  { 'rotating_light' }
      'high'    { 'rotating_light' }
      default   { 'warning' }
    }
    try {
      Invoke-RestMethod -Uri "$NtfyServer/$NtfyTopic" -Method Post -TimeoutSec 15 `
        -Headers @{ Title = $Title; Priority = $Priority; Tags = $tag } `
        -Body ([Text.Encoding]::UTF8.GetBytes($Body)) | Out-Null
      $sent = 1
    } catch { Write-AlertLog "ntfy failed: $($_.Exception.Message)" }
  }

  if ($Webhook) {
    # Both Slack and Discord accept a bare content/text body, so one payload
    # carrying both keys works on either without configuration.
    $text = "$Title`n$Body"
    $json = @{ content = $text; text = $text } | ConvertTo-Json -Compress
    try {
      Invoke-RestMethod -Uri $Webhook -Method Post -TimeoutSec 15 `
        -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($json)) | Out-Null
      $sent = 1
    } catch { Write-AlertLog "webhook failed: $($_.Exception.Message)" }
  }

  if ($Email) {
    # Windows has no sendmail to fall back on, so unlike the Pi this needs a
    # relay named outright. Said plainly rather than failing quietly, because a
    # configured address that never delivers is worse than an empty one.
    if (-not $SmtpServer) {
      Write-AlertLog 'XL1_ALERT_EMAIL is set but XL1_ALERT_SMTP_SERVER is empty — no mail sent'
    }
    else {
      try {
        $from = if ($SmtpFrom) { $SmtpFrom } else { $Email }
        $params = @{
          To = $Email; From = $from
          Subject = $Title; Body = $Body; SmtpServer = $SmtpServer; Port = $SmtpPort
          UseSsl = $true; ErrorAction = 'Stop'
        }
        if ($SmtpUser) {
          $sec = ConvertTo-SecureString $SmtpPass -AsPlainText -Force
          $params.Credential = New-Object Management.Automation.PSCredential($SmtpUser, $sec)
        }
        # Obsolete since PowerShell 6 and still the only thing in the box. The
        # alternative is a third-party module this bundle would then have to
        # install and keep current on a machine whose job is producing blocks.
        Send-MailMessage @params
        $sent = 1
      } catch { Write-AlertLog "email failed: $($_.Exception.Message)" }
    }
  }

  if (-not $sent) { Write-Warning "xl1-alert: no channel delivered: $Title" }
  Write-AlertLog "$Priority`: $Title -- $Body"
}

# ------------------------------------------------------------- what is true

# jq's `//` operator, which every predicate below depends on. Walking the path
# by hand rather than trusting property access: a missing intermediate is the
# normal case here (no node.os on Windows, no system.throttle off a Pi) and it
# has to read as "absent", never as an error and never as false-by-accident.
function Field {
  param($Obj, [string]$Path, $Default = $null)
  $cur = $Obj
  foreach ($part in $Path.Split('.')) {
    if ($null -eq $cur) { return $Default }
    $prop = $cur.PSObject.Properties[$part]
    if (-not $prop) { return $Default }
    $cur = $prop.Value
  }
  if ($null -eq $cur) { return $Default }
  return $cur
}

$fetchUrl = if ($Token) { "$Url`?token=$Token" } else { $Url }
$json = $null
try {
  $json = Invoke-RestMethod -Uri $fetchUrl -TimeoutSec 20 -UseBasicParsing
} catch {
  $json = $null
}

# The dashboard being unreachable is itself worth reporting -- but only from a
# host that is up enough to run this, so it means the dashboard died, not the
# machine. A dead machine cannot report anything, which is what the dead-man
# switch is for and this deliberately is not.
$readable = $true
$conditions = New-Object System.Collections.Generic.List[object]
function Add-Condition {
  param([string]$Key, [string]$Priority, [string]$Message)
  $conditions.Add([pscustomobject]@{ key = $Key; prio = $Priority; msg = $Message })
}

# Valid JSON is not the same as *our* JSON. Every predicate below defaults to
# "nothing wrong" when a field is missing, so a 200 carrying an unexpected shape
# -- a renamed field, an error object -- would read as healthy forever. Require
# the one field whose vocabulary we control.
$docStatus = Field $json 'status'
if ($null -eq $json) {
  $readable = $false
  Add-Condition 'dashboard-unreachable' 'high' "Dashboard API did not answer at $Url"
}
elseif ($docStatus -notin @('ok', 'degraded', 'down')) {
  $readable = $false
  Add-Condition 'alerter-broken' 'high' "Status document from $Url is not in the expected shape"
}
else {
  if ($docStatus -eq 'down') { Add-Condition 'node-down' 'urgent' 'Producer is DOWN' }

  $nodeOk = Field $json 'node.ok' $false
  $hasContainer = $null -ne (Field $json 'node.container')
  if ($nodeOk -and -not $hasContainer) {
    Add-Condition 'container-missing' 'urgent' 'Producer container does not exist'
  }
  $running = Field $json 'node.container.running'
  if ($running -eq $false) {
    Add-Condition 'container-stopped' 'urgent' 'Producer container is not running'
  }
  if (-not (Field $json 'node.ok' $true)) {
    Add-Condition 'collector-down' 'high' ("Collector is not reporting: " + (Field $json 'node.error' 'unknown'))
  }
  if ((Field $json 'node.eligibility.blocked' $false) -and -not (Field $json 'node.eligibilityIgnored' $false)) {
    Add-Condition 'ineligible' 'high' ("Producer cannot produce: " + (Field $json 'node.eligibility.reason' 'unknown'))
  }
  if (-not (Field $json 'health.ok' $true)) {
    Add-Condition 'health-failing' 'high' 'Health probe /livez is failing'
  }
  if (-not (Field $json 'chain.ok' $true)) {
    Add-Condition 'chain-unreachable' 'high' 'Chain gateway unreachable'
  }
  if (Field $json 'node.stale' $false) {
    Add-Condition 'collector-stale' 'default' 'Collector snapshot is stale'
  }
  if ((Field $json 'release.lag') -eq 'behind') {
    Add-Condition 'cli-behind' 'default' ("xl1-cli " + (Field $json 'release.installed' '?') +
      " is behind published " + (Field $json 'release.latest' '?'))
  }
  if ((Field $json 'system.swap.usedPercent' 0) -gt 60) {
    Add-Condition 'swapping' 'default' 'Heavy swap use — this machine is short of RAM'
  }

  # The Pi's undervoltage, hard-throttle and thermal rules have no analogue
  # here, and neither do its apt ones: both read fields the Windows collector
  # cannot write. Left out rather than left in to never fire, so this file lists
  # only conditions this machine can actually reach.

  # A producer that never entered production on this launch, as distinct from
  # one that is producing and losing. It cannot recover on its own -- /livez
  # passes on a node that has never built a block, so the container is never
  # unhealthy, never exits, and no restart policy fires. Only an operator
  # restarting it clears this, which is exactly why it pages.
  #
  # Guarded on the container actually running, so a stopped container reports
  # container-stopped and not this.
  $runSeconds = [double](Field $json 'node.runSeconds' 0)
  $buildsThisRun = [double](Field $json 'node.buildsThisRun' 1)
  if ($LaunchGrace -gt 0 -and (Field $json 'node.container.running' $false) `
      -and $runSeconds -gt $LaunchGrace -and $buildsThisRun -eq 0) {
    Add-Condition 'never-produced' 'urgent' ("Producer has been up " + [int][Math]::Floor($runSeconds / 60) +
      " min and has never built a block — it came up in the non-producing state and will not recover without a restart")
  }

  # The one every other check here misses. A node can be up, /livez green, chain
  # reachable, log clean, and simply lose every race. Not producing is the only
  # symptom that failure has, and it is the one that costs money.
  #
  # Counted from the chain, not from the log: a node can submit all day without
  # a single block being accepted.
  $sinceLast = [double](Field $json 'derived.blocksSinceLast' 0)
  if ($StallBlocks -gt 0 -and $sinceLast -gt $StallBlocks) {
    $spb = [double](Field $json 'derived.secondsPerBlock' 57)
    Add-Condition 'not-producing' 'high' ("No block counted in " + [int]$sinceLast + " chain blocks (~" +
      [int][Math]::Floor(($sinceLast * $spb) / 60) + " min) — the node looks healthy but is not landing anything")
  }
}

if ($Status) {
  # "Could not look" and "looked, found nothing" are different answers.
  if (-not $readable) {
    Write-Output 'COULD NOT READ STATUS'
    $conditions | ForEach-Object { Write-Output ("{0}|{1}|{2}" -f $_.key, $_.prio, $_.msg) }
  }
  elseif ($conditions.Count -eq 0) { Write-Output 'nothing firing' }
  else { $conditions | ForEach-Object { Write-Output ("{0}|{1}|{2}" -f $_.key, $_.prio, $_.msg) } }
  exit 0
}

# ------------------------------------------------------------------ dead man
#
# Pinged after the conditions are known, so a run that got as far as reading the
# status document is what counts as alive -- not merely a timer that fired.
#
# The /fail variant turns an outage into an immediate alarm rather than waiting
# out the service's grace period; without it a hard failure would be reported no
# sooner than a silent death, which wastes the one thing this adds.
function Send-Deadman {
  param([string]$Suffix = '')
  if (-not $DeadmanUrl) { return $false }
  try {
    Invoke-RestMethod -Uri ($DeadmanUrl + $Suffix) -TimeoutSec 15 | Out-Null
    return $true
  } catch {
    Write-AlertLog "dead-man ping to $DeadmanUrl$Suffix failed: $($_.Exception.Message)"
    return $false
  }
}

if ($Test) {
  Send-Alert 'default' "XL1 $NodeName`: test" 'If you are reading this, the channel works.'
  if ($DeadmanUrl) {
    if (Send-Deadman) { Write-Output "dead-man ping sent to $DeadmanUrl" }
  }
  else { Write-Output 'dead-man: not configured (XL1_ALERT_DEADMAN_URL is empty)' }
  exit 0
}

if ($readable) {
  # A node that is DOWN is a definite failure, not a missed check-in.
  $hard = $conditions | Where-Object { $_.key -in @('node-down', 'container-stopped') }
  if ($hard) { Send-Deadman '/fail' | Out-Null } else { Send-Deadman | Out-Null }
}

# --------------------------------------------------------------- transitions

$dir = Split-Path -Parent $StateFile
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
if (-not (Test-Path $StateFile)) { Set-Content -Path $StateFile -Value '' -NoNewline }

$now = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$previous = @{}
foreach ($line in @(Get-Content -Path $StateFile -ErrorAction SilentlyContinue)) {
  if (-not $line) { continue }
  $parts = $line -split "`t"
  if ($parts.Count -lt 2) { continue }
  $ts = 0
  if ([int]::TryParse($parts[1], [ref]$ts)) { $previous[$parts[0]] = $ts }
}

$next = [ordered]@{}
foreach ($c in $conditions) {
  if (-not $previous.ContainsKey($c.key)) {
    Send-Alert $c.prio ("XL1 $NodeName`: " + $c.msg) ("Started " + (Get-Date -Format 'o') + ".")
    $next[$c.key] = $now
  }
  elseif (($now - $previous[$c.key]) -ge $Cooldown) {
    # Still true hours later. Say so once more, then go quiet again.
    Send-Alert $c.prio ("XL1 $NodeName`: still — " + $c.msg) `
      ("Unresolved for " + [int](($now - $previous[$c.key]) / 3600) + "h.")
    $next[$c.key] = $now
  }
  else { $next[$c.key] = $previous[$c.key] }
}

# Recovery is worth as much as the alarm: an operator who was told something
# broke and never told it healed keeps checking by hand.
#
# But only when we could actually see. When the fetch fails every real condition
# looks absent, and reporting the ineligibility resolved seconds after the
# dashboard container died is worse than saying nothing. Not seeing a problem is
# not the same as the problem being fixed -- carry the old state forward.
if ($readable) {
  foreach ($key in $previous.Keys) {
    if (-not $next.Contains($key)) {
      Send-Alert 'default' "XL1 $NodeName`: recovered — $key" ("Cleared " + (Get-Date -Format 'o') + ".")
    }
  }
}
else {
  foreach ($key in $previous.Keys) {
    if (-not $next.Contains($key)) { $next[$key] = $previous[$key] }
  }
}

# Atomically: a kill partway through this write leaves a truncated state file,
# after which every condition looks new and re-fires at full priority.
$body = ($next.Keys | ForEach-Object { "$_`t$($next[$_])" }) -join "`n"
$tmp = "$StateFile.tmp"
Set-Content -Path $tmp -Value $body -NoNewline
Move-Item -Path $tmp -Destination $StateFile -Force
