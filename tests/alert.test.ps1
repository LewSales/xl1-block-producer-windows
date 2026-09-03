<#
.SYNOPSIS
  scripts\xl1-alert.ps1 against a served fixture.

.DESCRIPTION
  The Windows twin of the Pi's tests/alert.test.sh, case for case. The ones that
  matter are the ones that made the alerter lie: reporting nothing while several
  problems were live, and reporting recoveries for conditions it could not see.

  Served over a socket rather than read from a file, because the alerter fetches
  a URL and a test that swapped that for a file read would be testing a program
  nobody runs. The listener is fifteen lines of TcpListener rather than
  HttpListener, which wants a URL reservation and therefore an elevated shell.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'

$Here   = $PSScriptRoot
$Alert  = Join-Path (Split-Path -Parent $Here) 'scripts\xl1-alert.ps1'
$Work   = Join-Path $env:TEMP ('xl1-alert-test-' + [guid]::NewGuid().ToString('N'))
$script:Failed = 0
New-Item -ItemType Directory -Path $Work -Force | Out-Null

function Ok   { param($m) Write-Host "    ok   $m" -ForegroundColor Green }
function Fail { param($m, $extra = '') Write-Host "    FAIL $m" -ForegroundColor Red; if ($extra) { Write-Host "         $extra" -ForegroundColor Red }; $script:Failed++ }
function Check { param($name, $got, $want) if ("$got" -eq "$want") { Ok $name } else { Fail $name "want: $want   got: $got" } }
function Has   { param($name, $needle, $text) if ($text -match [regex]::Escape($needle)) { Ok $name } else { Fail $name "no /$needle/ in output" } }
function Hasnt { param($name, $needle, $text) if ($text -match [regex]::Escape($needle)) { Fail $name "unexpected /$needle/" } else { Ok $name } }

# A free port, chosen the same way the Pi's suite does it.
$probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe.Start(); $Port = $probe.LocalEndpoint.Port; $probe.Stop()

# A sink for delivery, on its own port so it outlives the status server that the
# outage cases deliberately kill.
$probe2 = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
$probe2.Start(); $SinkPort = $probe2.LocalEndpoint.Port; $probe2.Stop()

$server = Start-Job -ScriptBlock {
  param($dir, $port)
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
  $listener.Start()
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $reader = New-Object IO.StreamReader($stream)
      $request = $reader.ReadLine()
      # Drain the headers. Answering before the request is fully sent gets the
      # response reset by the client's stack rather than read.
      while ($true) { $line = $reader.ReadLine(); if ($null -eq $line -or $line -eq '') { break } }
      $verb = ($request -split ' ')[0]
      $name = (($request -split ' ')[1]).TrimStart('/').Split('?')[0]
      $file = Join-Path $dir $name
      if ($verb -eq 'POST') {
        # Stands in for ntfy or a webhook: anything posted is accepted, so the
        # test is about whether the request could be BUILT, not about the far end.
        $bytes = [byte[]]@()
        $head = "HTTP/1.1 200 OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
      }
      elseif (Test-Path $file) {
        $bytes = [Text.Encoding]::UTF8.GetBytes((Get-Content $file -Raw))
        $head = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
      } else {
        $bytes = [byte[]]@()
        $head = "HTTP/1.1 404 Not Found`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"
      }
      $hb = [Text.Encoding]::ASCII.GetBytes($head)
      $stream.Write($hb, 0, $hb.Length)
      if ($bytes.Length) { $stream.Write($bytes, 0, $bytes.Length) }
      $stream.Flush()
    } catch {}
    finally { $client.Close() }
  }
} -ArgumentList $Work, $Port

$sink = Start-Job -ScriptBlock {
  param($port)
  $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $port)
  $listener.Start()
  while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
      $stream = $client.GetStream()
      $reader = New-Object IO.StreamReader($stream)
      $null = $reader.ReadLine()
      while ($true) { $line = $reader.ReadLine(); if ($null -eq $line -or $line -eq '') { break } }
      $hb = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
      $stream.Write($hb, 0, $hb.Length); $stream.Flush()
    } catch {}
    finally { $client.Close() }
  }
} -ArgumentList $SinkPort

function Stop-Fixture {
  if ($server) { Stop-Job $server -ErrorAction SilentlyContinue; Remove-Job $server -Force -ErrorAction SilentlyContinue }
}
function Stop-Sink {
  if ($sink) { Stop-Job $sink -ErrorAction SilentlyContinue; Remove-Job $sink -Force -ErrorAction SilentlyContinue }
}

