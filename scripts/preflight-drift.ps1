<#
.SYNOPSIS
  Read-only drift sweep. It takes a what-if of every enabled unit and judges it with deploy-unit.ps1 -Drift.

.DESCRIPTION
  Nothing is deployed. For each unit it runs `deploy-unit.ps1 -Unit <name> -Drift`, which compiles,
  takes a FullResourcePayloads what-if and fails the unit on anything that is not NoChange, a
  documented boundary, a hold, or an expected Ignore. For a subscription unit whose template is its
  main.bicep it also fails on a live resource group with no record in the preview (NoRecord). Results go to
  -EvidenceRoot, one folder per unit, plus drift-summary.txt and drift-summary.json at the top.

  The drift workflow (.github/workflows/mirror-drift.yml) runs it, by hand only, because it has no schedule
  until IT approves one. It is also what to run
  after an incident or a portal change to see what moved. Units are run one after another so the
  sweep never overlaps itself.

  A subscription unit passes an Ignore record for a resource inside a resource group that has its
  own resourceGroup unit, and names that unit ("measured by <unit>"). The resource is measured by
  that unit's own check, so enable both together. Resource group records follow groupsDeclaredBy
  in units.json (deploy-unit.ps1 help).

  It checks enabled units only, because deploy-unit.ps1 refuses a disabled one. While every unit is
  disabled there is nothing to check, so it stops with exit code 2 rather than report a clean run.

  Two kinds of enabled unit are skipped when -Units is not given, and listed in the summary as SKIP:
    - a unit that another enabled unit names in measuredWith (a deploy-excluded sibling). Checked alone,
      it would see the routine resource group file's resources as Ignore and fail every run, so it is
      measured by that routine unit's drift check instead. Keep the routine unit of the group enabled
      with it.
    - a unit whose template is a *.hash-excluded.bicep file. What-if cannot preview a name with '#',
      so it is checked by reading the resource back instead.
  A skip does not change the exit code. A deploy-excluded unit whose routine unit is not enabled is still
  checked on its own.

.PARAMETER Units
  Unit names to check, as a list or as one string with the names separated by commas. The default is every
  enabled unit in units.json except the three tenant-kind units and the skipped units above. A disabled unit
  named here is reported as ERROR. A unit named here is never skipped.

.PARAMETER EvidenceRoot
  Output folder. Default reports/work/drift/<UTC timestamp>.

.NOTES
  Exit code 0 when no unit drifted, 1 when at least one did, 2 when a unit could not be checked
  (what-if or identity failure) or there was no unit to check. Runs unchanged under Windows PowerShell 5.1
  and PowerShell 7.5 or later (Windows and Linux), as deploy-unit.ps1 does.
