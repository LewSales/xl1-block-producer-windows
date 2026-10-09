<#
  Extra producers beside the main one (xl1-node-preset-1, cc91 on sequence).

    23b3 on sequence   project xl1-seq-23b3   health 127.0.0.1:9100   config\seq-23b3-producer.env
    cc91 on mainnet    project xl1-main-cc91  health 127.0.0.1:9101   config\main-cc91-producer.env

  Each key is on two networks at once: 23b3 on mainnet (the Pi) and here on
  sequence, and cc91 on sequence (the main node) and here on mainnet. The
  networks are separate chains, so a key never competes with itself. The rule
  that keeps that true: never two producers with one key on the SAME network.

  The extras run their own image tag (xl1:5.6.1, the Pi's mainnet version) so a
  Build.ps1 run, which retags xl1:local, never changes them by accident.

  Same compose files and role presets as xl1ctl.ps1, separate compose project
  names, so `xl1ctl.ps1` start/stop/rollback never touch these and vice versa.

    powershell -File .\scripts\xl1-extra-producers.ps1 up       # start or update both
    powershell -File .\scripts\xl1-extra-producers.ps1 down     # stop and remove both
    powershell -File .\scripts\xl1-extra-producers.ps1 status
    powershell -File .\scripts\xl1-extra-producers.ps1 up -Only xl1-seq-23b3   # just one

  cc91 on mainnet: no blocks accepted in its first test (2026-10-08), most likely
  because XYO has not yet allowed the key there. Running again from 2026-10-09
  so it lands as soon as the key is allowed. `down -Only xl1-main-cc91` pauses it.
#>
[CmdletBinding()]
param(
  [ValidateSet('up', 'down', 'status')][string]$Action = 'status',
  [string]$Image = 'xl1:5.6.1',
  [ValidateSet('xl1-seq-23b3', 'xl1-main-cc91')][string]$Only
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Upstream = Join-Path $Root 'upstream\compose\node.yml'
$Tuning = Join-Path $Root 'compose\producer-tuning.yml'
$Preset = Join-Path $Root 'presets\roles\producer.json'
$PresetRest = Join-Path $Root 'presets\roles\producer-rest.json'

$Extras = @(
  @{ Project = 'xl1-seq-23b3'; Env = 'seq-23b3-producer.env'; Health = 9100 },
  @{ Project = 'xl1-main-cc91'; Env = 'main-cc91-producer.env'; Health = 9101 }
)

foreach ($x in $Extras) {
  if ($Only -and $x.Project -ne $Only) { continue }
  $envPath = Join-Path $Root "config\$($x.Env)"
  if ($Action -ne 'status' -and -not (Test-Path $envPath)) { throw "missing $envPath" }

  # Relative to the first compose file's directory, as in xl1ctl.ps1.
  $env:XL1_IMAGE = $Image
  $env:XL1_PULL_POLICY = 'never'
  $env:XL1_PRESET_ENV_FILE = "../../config/$($x.Env)"
  $env:XL1_PRODUCER_PRESET = $Preset
  $env:XL1_PRODUCER_PRESET_REST = $PresetRest
  # Loopback only: the main node's 9099 is the one other machines read.
  $env:XL1_HEALTH_HOST_PORT = "127.0.0.1:$($x.Health)"

  $compose = @('compose', '-p', $x.Project, '-f', $Upstream, '-f', $Tuning, '--profile', 'preset')
  switch ($Action) {
    'up' { & docker @compose up -d preset }
    'down' { & docker @compose down }
    'status' { & docker @compose ps preset }
  }
}