try {
  # Four live conditions: ineligible, cli-behind, not-producing, swapping.
  @'
{"status":"degraded",
 "problems":["producer ineligible: not on the allowed-producer list"],
 "health":{"ok":true},"chain":{"ok":true},
 "node":{"ok":true,"stale":false,"container":{"running":true},
         "eligibility":{"blocked":true,"key":"not-allowed","reason":"not on the allowed-producer list"},
         "eligibilityIgnored":false,"cliVersion":"5.2.2","runSeconds":50000,"buildsThisRun":900},
 "release":{"ok":true,"latest":"5.3.2","installed":"5.2.2","lag":"behind"},
 "derived":{"blocksSinceLast":150,"secondsPerBlock":57},
 "system":{"ok":true,"swap":{"usedPercent":75}}}
'@ | Set-Content -Path (Join-Path $Work 'status.json') -Encoding UTF8

  $envFile = Join-Path $Work 'alert.env'
  @"
XL1_ALERT_URL=http://127.0.0.1:$Port/status.json
XL1_ALERT_STATE=$Work\.alert-state
XL1_ALERT_NAME=testnode
"@ | Set-Content -Path $envFile -Encoding UTF8

  # Environment, not parameters: this is exactly how the scheduled task and the
  # Pi's timer configure it, so the test exercises the path operators use.
  function A {
    $old = $env:XL1_ALERT_ENV
    $env:XL1_ALERT_ENV = $envFile
    try { (& $Alert @args *>&1 | Out-String) } finally { $env:XL1_ALERT_ENV = $old }
  }

  # Wait for the listener rather than sleeping a fixed amount.
  $up = $false
  foreach ($i in 1..40) {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/status.json" -TimeoutSec 1 | Out-Null; $up = $true; break }
    catch { Start-Sleep -Milliseconds 250 }
  }
  if (-not $up) { Fail 'fixture server never came up'; Stop-Fixture; exit 1 }

  # A launch that came up non-producing, served separately so the state-machine
  # sequence below is not perturbed. -Status only; it writes nothing.
  function Mk2 {
    param([int]$RunSeconds, [int]$Builds)
    @"
{"status":"ok","health":{"ok":true},"chain":{"ok":true},
 "node":{"ok":true,"stale":false,"container":{"running":true},
         "eligibility":{"blocked":false},"runSeconds":$RunSeconds,"buildsThisRun":$Builds},
 "release":{"ok":true},"derived":{"blocksSinceLast":0},
 "system":{"ok":true,"swap":{"usedPercent":0}}}
"@ | Set-Content -Path (Join-Path $Work 'status2.json') -Encoding UTF8
    $env2 = Join-Path $Work 'alert2.env'
    @"
XL1_ALERT_URL=http://127.0.0.1:$Port/status2.json
XL1_ALERT_STATE=$Work\.alert-state2
XL1_ALERT_NAME=testnode
"@ | Set-Content -Path $env2 -Encoding UTF8
    $old = $env:XL1_ALERT_ENV
    $env:XL1_ALERT_ENV = $env2
    try { (& $Alert -Status *>&1 | Out-String) } finally { $env:XL1_ALERT_ENV = $old }
  }

  Hasnt 'a young container is given its grace'    'never-produced' (Mk2 60 0)
  Has   'a launch that never produced is caught'  'never-produced' (Mk2 1800 0)
  Hasnt 'a producing launch is not accused'       'never-produced' (Mk2 1800 4)

  $out = A -Status
  Has 'real conditions are detected'  'ineligible'    $out
  Has 'version lag is detected'       'cli-behind'    $out
  Has 'heavy swap is detected'        'swapping'      $out
  # A node that is up, healthy and winning nothing looks perfectly fine to every
  # other predicate.
  Has 'a healthy node winning nothing is caught' 'not-producing' $out

  $out = A
  $lines = @(Get-Content (Join-Path $Work '.alert-state') -ErrorAction SilentlyContinue | Where-Object { $_ })
  Check 'first run tracks all four' $lines.Count 4

  $out = A
  Hasnt 'second run is silent' 'XL1 testnode' $out

  # ntfy carries the title in an HTTP header, and .NET rejects anything outside
  # ASCII in one -- it throws "invalid Control characters" and the notification
  # is lost. Every message in the alerter is written with em dashes, so this
  # silently dropped every recovery notice and several conditions. The log still
  # recorded the alert as raised, because it had been; only the delivery was
  # gone, which is the worst shape a monitoring bug can take.
  #
  # `swapping` is the condition used here because its text actually contains one:
  #   Heavy swap use - this machine is short of RAM     (with an em dash)
  # Delivery is asserted through the absence of the complaint Send-Alert makes
  # when no channel accepted the message.
  $env3 = Join-Path $Work 'alert3.env'
  @"
XL1_ALERT_URL=http://127.0.0.1:$Port/status.json
XL1_ALERT_STATE=$Work\.alert-state3
XL1_ALERT_NAME=testnode
XL1_ALERT_NTFY_SERVER=http://127.0.0.1:$SinkPort
XL1_ALERT_NTFY_TOPIC=t
"@ | Set-Content -Path $env3 -Encoding UTF8
  $oldEnv = $env:XL1_ALERT_ENV
  $env:XL1_ALERT_ENV = $env3
  try { $out = (& $Alert *>&1 | Out-String) } finally { $env:XL1_ALERT_ENV = $oldEnv }

  $fired = @(Get-Content (Join-Path $Work '.alert-state3') -ErrorAction SilentlyContinue | Where-Object { $_ })
  Check 'the em-dash condition actually fired' ($fired -match 'swapping').Count 1
  Hasnt 'no channel refused the em-dash title'   'no channel delivered'       $out
  Hasnt 'the header was not rejected as invalid' 'invalid Control characters' $out

  # The dashboard dying must not read as everything healing.
  Stop-Fixture; $server = $null
  foreach ($i in 1..40) {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$Port/status.json" -TimeoutSec 1 | Out-Null; Start-Sleep -Milliseconds 250 }
    catch { break }
  }

  $out = A
  Has   'outage itself is reported'        'did not answer' $out
  Hasnt 'no false recovery for ineligible' 'recovered'      $out
  $lines = @(Get-Content (Join-Path $Work '.alert-state') -ErrorAction SilentlyContinue | Where-Object { $_ })
  Check 'prior conditions preserved' $lines.Count 5

  $out = A -Status
  Has '-Status admits it could not look' 'COULD NOT READ STATUS' $out

}
finally {
  Stop-Fixture
  Stop-Sink
  Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}

exit ([int]($script:Failed -gt 0))