#>
[CmdletBinding()]
param(
  [string[]]$Units,
  [string]$EvidenceRoot
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
# Windows PowerShell 5.1 writes UTF8 with a byte order mark. PowerShell 7 writes the same bytes only with utf8BOM.
$utf8Bom = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
# Through -File (pwsh -File scripts/preflight-drift.ps1 -Units a,b) the names arrive as the one string 'a,b', so
# each name is split on commas and trimmed.
if ($Units) { $Units = @($Units | ForEach-Object { $_.Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
# A -Units that names nothing (only commas or spaces) stops, so it never falls back to every enabled unit.
if ($PSBoundParameters.ContainsKey('Units') -and @($Units).Count -eq 0) {
  Write-Host 'STOP: -Units names no unit.' -ForegroundColor Red
  exit 2
}
$udoc = Get-Content -Raw -LiteralPath ([IO.Path]::Combine($repo, 'deploy', 'units.json')) | ConvertFrom-Json
$skipped = @()
if (-not $Units -or $Units.Count -eq 0) {
  $enabled = @($udoc.units | Where-Object { $_.enabled -and $_.kind -ne 'tenant' } | Sort-Object wave, name)
  # Units measured through an enabled unit's measuredWith list (deploy-unit.ps1 -Drift merges them).
  # Unit names are matched character by character, case included, as deploy-unit.ps1 matches them.
  $covered = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  foreach ($x in $enabled) {
    $mw = $x.PSObject.Properties['measuredWith']
    if ($null -eq $mw) { continue }
    foreach ($s in @($mw.Value)) { if ($s -and -not $covered.ContainsKey($s)) { $covered[$s] = $x.name } }
  }
  $Units = @()
  foreach ($x in $enabled) {
    if ($covered.ContainsKey($x.name)) { $skipped += [pscustomobject]@{ unit = $x.name; reason = "measured by $($covered[$x.name]) (measuredWith)" }; continue }
    if ([string]$x.template -match '\.hash-excluded\.bicep$') { $skipped += [pscustomobject]@{ unit = $x.name; reason = "not previewable (a name with '#'), so check it by reading the resource back" }; continue }
    $Units += $x.name
  }
  foreach ($k in $skipped) { Write-Host "SKIP   $($k.unit): $($k.reason)" }
}
if ($Units.Count -eq 0) {
  Write-Host 'STOP: no enabled unit to check in deploy/units.json (skipped units are measured elsewhere). Set enabled to true in deploy/units.json for each deployed unit.' -ForegroundColor Red
  exit 2
}
if (-not $EvidenceRoot) { $EvidenceRoot = [IO.Path]::Combine($repo, 'reports', 'work', 'drift', (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmm')) }
# A full path, written with '/' on Linux when it was given with '\' (for example "$env:RUNNER_TEMP\drift"), so
# that this script reads the same folder deploy-unit.ps1 writes.
if ([IO.Path]::DirectorySeparatorChar -ne '\') { $EvidenceRoot = $EvidenceRoot.Replace('\', '/') }
$EvidenceRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($EvidenceRoot)
New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null

$rows = @()
foreach ($u in $Units) {
  Write-Host "== $u"
  $start = Get-Date
  # Only the evidence folder this run creates is read, so a reused -EvidenceRoot never shows an earlier run's findings.
  $unitRoot = Join-Path $EvidenceRoot $u
  $before = @(Get-ChildItem -LiteralPath $unitRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  # In the same process, so that a sign-in function the caller defines (the drift workflow's az function) still
  # applies. A terminating error inside deploy-unit.ps1 is caught here, so the sweep goes on with the next unit
  # and the summary is still written. The unit is reported as ERROR (exit code 2).
  $thrown = $null
  try { & (Join-Path $PSScriptRoot 'deploy-unit.ps1') -Unit $u -Drift -EvidenceRoot $EvidenceRoot | Out-Host; $code = $LASTEXITCODE }
  catch { $code = 2; $thrown = $_.Exception.Message; Write-Host "ERROR ${u}: $thrown" -ForegroundColor Red }
  $result = switch ($code) { 0 { 'clean' } 1 { 'DRIFT' } default { 'ERROR' } }
  $runDir = Get-ChildItem -LiteralPath $unitRoot -Directory -ErrorAction SilentlyContinue | Where-Object { $before -notcontains $_.FullName } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
  $gateFile = $null; $stopFile = $null
  if ($runDir) {
    $gateFile = Get-Item -LiteralPath (Join-Path $runDir.FullName 'pre-gate.json') -ErrorAction SilentlyContinue
    $stopFile = Get-Item -LiteralPath (Join-Path $runDir.FullName 'stop.txt') -ErrorAction SilentlyContinue
  }
  $findings = @()
  $notMeasured = @()
  if ($thrown) { $findings += "the check stopped with an error: $thrown" }
  if ($gateFile) {
    $g = Get-Content -Raw -LiteralPath $gateFile.FullName | ConvertFrom-Json
    $findings += @($g.problems)
    $findings += @($g.decisions | Where-Object { $_.verdict -eq 'fail' } | ForEach-Object { "$($_.changeType) $($_.resourceId): $(@($_.notes) -join '; ')" })
    # A subscription unit's Ignore records inside a group whose resource-group unit is disabled pass, but nothing
    # measures them yet (deploy-unit.ps1, Find-DriftOwner). They are counted per covering unit for the summary.
    foreach ($d in @($g.decisions)) {
      foreach ($n in @($d.notes)) { if ($n -match '^covered by (\S+), which is disabled') { $notMeasured += $Matches[1] } }
    }
  } elseif ($code -ne 0) {
    # A unit that stopped before its gate (identity, tenant, compile, what-if) leaves stop.txt with the reason.
    if ($stopFile) { $findings += @(Get-Content -LiteralPath $stopFile.FullName | Where-Object { $_ -like 'Reason:*' } | ForEach-Object { $_.Substring(7).Trim() }) }
    elseif (-not $runDir) { $findings += 'stopped before its evidence folder was created (for example a disabled or unknown unit). The reason is in the output above' }
  }
  $notes = @()
  if ($notMeasured.Count -gt 0) {
    $byUnit = @($notMeasured | Group-Object | Sort-Object Name | ForEach-Object { "$($_.Name) ($($_.Count))" })
    $notes += "$($notMeasured.Count) resources in groups whose units are disabled, not measured until they are enabled: $($byUnit -join ', ')"
  }
  $rows += [pscustomobject]@{ unit = $u; result = $result; exitCode = $code; minutes = [Math]::Round(((Get-Date) - $start).TotalMinutes, 1); findings = $findings; notes = $notes }
}

$lines = @("Drift sweep $((Get-Date).ToUniversalTime().ToString('u'))", '')
foreach ($r in $rows) {
  $lines += ("{0,-6} {1}" -f $r.result, $r.unit)
  foreach ($f in $r.findings) { $lines += "       $f" }
  foreach ($n in $r.notes) { $lines += "NOTE   $($r.unit): $n" }
}
foreach ($k in $skipped) { $lines += ("{0,-6} {1}: {2}" -f 'SKIP', $k.unit, $k.reason) }
Set-Content -LiteralPath (Join-Path $EvidenceRoot 'drift-summary.txt') -Value $lines -Encoding $utf8Bom
$skipRows = @($skipped | ForEach-Object { [pscustomobject]@{ unit = $_.unit; result = 'SKIP'; exitCode = $null; minutes = 0; findings = @($_.reason); notes = @() } })
# -InputObject keeps the list a JSON array when it holds one unit, where the pipeline would write a single object.
ConvertTo-Json -InputObject (@($rows) + $skipRows) -Depth 5 | Set-Content -LiteralPath (Join-Path $EvidenceRoot 'drift-summary.json') -Encoding $utf8Bom
$lines | Write-Host

if (@($rows | Where-Object { $_.result -eq 'ERROR' }).Count -gt 0) { exit 2 }
if (@($rows | Where-Object { $_.result -eq 'DRIFT' }).Count -gt 0) { exit 1 }
exit 0
