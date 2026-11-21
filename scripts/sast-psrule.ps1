<#
.SYNOPSIS
  Offline security scan of the Bicep entry points with PSRule for Azure.

.DESCRIPTION
  Read-only, no Azure calls. Takes the entry points from deploy/units.json (each unit's parameter
  file, or its template when it has none) and adds infra/tenant/main.bicep. Every entry point is
  first compiled with bicep build-params (or bicep build) and timed. PSRule then expands the ones
  that compiled quickly with the Bicep CLI and runs the baseline (Azure.Default unless told
  otherwise). The slow ones, and any that PSRule does not expand, are scanned from the compiled
  ARM JSON with the same rules. The log names the route each entry point took.

  PSRule 2.9.0 ends the PowerShell host (exit code 2) a few seconds after a Bicep build inside it
  hits the expansion timeout, which is why slow entry points do not go through PSRule's own build.

  Writes to reports/work/sast/psrule/<timestamp>/:
    results.sarif           SARIF from the expansion pass
    results-compiled.sarif  SARIF from the compiled pass (only when an entry point needed it)
    results.json            every rule result (Pass, Fail, Error) with its entry point
    scan.log                compile times, PSRule console output, warnings and errors
    summary.txt             failures per rule, severity, pillar and entry point. Resources per security rule

  Needs Windows PowerShell 5.1, the PSRule 2.9.0 and PSRule.Rules.Azure 1.47.0 modules
  (Install-Module PSRule -RequiredVersion 2.9.0 -Scope CurrentUser, Install-Module PSRule.Rules.Azure
  -RequiredVersion 1.47.0 -Scope CurrentUser) and Bicep CLI 0.49.2. ps-rule.yaml in the repository root
  sets the minimum versions and the options. A full run takes about 30 to 60 minutes. The output folder
  is under reports\work, which .gitignore keeps out of the repository.

  Rule failures are findings and do not fail the run. The exit code is 1 when an entry point does not
  compile, when an entry point has no resource scanned, or when a rule ends in Error. 0 otherwise.

.PARAMETER Root
  Repository root. Defaults to the parent of this script's folder.

.PARAMETER OutDir
  Output folder. Defaults to reports/work/sast/psrule/<timestamp> under Root.

.PARAMETER Unit
  Scan only these units of deploy/units.json (by name). The default is all of them.

.PARAMETER Parallel
  Bicep builds run at once in the compile step. Default 3.

.PARAMETER ExpandLimit
  Seconds. An entry point that took longer than this to compile is scanned from its compiled JSON
  instead of being expanded by PSRule. Default 60, half the PSRule timeout of 120.

.EXAMPLE
  powershell -NoProfile -File scripts/sast-psrule.ps1
  powershell -NoProfile -File scripts/sast-psrule.ps1 -Unit fdm-grc,fdm-rsg-uks-monitor
