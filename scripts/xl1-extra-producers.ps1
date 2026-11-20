<#
  Extra producers beside the main one (xl1-node-preset-1, cc91 on sequence).

    23b3 on sequence   project xl1-seq-23b3   health 127.0.0.1:9100   config\seq-23b3-producer.env
    cc91 on mainnet    project xl1-main-cc91  health 127.0.0.1:9101   config\main-cc91-producer.env
    653e on mainnet    project xl1-main-653e  health 127.0.0.1:9102   config\main-653e-producer.env

  653e (a930…653e, added 2026-10-16) is a third, separate mainnet key with its
  own stake -- the fleet's third mainnet producer beside the Pi and cc91. It
  runs on mainnet only.

  Each key is on two networks at once: 23b3 on mainnet (the Pi) and here on
  sequence, and cc91 on sequence (the main node) and here on mainnet. The
  networks are separate chains, so a key never competes with itself. The rule
  that keeps that true: never two producers with one key on the SAME network.

  The extras run their own image tag (xl1:5.7.2 since 2026-11-20 for the mainnet
  pair; build it with Build.ps1 -CliVersion 5.7.2 -ProducerOnly, which also tags
  xl1:5.7.2) so a Build.ps1 run, which retags xl1:local, never
  changes them by accident. Change this default only together with an upgrade:
  `up` without -Image recreates onto whatever it names.

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
  [string]$Image = 'xl1:5.7.2',
  [ValidateSet('xl1-seq-23b3', 'xl1-main-cc91', 'xl1-main-653e')][string]$Only
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Upstream = Join-Path $Root 'upstream\compose\node.yml'
$Tuning = Join-Path $Root 'compose\producer-tuning.yml'
$Preset = Join-Path $Root 'presets\roles\producer.json'
$PresetRest = Join-Path $Root 'presets\roles\producer-rest.json'

# Roles = which preset folder the node mounts (owner call 2026-11-20, after Arie Trouw said his
# leading homelab producer polls at 500 ms): cc91 reads presets\roles-mainnet-500 (500 ms, like
# the Pi), 653e reads presets\roles-mainnet (1000 ms). Everything else in those files is
# identical to presets\roles, which stays at 3000 for the sequence nodes and is what tests pin.
# Both mainnet nodes use ethereum-rpc.publicnode.com for ETH; the Pi uses eth.drpc.org.
$Extras = @(
  @{ Project = 'xl1-seq-23b3'; Env = 'seq-23b3-producer.env'; Health = 9100; Roles = 'roles' },
  @{ Project = 'xl1-main-cc91'; Env = 'main-cc91-producer.env'; Health = 9101; Roles = 'roles-mainnet-500' },
  @{ Project = 'xl1-main-653e'; Env = 'main-653e-producer.env'; Health = 9102; Roles = 'roles-mainnet' }
)

foreach ($x in $Extras) {
  if ($Only -and $x.Project -ne $Only) { continue }
  $envPath = Join-Path $Root "config\$($x.Env)"
  if ($Action -ne 'status' -and -not (Test-Path $envPath)) { throw "missing $envPath" }
  # A placeholder phrase would start a producer for some other, unstaked key.
  if ($Action -eq 'up' -and (Select-String -Path $envPath -Pattern 'PASTE_RECOVERY_PHRASE_HERE' -Quiet)) {
    throw "$($x.Env) still has the placeholder recovery phrase -- fill in XL1_MNEMONIC first"
  }

  # Relative to the first compose file's directory, as in xl1ctl.ps1.
  $env:XL1_IMAGE = $Image
  $env:XL1_PULL_POLICY = 'never'
  $env:XL1_PRESET_ENV_FILE = "../../config/$($x.Env)"
  $env:XL1_PRODUCER_PRESET = Join-Path $Root "presets\$($x.Roles)\producer.json"
  $env:XL1_PRODUCER_PRESET_REST = Join-Path $Root "presets\$($x.Roles)\producer-rest.json"
  if (-not (Test-Path $env:XL1_PRODUCER_PRESET_REST)) { throw "missing $($env:XL1_PRODUCER_PRESET_REST)" }
  # Loopback only: the main node's 9099 is the one other machines read.
  $env:XL1_HEALTH_HOST_PORT = "127.0.0.1:$($x.Health)"

  $compose = @('compose', '-p', $x.Project, '-f', $Upstream, '-f', $Tuning, '--profile', 'preset')
  switch ($Action) {
    'up' { & docker @compose up -d preset }
    'down' { & docker @compose down }
    'status' { & docker @compose ps preset }
  }
}
