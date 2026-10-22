<#
.SYNOPSIS
  Sort-LogStamped from scripts\xl1-collect.ps1, on the log shape it was written for.

.DESCRIPTION
  xl1-cli logs "Generated time payload" on stderr and "Building block" on
  stdout. Read through PowerShell 5.1's 2>&1 the stderr lines arrive in a batch
  after the stdout around them, and the collector then paired almost no build
  with its time payload. The function is lifted out of the collector by its
  syntax tree, so the test runs it without running the collector or docker.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Collect = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts\xl1-collect.ps1'
$script:Failed = 0

function Ok   { param($m) Write-Host "    ok   $m" -ForegroundColor Green }
function Fail { param($m, $extra = '') Write-Host "    FAIL $m" -ForegroundColor Red; if ($extra) { Write-Host "         $extra" -ForegroundColor Red }; $script:Failed++ }
function Check { param($name, $got, $want) if ("$got" -eq "$want") { Ok $name } else { Fail $name "want: $want   got: $got" } }

$ast = [System.Management.Automation.Language.Parser]::ParseFile($Collect, [ref]$null, [ref]$null)
$fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sort-LogStamped' }, $true)
if (-not $fn) { Fail 'Sort-LogStamped is defined in xl1-collect.ps1'; exit 1 }
. ([scriptblock]::Create($fn.Extent.Text))

# As PowerShell delivered them on 2026-10-22: stdout first, stderr batched after.
$arrived = @(
  '2026-10-22T21:58:05.268295159Z [BlockRunner] Building block 1862877',
  '2026-10-22T21:58:17.281337462Z [BlockRunner] Building block 1862878',
  '2026-10-22T21:58:26.3627414Z [BlockRunner] Building block 1862879',
  '2026-10-22T21:58:05.266409834Z [BlockRunner] [Slow] Generated time payload in 327ms',
  '2026-10-22T21:58:17.27822472Z [BlockRunner] [Slow] Generated time payload in 316ms',
  '2026-10-22T21:58:26.36Z [BlockRunner] [Slow] Generated time payload in 329ms'
)
$sorted = @(Sort-LogStamped $arrived)
Check 'every line kept' $sorted.Count 6
Check 'payload before its build (ns stamps)' ($sorted[0] -replace '^\S+Z ', '') '[BlockRunner] [Slow] Generated time payload in 327ms'
Check 'build follows its payload' ($sorted[1] -replace '^\S+Z ', '') '[BlockRunner] Building block 1862877'
# .36Z is .360000000, before .3627414: a plain string sort puts it after, since 'Z' > '2'.
Check 'trailing zeros dropped by docker still order' ($sorted[4] -replace '^\S+Z ', '') '[BlockRunner] [Slow] Generated time payload in 329ms'
Check 'last build last' ($sorted[5] -replace '^\S+Z ', '') '[BlockRunner] Building block 1862879'

# The pairing the collector does with the result: payload time carried to the next build.
$tp = $null; $pairs = @{}
foreach ($l in $sorted) {
  if ($l -match 'Generated time payload in (\d+)ms') { $tp = [int]$Matches[1]; continue }
  if ($l -match 'Building block (\d+)$') { $pairs[$Matches[1]] = $tp; $tp = $null }
}
Check 'every build paired with its payload' "$($pairs['1862877']),$($pairs['1862878']),$($pairs['1862879'])" '327,316,329'

$tie = @(Sort-LogStamped @('2026-10-22T21:00:00.5Z b', '2026-10-22T21:00:00.500Z a', '2026-10-22T21:00:00Z c'))
Check 'equal stamps keep arrival order; whole seconds sort first' ($tie -join '|') '2026-10-22T21:00:00Z c|2026-10-22T21:00:00.5Z b|2026-10-22T21:00:00.500Z a'
Check 'empty input' (@(Sort-LogStamped @()).Count) 0
Check 'null input' (@(Sort-LogStamped $null).Count) 0

# The collector sorts up to 8000 lines per container every 30 s.
$many = @(for ($k = 0; $k -lt 8000; $k++) { '2026-10-22T21:{0:D2}:{1:D2}.{2}Z line {3}' -f [int][Math]::Floor($k / 600), [int][Math]::Floor(($k % 600) / 10), (($k * 7919) % 1000), $k })
$ms = (Measure-Command { $big = @(Sort-LogStamped $many) }).TotalMilliseconds
Check '8000 lines kept' $big.Count 8000
if ($ms -lt 500) { Ok "8000 lines sorted in $([int]$ms) ms" } else { Fail "8000 lines sorted in $([int]$ms) ms (budget 500)" }

if ($script:Failed) { Write-Host "  $script:Failed failed" -ForegroundColor Red; exit 1 }
Write-Host '  all passed' -ForegroundColor Green
exit 0