#>
[CmdletBinding()]
param(
    [string]$Root,
    [string]$OutDir,
    [string[]]$Unit,
    [string]$Baseline = 'Azure.Default',
    [int]$Parallel = 3,
    [int]$ExpandLimit = 60,
    [string]$Bicep = (Join-Path $env:USERPROFILE '.azure\bin\bicep.exe')
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 leaves $PSScriptRoot empty in parameter defaults under -File, so the default
# is set here.
if (-not $Root) { $Root = Split-Path -Parent $PSScriptRoot }
$Root = (Resolve-Path $Root).Path
if (-not $OutDir) { $OutDir = Join-Path $Root ('reports\work\sast\psrule\' + (Get-Date -Format 'yyyyMMdd-HHmmss')) }
New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$log = Join-Path $OutDir 'scan.log'
$option = Join-Path $Root 'ps-rule.yaml'
if (-not (Test-Path $Bicep)) { throw "Bicep CLI not found at $Bicep" }
$env:PSRULE_AZURE_BICEP_PATH = $Bicep
Import-Module PSRule.Rules.Azure -ErrorAction Stop

function Write-Log([string]$Text) { Add-Content -Path $log -Value $Text -Encoding UTF8; Write-Host $Text }

# Starts the Bicep CLI in its own process with both outputs read asynchronously.
function Start-Bicep([string[]]$Arguments) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Bicep
    $psi.Arguments = ($Arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    [pscustomobject]@{ Process = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Started = Get-Date }
}

function Invoke-Scan([string[]]$Paths, [string]$Sarif) {
    $rv = $null
    $console = $null
    try {
        $console = Assert-PSRule -Option $option -InputPath $Paths -Module PSRule.Rules.Azure -Baseline $Baseline `
            -Format File -OutputFormat Sarif -OutputPath $Sarif -ResultVariable rv -ErrorAction Continue *>&1
    } catch {
        # Assert-PSRule throws when any rule fails. The results are already in the variable.
        $console = @($console) + ('Assert-PSRule: ' + $_.Exception.Message)
    }
    Add-Content -Path $log -Value ($console | Out-String -Width 400) -Encoding UTF8
    @($rv)
}

function Get-EntryOf($Record, $Map) {
    foreach ($s in @($Record.Source)) {
        if (-not $s.File) { continue }
        $f = ([IO.Path]::GetFullPath($s.File)).ToLowerInvariant()
        if ($Map.ContainsKey($f)) { return $Map[$f] }
    }
    return $null
}

# Entry points, as relative path -> unit name.
$units = (Get-Content (Join-Path $Root 'deploy\units.json') -Raw | ConvertFrom-Json).units
# -File passes 'a,b' as one string. Split it.
if ($Unit) { $Unit = @($Unit -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
if ($Unit) { $units = $units | Where-Object { $Unit -contains $_.name } }
$entries = [ordered]@{}
foreach ($u in $units) {
    $p = if ($u.parameters) { $u.parameters } else { $u.template }
    $entries[$p.Replace('\', '/')] = $u.name
}
if (-not $Unit) { $entries['infra/tenant/main.bicep'] = 'tenant-main' }
if ($entries.Count -eq 0) { throw 'No entry points matched.' }
$v = Start-Bicep @('--version'); $v.Process.WaitForExit(); $bicepVersion = $v.Out.Result.Trim()
Write-Log ("PSRule {0}, PSRule.Rules.Azure {1}, {2}, baseline {3}, {4} entry points, root {5}" -f `
    (Get-Module PSRule).Version, (Get-Module PSRule.Rules.Azure).Version, $bicepVersion, $Baseline, $entries.Count, $Root)

# Step 1. Compile every entry point to ARM JSON, a few at a time, and time each build.
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('sast-psrule-' + [guid]::NewGuid().ToString('n').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
$compiled = @{}
$compileFailed = 0
$queue = New-Object System.Collections.Queue
foreach ($k in $entries.Keys) { $queue.Enqueue($k) }
$running = @{}
$started = Get-Date
while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($queue.Count -gt 0 -and $running.Count -lt $Parallel) {
        $k = $queue.Dequeue()
        $verb = if ($k -like '*.bicepparam') { 'build-params' } else { 'build' }
        $running[$k] = Start-Bicep @($verb, (Join-Path $Root $k), '--stdout')
    }
    Start-Sleep -Milliseconds 500
    foreach ($k in @($running.Keys)) {
        $j = $running[$k]
        if (-not $j.Process.HasExited) { continue }
        $j.Process.WaitForExit()
        $seconds = [int]((Get-Date) - $j.Started).TotalSeconds
        $running.Remove($k)
        if ($j.Err.Result) { Add-Content -Path $log -Value $j.Err.Result -Encoding UTF8 }
        if ($j.Process.ExitCode -ne 0) { Write-Log "Compile failed: $k"; $compileFailed++; continue }
        $i = $compiled.Count + 1
        $stem = Join-Path $tmp "e$i"
        if ($k -like '*.bicepparam') {
            $pair = $j.Out.Result | ConvertFrom-Json
            $template = $pair.templateJson
            $params = $pair.parametersJson | ConvertFrom-Json
        } else {
            $template = $j.Out.Result
            $params = [pscustomobject]@{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0.0'; parameters = @{} }
        }
        [IO.File]::WriteAllText("$stem.template.json", $template)
        $params | Add-Member -NotePropertyName metadata -NotePropertyValue @{ template = "./e$i.template.json" } -Force
        [IO.File]::WriteAllText("$stem.parameters.json", ($params | ConvertTo-Json -Depth 100))
        $compiled[$k] = [pscustomobject]@{ Parameters = "$stem.parameters.json"; Template = "$stem.template.json"; Seconds = $seconds }
        Add-Content -Path $log -Value ("Compiled in {0,4} s: {1}" -f $seconds, $k) -Encoding UTF8
    }
}
Write-Log ("Compile step: {0} of {1} entry points in {2:N0} s" -f $compiled.Count, $entries.Count, ((Get-Date) - $started).TotalSeconds)

$all = New-Object System.Collections.Generic.List[object]
$mode = @{}
Push-Location $Root
try {
    # Step 2. PSRule expands the entry points that compiled inside the limit.
    $fast = @($entries.Keys | Where-Object { $compiled.ContainsKey($_) -and $compiled[$_].Seconds -le $ExpandLimit })
    if ($fast.Count -gt 0) {
        $map = @{}
        foreach ($k in $fast) { $map[([IO.Path]::GetFullPath((Join-Path $Root $k))).ToLowerInvariant()] = $k }
        $started = Get-Date
        $results = Invoke-Scan -Paths $fast -Sarif (Join-Path $OutDir 'results.sarif')
        Write-Log ("Expansion pass: {0} entry points, {1} results in {2:N0} s" -f $fast.Count, $results.Count, ((Get-Date) - $started).TotalSeconds)
        foreach ($r in $results) {
            $e = Get-EntryOf $r $map
            # Only an expanded resource counts. Rules on the file itself run even when expansion fails.
            if ($e -and $r.TargetType -like 'Microsoft.*') { $mode[$e] = 'bicep' }
            $all.Add([pscustomobject]@{ Record = $r; Entry = $e; Mode = 'bicep' })
        }
    }

    # Step 3. The rest (slow to compile, or no result from the expansion pass) are scanned as ARM JSON.
    $rest = @($entries.Keys | Where-Object { $compiled.ContainsKey($_) -and -not $mode.ContainsKey($_) })
    if ($rest.Count -gt 0) {
        $map2 = @{}
        foreach ($k in $rest) {
            Write-Log ("Scanned from compiled JSON ({0} s to compile): {1}" -f $compiled[$k].Seconds, $k)
            $map2[([IO.Path]::GetFullPath($compiled[$k].Parameters)).ToLowerInvariant()] = $k
            $map2[([IO.Path]::GetFullPath($compiled[$k].Template)).ToLowerInvariant()] = $k
        }
        # PSRule reads a linked template only from inside the working folder.
        Set-Location $tmp
        $started = Get-Date
        $results2 = Invoke-Scan -Paths @($rest | ForEach-Object { $compiled[$_].Parameters }) -Sarif (Join-Path $OutDir 'results-compiled.sarif')
        Write-Log ("Compiled pass: {0} entry points, {1} results in {2:N0} s" -f $rest.Count, $results2.Count, ((Get-Date) - $started).TotalSeconds)
        foreach ($r in $results2) {
            $e = Get-EntryOf $r $map2
            if ($e -and $r.TargetType -like 'Microsoft.*') { $mode[$e] = 'compiled' }
            $all.Add([pscustomobject]@{ Record = $r; Entry = $e; Mode = 'compiled' })
        }
    }
    foreach ($k in $entries.Keys) { if (-not $mode.ContainsKey($k)) { Write-Log "NOT SCANNED: $k" } }
} finally {
    Pop-Location
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}

# results.json holds one row per rule result.
$rows = @(foreach ($a in $all) {
    $r = $a.Record
    [pscustomobject]@{
        entryPoint     = $a.Entry
        unit           = if ($a.Entry) { $entries[$a.Entry] } else { $null }
        mode           = $a.Mode
        rule           = $r.RuleName
        outcome        = [string]$r.Outcome
        level          = [string]$r.Level
        severity       = $r.Info.Annotations.severity
        pillar         = $r.Tag.'Azure.WAF/pillar'
        targetType     = $r.TargetType
        targetName     = $r.TargetName
        resourceId     = $r.TargetObject.id
        reason         = (@($r.Reason) -join ' ')
        recommendation = $r.Recommendation
        help           = $r.Info.Annotations.'online version'
    }
})
[IO.File]::WriteAllText((Join-Path $OutDir 'results.json'), (ConvertTo-Json -InputObject $rows -Depth 5))

# summary.txt
$fail = @($rows | Where-Object outcome -eq 'Fail')
$err = @($rows | Where-Object outcome -eq 'Error')
$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$t = '') { [void]$sb.AppendLine($t) }
Add-Line "PSRule for Azure scan, $(Get-Date -Format 'yyyy-MM-dd HH:mm'), root $Root"
Add-Line ("PSRule {0}, PSRule.Rules.Azure {1}, baseline {2}, {3}" -f (Get-Module PSRule).Version, (Get-Module PSRule.Rules.Azure).Version, $Baseline, $bicepVersion)
Add-Line ("Entry points {0}; expanded by PSRule {1}, scanned from compiled JSON {2}, not scanned {3}" -f $entries.Count,
    @($mode.Values | Where-Object { $_ -eq 'bicep' }).Count, @($mode.Values | Where-Object { $_ -eq 'compiled' }).Count,
    @($entries.Keys | Where-Object { -not $mode.ContainsKey($_) }).Count)
Add-Line ("Results {0}: Pass {1}, Fail {2}, Error {3}" -f $rows.Count, @($rows | Where-Object outcome -eq 'Pass').Count, $fail.Count, $err.Count)
# infra/tenant/main.bicep composes the subscription units, so its results repeat theirs. Distinct counts
# take each (rule, resource type, resource name) once.
$key = { '{0}|{1}|{2}' -f $_.rule, $_.targetType, $_.targetName }
Add-Line ("Distinct failures (rule, resource type, resource name) {0}; distinct failing resources {1}" -f `
    @($fail | ForEach-Object $key | Sort-Object -Unique).Count,
    @($fail | ForEach-Object { "$($_.targetType)|$($_.targetName)" } | Sort-Object -Unique).Count)
Add-Line 'Results repeat where entry points overlap (infra/tenant/main.bicep contains the subscription units).'
Add-Line
Add-Line 'Failures per severity (results, distinct)'
foreach ($g in ($fail | Group-Object severity | Sort-Object Count -Descending)) { Add-Line ("  {0,6} {1,6}  {2}" -f $g.Count, @($g.Group | ForEach-Object $key | Sort-Object -Unique).Count, $g.Name) }
Add-Line
Add-Line 'Failures per pillar (results, distinct)'
foreach ($g in ($fail | Group-Object pillar | Sort-Object Count -Descending)) { Add-Line ("  {0,6} {1,6}  {2}" -f $g.Count, @($g.Group | ForEach-Object $key | Sort-Object -Unique).Count, $g.Name) }
Add-Line
Add-Line 'Failures per rule (results, distinct, severity, pillar, rule)'
foreach ($g in ($fail | Group-Object rule | Sort-Object Count -Descending)) {
    Add-Line ("  {0,6} {1,6}  {2,-12} {3,-24} {4}" -f $g.Count, @($g.Group | ForEach-Object $key | Sort-Object -Unique).Count, $g.Group[0].severity, $g.Group[0].pillar, $g.Name)
}
Add-Line
Add-Line 'Failures per entry point (count, security count, route, entry point)'
foreach ($g in ($fail | Group-Object entryPoint | Sort-Object Count -Descending)) {
    Add-Line ("  {0,6}  {1,6}  {2,-8}  {3}" -f $g.Count, @($g.Group | Where-Object pillar -eq 'Security').Count, $g.Group[0].mode, $g.Name)
}
Add-Line
Add-Line 'Security pillar failures, by rule, with the resources [unit]'
$sev = @{ Critical = 0; Important = 1; Awareness = 2 }
foreach ($g in ($fail | Where-Object pillar -eq 'Security' | Group-Object rule | Sort-Object { $sev[$_.Group[0].severity] }, { -$_.Count })) {
    Add-Line
    Add-Line ("{0} ({1}, {2} results)" -f $g.Name, $g.Group[0].severity, $g.Count)
    Add-Line ('  ' + $g.Group[0].recommendation)
    # One line per resource, with the units it appears in.
    foreach ($n in ($g.Group | Group-Object targetName | Sort-Object Name)) {
        Add-Line ('    {0}  [{1}]' -f $n.Name, (@($n.Group | ForEach-Object { $_.unit } | Sort-Object -Unique) -join ', '))
    }
}
if ($err.Count -gt 0) {
    Add-Line
    Add-Line 'Rule errors'
    foreach ($g in ($err | Group-Object rule)) { Add-Line ("  {0,6}  {1}" -f $g.Count, $g.Name) }
}
$notScanned = @($entries.Keys | Where-Object { -not $mode.ContainsKey($_) }).Count
$exitCode = if ($compileFailed -gt 0 -or $notScanned -gt 0 -or $err.Count -gt 0) { 1 } else { 0 }
Add-Line
Add-Line ("Exit code {0}: compile failures {1}, entry points not scanned {2}, rule errors {3}" -f $exitCode, $compileFailed, $notScanned, $err.Count)
[IO.File]::WriteAllText((Join-Path $OutDir 'summary.txt'), $sb.ToString())
Write-Log "Written to $OutDir"
exit $exitCode
