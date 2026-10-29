<#
.SYNOPSIS
  Offline checks to run before any what-if or deployment: deployment units, compile, lint, parameters,
  file layout, duplicate declarations.

.DESCRIPTION
  No Azure calls. Run it locally before pushing. The validate workflow (.github/workflows/mirror-validate.yml) runs it too.

    1. deploy/units.json and boundaries.json parse, and every unit's template and parameters file
       exists, enabled or not (a disabled unit is still checked, so it is ready the day it is enabled).
       Every entry of boundaries.json has the fields the deploy gate reads. A boundary has a type, a
       path, a non-empty changeTypes list and onDeploy exactly "inert" or "review" (a review boundary
       also has a note), a hold has a reason and an idPattern or a type with a namePattern, and an
       expected Ignore has a pattern and a reason. Every pattern is a valid regular expression.
    2. Compiles every entry point once: tenant/main.bicep, the 11 subscription mains, every file in
       the demo subscription's resource-groups folder (the routine group files, the deploy-excluded and hash-excluded
       ones, networkwatchers.bicep and the two vpn-gateways files), and every other unit template (the
       VPN gateway, budget, pilot and tenant templates). The group files of the other ten subscriptions
       are compiled through their main.bicep, because a module behind a false condition is still compiled.
       Linter rules at error level in bicepconfig.json fail the build, so this is also the lint gate.
    3. Builds every unit's parameters file and every parameters.verify.bicepparam (the subscription
       sweep previews with those) with az bicep build-params. A parameters file that reads a secure
       input through readEnvironmentVariable() with no default is reported and skipped when that
       variable is not set, because it cannot build without the secret.
    4. Layout (text checks, no compile). The group files are edited by hand, so this step keeps the
       rules the sweeps and the deploy script rely on:
       a. every demo resource-groups/<x>.bicep has <x>.bicepparam whose using line names './<x>.bicep'
          (the resource group sweep finds files only through their .bicepparam), except *.hash-excluded.bicep
          and the files another file calls as a module (networkwatchers.bicep from main.bicep, the two
          *.vpn-gateways.bicep files from network-gateways.bicep). Every .bicepparam there names a file that
          exists, and every demo group unit names the resource group its file is named after.
          For every unit in deploy/units.json with a .bicepparam parameters file, the using line of
          that file names the unit's template. deploy-unit.ps1 gives the Azure CLI only the .bicepparam
          file, and the CLI takes the template from that line. Every using line is read as Bicep reads
          it, so a line inside a comment or a multi-line string does not count.
       b. every module and import path in a .bicep under infra/ resolves to a file that exists, and none
          points at a file of another layout (see g).
       c. no resource name with '#' outside a *.hash-excluded.bicep file (what-if cannot preview such a
          name, and the whole preview of that group fails).
       d. a '// deploy-excluded:' marker appears only in a *.deploy-excluded.bicep file, every demo
          *.deploy-excluded.bicep file is the template of a unit, and that unit is listed in the
          measuredWith of the group's routine unit (otherwise the drift check never measures it). Every
          measuredWith and groupsDeclaredBy entry in deploy/units.json names a unit with exactly that
          name, case included, as deploy-unit.ps1 matches them.
       e. no '// Source:' or '// rg-member:' line is left under infra/subscriptions.
       f. every .bicep under infra/subscriptions, the group files included, is reached from a
          deploy/units.json template or a main.bicep through module lines. A file nothing reaches is
          never previewed or deployed.
       g. no file of another layout is present (the patterns are in $retiredPatterns below, nothing
          in this folder uses them).
       h. no .bicep or .bicepparam file under infra/ or pipelines/ has a line that ends in two carriage
          returns. Bicep counts each carriage return as a line break, so in such a file every warning
          names the wrong line and every '#disable-next-line' comment points at an empty line and is
          ignored. git also treats such a file as non-text and keeps the extra carriage returns.
    5. find-duplicate-declarations.ps1 on every subscription and resource group unit with its
       parameters file (ResourceDeployedMultipleTimes would fail that deployment), as deploy-unit.ps1
       does, and on the three subscriptions that keep a parameters.verify.bicepparam with that file, so
       the modules behind switches that are off in the routine file are checked too. Then the
       declarations of all units are merged, and the same resource (subscription, resource group, extension
       scope, type and name) declared by two units fails the run, for example a lock declared both in
       governance/locks/<group>.bicep (demo-subscription unit) and in the group's own resource group
       file, or a resource in both a routine group file and its deploy-excluded file. Names the checker
       cannot resolve take no part in the merge.

  Warnings are counted and printed per rule but do not fail the run.

.PARAMETER OutDir
  Optional folder for build logs (one per compiled file) and the duplicate check output.

.PARAMETER SkipDuplicates
  Skip step 5 (one compile per unit, it takes several minutes).

.NOTES
  Exit code 0 when every check passes, 1 otherwise. Runs unchanged under Windows PowerShell 5.1 and
  PowerShell 7 (Windows and Linux).
#>
[CmdletBinding()]
param(
  [string]$OutDir,
  [switch]$SkipDuplicates
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$infra = Join-Path $repo 'infra'
$mainFolder = 'demo'
$mainRgDir = [IO.Path]::Combine($infra, 'subscriptions', $mainFolder, 'resource-groups')
# The same script runs on Windows and Linux. Paths are built with the separator of the system. $pathCmp, used
# where a path is compared with the repository root, the demo folder or a unit's template, ignores case on
# Windows only, because Linux file names are case-sensitive. The other path comparisons below ignore case on every
# system.
$sep = [IO.Path]::DirectorySeparatorChar
$pathCmp = if ($sep -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
# The output folder is passed to the duplicate checker, a child process, so it is made a full path, written
# with '/' on Linux when it was given with '\' (for example "$env:RUNNER_TEMP\x").
if ($OutDir) {
  if ($sep -ne '\') { $OutDir = $OutDir.Replace('\', '/') }
  $OutDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutDir)
  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}
$failures = New-Object System.Collections.Generic.List[string]
$ruleCounts = @{}
# Windows (NTFS) lists the files of a folder sorted by name without case, and Linux lists them in the file
# system's own order. Every listing below is sorted the Windows way, so the output is in the same order on both.
# The comparer is cast to IComparer so that PowerShell calls Array.Sort(Array, Array, IComparer), which sorts the
# items in place. With a StringComparer it picks the generic overload, passes a converted copy of the items, and
# only the keys end up sorted.
function Get-SortedByPath($items) {
  # An empty listing binds as $null, so it is dropped and the result is an empty list, not one $null.
  $a = [object[]]@($items | Where-Object { $null -ne $_ })
  $keys = [string[]]@($a | ForEach-Object { $_.FullName })
  [Array]::Sort($keys, $a, [Collections.IComparer][StringComparer]::OrdinalIgnoreCase)
  return $a
}
# Get-ChildItem -Recurse -File in the Windows order, which is the files of a folder and then each subfolder in turn.
function Get-SortedFilesRecurse([string]$dir) {
  $items = Get-SortedByPath @(Get-ChildItem -LiteralPath $dir)
  $items | Where-Object { -not $_.PSIsContainer }
  foreach ($d in @($items | Where-Object { $_.PSIsContainer -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) })) { Get-SortedFilesRecurse $d.FullName }
}
# az on Windows (az.cmd starts Python with -I, which ignores PYTHONUTF8 and PYTHONIOENCODING) writes text in
# the ANSI code page of the system, and az on Linux writes UTF-8. So that a message with a character such as a
# dash reads the same on every host, az output is taken byte for byte (Latin-1) on Windows and decoded by
# ConvertFrom-AzLine, as UTF-8 when the bytes are valid UTF-8 and otherwise in the ANSI code page. On Linux it is
# read as UTF-8. Plain ASCII output is the same either way.
$azCapture = if ($sep -eq '\') { [Text.Encoding]::GetEncoding(28591) } else { New-Object System.Text.UTF8Encoding $false }
$azUtf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$azHighByte = New-Object regex ("[$([char]0x80)-$([char]0xFF)]")
function ConvertFrom-AzLine([string]$s, [bool]$captured) {
  if (-not ($sep -eq '\' -and $captured) -or -not $azHighByte.IsMatch($s)) { return $s }
  $b = $azCapture.GetBytes($s)
  try { return $azUtf8Strict.GetString($b) } catch { return [Text.Encoding]::GetEncoding(0).GetString($b) }
}
# Windows PowerShell 5.1 writes UTF8 with a byte order mark. PowerShell 7 writes the same bytes only with utf8BOM.
$utf8Bom = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
# A path written with '/' (units.json, module and using lines) as a path of this system.
function Get-SysPath([string]$rel) { return ($rel -replace '[\\/]', $sep) }

function Get-RepoPath([string]$rel) { [IO.Path]::GetFullPath((Join-Path $repo (Get-SysPath $rel))) }
function Get-RelPath([string]$full) {
  $f = [IO.Path]::GetFullPath($full)
  if ($f.StartsWith($repo + $sep, $pathCmp)) { $f = $f.Substring($repo.Length + 1) }
  return ($f -replace '\\', '/')
}

# The text of a Bicep or .bicepparam file as Bicep reads its statements. Comments (// and /* */) and the inside of
# multi-line strings ('''...''', with any quotes right after the closing three) become spaces, and line breaks stay. A single-quoted string stays as it is, with
# the expressions inside ${...}, so a comment marker inside it is text. So a using line inside a comment or a
# multi-line string is not taken for the one Bicep compiles.
function Get-BicepCodeText([string]$path) {
  $t = [IO.File]::ReadAllText($path)
  $n = $t.Length
  $sb = New-Object System.Text.StringBuilder $n
  # -1 marks a single-quoted string, 0 or more an expression inside ${...} with that many open braces.
  $stack = New-Object System.Collections.Generic.List[int]
  $q = [char]39; $bs = [char]92; $cr = [char]13; $lf = [char]10
  $i = 0
  while ($i -lt $n) {
    $c = $t[$i]
    if ($stack.Count -gt 0 -and $stack[$stack.Count - 1] -lt 0) {
      if ($c -eq $bs -and $i + 1 -lt $n) { [void]$sb.Append($c).Append($t[$i + 1]); $i += 2; continue }
      if ($c -eq $q) { $stack.RemoveAt($stack.Count - 1); [void]$sb.Append($c); $i++; continue }
      if ($c -eq [char]'$' -and $i + 1 -lt $n -and $t[$i + 1] -eq [char]'{') { $stack.Add(0); [void]$sb.Append('${'); $i += 2; continue }
      [void]$sb.Append($c); $i++; continue
    }
    $blankTo = -1
    if ($c -eq $q -and $i + 2 -lt $n -and $t[$i + 1] -eq $q -and $t[$i + 2] -eq $q) {
      $e = $t.IndexOf("'''", $i + 3, [StringComparison]::Ordinal)
      if ($e -lt 0) { $blankTo = $n }
      else {
        # Bicep keeps any quote right after the closing three in the string, so '''x'''' is the text x'.
        $blankTo = $e + 3
        while ($blankTo -lt $n -and $t[$blankTo] -eq $q) { $blankTo++ }
      }
    } elseif ($c -eq [char]'/' -and $i + 1 -lt $n -and $t[$i + 1] -eq [char]'/') {
      $blankTo = $t.IndexOfAny([char[]]@($cr, $lf), $i)
      if ($blankTo -lt 0) { $blankTo = $n }
    } elseif ($c -eq [char]'/' -and $i + 1 -lt $n -and $t[$i + 1] -eq [char]'*') {
      $e = $t.IndexOf('*/', $i + 2, [StringComparison]::Ordinal)
      $blankTo = if ($e -lt 0) { $n } else { $e + 2 }
    }
    if ($blankTo -ge 0) {
      for (; $i -lt $blankTo; $i++) { if ($t[$i] -eq $cr -or $t[$i] -eq $lf) { [void]$sb.Append($t[$i]) } else { [void]$sb.Append(' ') } }
      continue
    }
    if ($c -eq $q) { $stack.Add(-1) }
    elseif ($stack.Count -gt 0) {
      $top = $stack.Count - 1
      if ($c -eq [char]'{') { $stack[$top] = $stack[$top] + 1 }
      elseif ($c -eq [char]'}') { if ($stack[$top] -eq 0) { $stack.RemoveAt($top) } else { $stack[$top] = $stack[$top] - 1 } }
    }
    [void]$sb.Append($c); $i++
  }
  return $sb.ToString()
}
# The file a .bicepparam file names in its using line, as written there, or $null when it has none.
function Get-UsingPath([string]$path) {
  $m = [regex]::Match((Get-BicepCodeText $path), "(?m)^\s*using\s+'([^']+)'")
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

# Files of another layout. Nothing may use them. Step 4g lists any that are on disk.
$retiredPatterns = @(
  '^infra/typed/',
  "^infra/subscriptions/$mainFolder/candidates-[^/]*\.bicep$",
  "^infra/subscriptions/$mainFolder/verify-candidates\.bicep$",
  "^infra/subscriptions/$mainFolder/parameters\.verify\.bicepparam$",
  "^infra/subscriptions/$mainFolder/resource-groups/_report\.txt$",
  '^infra/subscriptions/.+/workload-candidates[^/]*\.bicep$',
  '^infra/subscriptions/.+/reviewed-[^/]*\.bicep$',
  '^infra/subscriptions/.+/(network-watchers|connection-monitors)\.bicep$',
  '^infra/subscriptions/subscription-composition\.bicep$',
  '^infra/modules/identity/',
  '^infra/parameters/resource-groups\.json$',
  '^infra/subscriptions/demo/automation-modules\.bicep$',
  '^infra/subscriptions/demo/secret-bearing-connections\.bicep$',
  '^scripts/(gen-rg\.ps1|find-orphan-typed-files\.ps1|README-gen-rg\.md)$'
)
function Test-Retired([string]$full) {
  $rel = Get-RelPath $full
  foreach ($p in $retiredPatterns) { if ($rel -imatch $p) { return $true } }
  return $false
}

# Environment variables a parameters file reads with readEnvironmentVariable('X') and no default, and that are not set.
function Get-UnsetSecureInputs([string]$paramFile) {
  $text = [IO.File]::ReadAllText($paramFile)
  return @([regex]::Matches($text, "readEnvironmentVariable\(\s*'([^']+)'\s*\)") | ForEach-Object { $_.Groups[1].Value } |
           Where-Object { -not [Environment]::GetEnvironmentVariable($_) } | Select-Object -Unique)
}

# Runs one az bicep command, counts diagnostics per rule, keeps the log, records a failure.
function Invoke-BicepStep([string[]]$azArgs, [string]$path, [string]$label) {
  $tmp = [IO.Path]::GetTempFileName()
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $prevEnc = [Console]::OutputEncoding
  $captured = $false
  try { [Console]::OutputEncoding = $azCapture; $captured = $true } catch { }
  try { $log = @(& az @azArgs --outfile $tmp 2>&1 | ForEach-Object { ConvertFrom-AzLine "$_" $captured }) }
  finally { if ($captured) { try { [Console]::OutputEncoding = $prevEnc } catch { } } }
  $code = $LASTEXITCODE
  $ErrorActionPreference = $prev
  Remove-Item $tmp -ErrorAction SilentlyContinue
  foreach ($l in $log) {
    if ($l -match ': (Warning|Error) ([A-Za-z0-9-]+):') {
      $k = "$($Matches[1]) $($Matches[2])"
      if ($script:ruleCounts.ContainsKey($k)) { $script:ruleCounts[$k]++ } else { $script:ruleCounts[$k] = 1 }
    }
  }
  $item = Get-Item -LiteralPath $path
  if ($OutDir) { Set-Content -LiteralPath (Join-Path $OutDir ($item.Directory.Name + '__' + $item.Name + '.log')) -Value $log -Encoding $utf8Bom }
  if ($code -ne 0) {
    $script:failures.Add("${label}: $path")
    $shown = @($log | Where-Object { $_ -match ': Error ' } | Select-Object -First 20)
    if ($shown.Count -eq 0) { $shown = @($log | Select-Object -Last 10) }
    $shown | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  }
}

# The entries of deploy/boundaries.json without a field the deploy gate reads, or with a value it cannot use, one
# line each. A boundary needs a type, a path, a non-empty changeTypes list and onDeploy exactly "inert" or "review"
# (so a misspelt "review" is caught before any preview), and a review boundary needs the note the gate prints. A
# hold needs a reason and either an idPattern or a type with a namePattern. An expected Ignore needs a pattern and
# a reason. Every pattern must be a valid regular expression.
function Get-BoundaryProblems($doc) {
  $problems = New-Object System.Collections.Generic.List[string]
  $text = { param($o, [string]$name) if ($null -eq $o) { return $null }; $p = $o.PSObject.Properties[$name]; if ($null -ne $p -and $p.Value -is [string] -and $p.Value.Trim()) { return $p.Value }; return $null }
  $regexOk = { param([string]$rx) try { $null = [regex]::Match('', $rx); return $true } catch { return $false } }
  # An empty file or a top-level list is reported as one problem, the same on both PowerShell hosts.
  if (-not ($doc -is [System.Management.Automation.PSCustomObject])) { $problems.Add('boundaries.json is empty or not a JSON object'); return $problems }
  foreach ($list in 'alwaysAcceptedPropertyChangeTypes', 'boundaries', 'holds', 'expectedIgnore') {
    $p = $doc.PSObject.Properties[$list]
    if ($null -eq $p -or -not ($p.Value -is [System.Array])) { $problems.Add("boundaries.json has no $list list") }
  }
  if ($problems.Count -gt 0) { return $problems }
  foreach ($ct in @($doc.alwaysAcceptedPropertyChangeTypes)) {
    if (-not ($ct -is [string]) -or -not $ct.Trim()) { $problems.Add('boundaries.json: alwaysAcceptedPropertyChangeTypes has an entry that is not a change type name') }
  }
  $i = 0
  foreach ($b in @($doc.boundaries)) {
    $at = "boundaries[$i]"
    if ($null -eq $b) { $problems.Add("boundaries.json: $at is empty"); $i++; continue }
    $t = & $text $b 'type'; $pa = & $text $b 'path'
    if ($t -and $pa) { $at = "boundaries[$i] ($t, $pa)" }
    if (-not $t) { $problems.Add("boundaries.json: $at has no type") }
    if (-not $pa) { $problems.Add("boundaries.json: $at has no path") }
    $cp = $b.PSObject.Properties['changeTypes']
    if ($null -eq $cp -or -not ($cp.Value -is [System.Array]) -or @($cp.Value).Count -eq 0) { $problems.Add("boundaries.json: $at has no changeTypes list with at least one change type") }
    elseif (@($cp.Value | Where-Object { -not ($_ -is [string]) -or -not $_.Trim() }).Count -gt 0) { $problems.Add("boundaries.json: $at has a changeTypes entry that is not a change type name") }
    $op = $b.PSObject.Properties['onDeploy']
    $od = if ($null -ne $op) { $op.Value } else { $null }
    if (-not ([string]::Equals([string]$od, 'inert', [StringComparison]::Ordinal) -or [string]::Equals([string]$od, 'review', [StringComparison]::Ordinal))) {
      $problems.Add("boundaries.json: $at has onDeploy '$od', which must be exactly 'inert' or 'review'")
    } elseif ($od -ceq 'review' -and -not (& $text $b 'note')) { $problems.Add("boundaries.json: $at is a review boundary with no note, and the gate prints the note for the operator") }
    $i++
  }
  $i = 0
  foreach ($h in @($doc.holds)) {
    $idp = & $text $h 'idPattern'; $np = & $text $h 'namePattern'
    if ($idp) { if (-not (& $regexOk $idp)) { $problems.Add("boundaries.json: holds[$i] has an idPattern that is not a valid regular expression") } }
    elseif ($np -and (& $text $h 'type')) { if (-not (& $regexOk $np)) { $problems.Add("boundaries.json: holds[$i] has a namePattern that is not a valid regular expression") } }
    else { $problems.Add("boundaries.json: holds[$i] has neither an idPattern nor a type with a namePattern") }
    if (-not (& $text $h 'reason')) { $problems.Add("boundaries.json: holds[$i] has no reason") }
    $i++
  }
  $i = 0
  foreach ($e in @($doc.expectedIgnore)) {
    $pt = & $text $e 'pattern'
    if (-not $pt) { $problems.Add("boundaries.json: expectedIgnore[$i] has no pattern") }
    elseif (-not (& $regexOk $pt)) { $problems.Add("boundaries.json: expectedIgnore[$i] has a pattern that is not a valid regular expression") }
    if (-not (& $text $e 'reason')) { $problems.Add("boundaries.json: expectedIgnore[$i] has no reason") }
    $i++
  }
  return $problems
}

# 1. Units and boundaries
Write-Host 'Checking deploy/units.json and boundaries.json'
$units = @()
$u = $null
try {
  $u = Get-Content -Raw -LiteralPath ([IO.Path]::Combine($repo, 'deploy', 'units.json')) | ConvertFrom-Json
  $bd = Get-Content -Raw -LiteralPath ([IO.Path]::Combine($repo, 'deploy', 'boundaries.json')) | ConvertFrom-Json
  $bdProblems = @(Get-BoundaryProblems $bd)
  foreach ($pr in $bdProblems) { $failures.Add($pr); Write-Host "  $pr" -ForegroundColor Red }
  Write-Host "  $(@($bd.boundaries).Count) boundaries, $(@($bd.holds).Count) holds and $(@($bd.expectedIgnore).Count) expected Ignore patterns checked, $($bdProblems.Count) problem(s)"
  $units = @($u.units)
  foreach ($unit in $units) {
    if (-not $unit.template) { $failures.Add("units.json: $($unit.name) has no template"); continue }
    foreach ($rel in @($unit.template, $unit.parameters)) {
      if ($rel -and -not (Test-Path -LiteralPath (Get-RepoPath $rel))) { $failures.Add("units.json: $($unit.name) points at missing $rel") }
    }
  }
  Write-Host "  $($units.Count) units checked ($(@($units | Where-Object { $_.enabled }).Count) enabled)"
} catch { $failures.Add("units/boundaries JSON: $($_.Exception.Message)") }

# 2. Compile every entry point once
$seen = @{}
$entries = New-Object System.Collections.Generic.List[string]
# An estate without tenant-scope code has no infra/tenant/main.bicep, so that entry point is taken only when it exists.
$tenantMain = [IO.Path]::Combine($infra, 'tenant', 'main.bicep')
$candidates = @(Get-ChildItem -LiteralPath $tenantMain -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) +
              @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'main.bicep'))) | ForEach-Object { $_.FullName }) +
              @(Get-SortedByPath (Get-ChildItem (Join-Path $mainRgDir '*.bicep')) | ForEach-Object { $_.FullName }) +
              @($units | Where-Object { $_.template -and (Test-Path -LiteralPath (Get-RepoPath $_.template)) } | ForEach-Object { Get-RepoPath $_.template })
foreach ($c in $candidates) {
  if (Test-Retired $c) { continue }
  $k = $c.ToLowerInvariant()
  if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $entries.Add($c) }
}
Write-Host "Compiling $($entries.Count) entry points"
foreach ($f in $entries) { Invoke-BicepStep @('bicep', 'build', '--file', $f) $f 'compile' }

# 3. Build parameters files
$seenP = @{}
$params = New-Object System.Collections.Generic.List[string]
$pCandidates = @($units | Where-Object { $_.parameters -and (Test-Path -LiteralPath (Get-RepoPath $_.parameters)) } | ForEach-Object { Get-RepoPath $_.parameters }) +
               @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'parameters.verify.bicepparam'))) | ForEach-Object { $_.FullName })
foreach ($c in $pCandidates) {
  if (Test-Retired $c) { continue }
  $k = $c.ToLowerInvariant()
  if (-not $seenP.ContainsKey($k)) { $seenP[$k] = $true; $params.Add($c) }
}
Write-Host "Building $($params.Count) parameters files"
$paramsSkipped = 0
foreach ($p in $params) {
  $unset = @(Get-UnsetSecureInputs $p)
  if ($unset.Count -gt 0) { $paramsSkipped++; Write-Host "  skipped $p (secure input $($unset -join ', ') not set)" -ForegroundColor Yellow; continue }
  Invoke-BicepStep @('bicep', 'build-params', '--file', $p) $p 'build-params'
}
Write-Host 'Diagnostics by rule (counted once per compiled file that includes the source):'
# Rules with the same count are listed by name, because a hashtable has no fixed order in PowerShell 7.
$ruleCounts.GetEnumerator() | Sort-Object @{ Expression = 'Value'; Descending = $true }, @{ Expression = 'Key'; Descending = $false } | ForEach-Object { Write-Host ("  {0,6}  {1}" -f $_.Value, $_.Key) }

# 4. Layout
Write-Host 'Checking the file layout'
$layoutStart = $failures.Count
function Add-LayoutFailure([string]$check, [string]$message) {
  $script:failures.Add("layout ${check}: $message")
}
# The same rule as whatif-rg-sweep.sh, case-insensitive with '_' and '-' ignored.
function Get-NormName([string]$n) { return ($n -replace '[_-]', '').ToLowerInvariant() }

$allInfraFiles = @(Get-SortedFilesRecurse $infra)
$bicepFiles = @($allInfraFiles | Where-Object { $_.Extension -ieq '.bicep' -and -not (Test-Retired $_.FullName) })
$texts = @{}
foreach ($f in $bicepFiles) { $texts[$f.FullName.ToLowerInvariant()] = [IO.File]::ReadAllText($f.FullName) }

# Module and import targets of one file, resolved to full paths. Registry and template spec references
# (br:, ts:, and aliases such as br/public:) are skipped.
function Get-FileRefs([string]$full) {
  $text = $script:texts[$full.ToLowerInvariant()]
  if ($null -eq $text) { $text = [IO.File]::ReadAllText($full) }
  $dir = Split-Path -Parent $full
  $refs = New-Object System.Collections.Generic.List[string]
  $ms = @([regex]::Matches($text, "(?m)^[ \t]*module[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+'([^']+)'")) +
        @([regex]::Matches($text, "(?m)^[ \t]*import[ \t][^\r\n]*?'([^']+\.(bicep|json))'"))
  foreach ($m in $ms) {
    $p = $m.Groups[1].Value
    if ($p -match '^(br|ts)(:|/[^/:]+:)') { continue }
    $refs.Add([IO.Path]::GetFullPath((Join-Path $dir (Get-SysPath $p))))
  }
  return $refs
}

# a. demo group files and their parameters files
$mainRgFiles = @(Get-SortedByPath (Get-ChildItem (Join-Path $mainRgDir '*.bicep')))
# A group file that another demo file calls as a module is deployed with that file's unit, not on its own.
$mainModuleTargets = @{}
foreach ($h in @(Get-SortedByPath (Get-ChildItem (Join-Path (Split-Path -Parent $mainRgDir) '*.bicep')))) {
  foreach ($mm in [regex]::Matches([IO.File]::ReadAllText($h.FullName), "(?m)^module\s+\w+\s+'\./resource-groups/([^']+)'")) { $mainModuleTargets[$mm.Groups[1].Value.ToLowerInvariant()] = $true }
}
foreach ($f in $mainRgFiles) {
  if ($f.Name -like '*.hash-excluded.bicep' -or $mainModuleTargets.ContainsKey($f.Name.ToLowerInvariant())) { continue }
  $x = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $pf = Join-Path $mainRgDir "$x.bicepparam"
  if (-not (Test-Path -LiteralPath $pf)) { Add-LayoutFailure 'a' "$(Get-RelPath $f.FullName) has no $x.bicepparam, so the resource group sweep never previews it"; continue }
  if ((Get-UsingPath $pf) -ne "./$x.bicep") { Add-LayoutFailure 'a' "$(Get-RelPath $pf) has no using './$x.bicep' line" }
}
foreach ($pf in @(Get-SortedByPath (Get-ChildItem (Join-Path $mainRgDir '*.bicepparam')))) {
  $usingRel = Get-UsingPath $pf.FullName
  if ($null -eq $usingRel) { Add-LayoutFailure 'a' "$(Get-RelPath $pf.FullName) has no using line"; continue }
  $t = [IO.Path]::GetFullPath((Join-Path $mainRgDir (Get-SysPath $usingRel)))
  if (-not (Test-Path -LiteralPath $t)) { Add-LayoutFailure 'a' "$(Get-RelPath $pf.FullName) names $usingRel, which does not exist" }
}
foreach ($unit in @($units | Where-Object { $_.kind -eq 'resourceGroup' -and $_.template })) {
  $t = Get-RepoPath $unit.template
  if (-not $t.StartsWith($mainRgDir + $sep, $pathCmp)) { continue }
  $slug = [IO.Path]::GetFileNameWithoutExtension($t) -replace '\.(deploy|hash)-excluded$', ''
  if ((Get-NormName $slug) -ne (Get-NormName ([string]$unit.resourceGroup))) {
    Add-LayoutFailure 'a' "unit $($unit.name) deploys $($unit.template) into $($unit.resourceGroup), but the file name and the group name differ"
  }
}
# The preview and the deployment of a unit with a .bicepparam file pass only that file to the Azure CLI, which
# compiles the template its using line names. So that line must name the unit's own template, or the unit would
# preview and deploy another file than the one units.json lists and this script compiles. Both paths are compared
# in full, without case on Windows and with case on Linux. A missing file is already reported in step 1.
foreach ($unit in @($units | Where-Object { $_.template -and $_.parameters -and ([string]$_.parameters) -like '*.bicepparam' })) {
  $pf = Get-RepoPath $unit.parameters
  if (-not (Test-Path -LiteralPath $pf -PathType Leaf)) { continue }
  $t = Get-RepoPath $unit.template
  $usingPath = Get-UsingPath $pf
  if ($null -eq $usingPath) { Add-LayoutFailure 'a' "unit $($unit.name) has the parameters file $($unit.parameters), which has no using line that names a file, so it does not name the unit's template $($unit.template)"; continue }
  $target = $null
  if ($usingPath -notmatch '^(br|ts)(:|/[^/:]+:)') {
    try { $target = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $pf) (Get-SysPath $usingPath))) } catch { $target = $null }
  }
  if ($null -eq $target -or -not [string]::Equals($target, $t, $pathCmp)) {
    $shown = if ($null -eq $target) { "'$usingPath'" } else { "'$usingPath' ($(Get-RelPath $target))" }
    Add-LayoutFailure 'a' "unit $($unit.name) has the parameters file $($unit.parameters), whose using line names $shown, but the unit's template is $($unit.template)"
  }
}

# b. Module and import paths
foreach ($f in $bicepFiles) {
  foreach ($r in (Get-FileRefs $f.FullName)) {
    $rel = Get-RelPath $r
    if ($rel -imatch '^infra/typed/') { Add-LayoutFailure 'b' "$(Get-RelPath $f.FullName) uses $rel, under infra/typed" }
    elseif (-not (Test-Path -LiteralPath $r)) { Add-LayoutFailure 'b' "$(Get-RelPath $f.FullName) uses $rel, which does not exist" }
    elseif (Test-Retired $r) { Add-LayoutFailure 'b' "$(Get-RelPath $f.FullName) uses $rel, a file of another layout" }
  }
}

# c. '#' in a resource name
foreach ($f in $bicepFiles) {
  if ($f.Name -like '*.hash-excluded.bicep') { continue }
  $lines = $texts[$f.FullName.ToLowerInvariant()] -split "`r?`n"
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^\s*//') { continue }
    if ($lines[$i] -match "\bname\s*:\s*'[^']*#") { Add-LayoutFailure 'c' "$(Get-RelPath $f.FullName):$($i + 1) has a name with '#'. It belongs in a *.hash-excluded.bicep file" }
  }
}

# d. deploy-excluded markers and units
# True when the list holds the name, compared character by character, case included, as deploy-unit.ps1 compares
# unit names. PowerShell's -ccontains compares by the rules of a language, which ignore some characters that do not
# show on screen, such as a zero-width space on PowerShell 7 and a soft hyphen on Windows PowerShell 5.1.
function Test-NameInList($list, [string]$name) {
  foreach ($x in @($list)) { if ($null -ne $x -and [string]::Equals([string]$x, $name, [StringComparison]::Ordinal)) { return $true } }
  return $false
}
foreach ($f in $bicepFiles) {
  if ($f.Name -like '*.deploy-excluded.bicep') { continue }
  $n = [regex]::Matches($texts[$f.FullName.ToLowerInvariant()], '//\s*deploy-excluded:').Count
  if ($n -gt 0) { Add-LayoutFailure 'd' "$(Get-RelPath $f.FullName) has $n '// deploy-excluded:' marker(s). Those resources belong in the group's *.deploy-excluded.bicep file" }
}
foreach ($f in @($mainRgFiles | Where-Object { $_.Name -like '*.deploy-excluded.bicep' })) {
  $own = @($units | Where-Object { $_.template -and (Get-RepoPath $_.template) -ieq $f.FullName })
  if ($own.Count -eq 0) { Add-LayoutFailure 'd' "$(Get-RelPath $f.FullName) is the template of no unit in deploy/units.json"; continue }
  $routine = Join-Path $mainRgDir (($f.Name -replace '\.deploy-excluded\.bicep$', '') + '.bicep')
  $main = @($units | Where-Object { $_.template -and (Get-RepoPath $_.template) -ieq $routine })
  if ($main.Count -eq 0) { Add-LayoutFailure 'd' "$(Get-RelPath $f.FullName) has no routine unit for $(Get-RelPath $routine)"; continue }
  foreach ($o in $own) {
    $mw = @()
    if ($main[0].PSObject.Properties['measuredWith']) { $mw = @($main[0].measuredWith) }
    if (-not (Test-NameInList $mw ([string]$o.name))) { Add-LayoutFailure 'd' "unit $($o.name) is not in the measuredWith list of unit $($main[0].name), so the drift check never measures it" }
  }
}
# deploy-unit.ps1 matches unit names character by character, case included, so a measuredWith or groupsDeclaredBy
# entry that names no unit with exactly that name would stop the drift check of its unit.
$unitNames = @($units | ForEach-Object { [string]$_.name })
foreach ($unit in $units) {
  foreach ($field in 'measuredWith', 'groupsDeclaredBy') {
    if (-not $unit.PSObject.Properties[$field]) { continue }
    foreach ($ref in @($unit.$field)) {
      if ($ref -and -not (Test-NameInList $unitNames ([string]$ref))) { Add-LayoutFailure 'd' "unit $($unit.name) names '$ref' in $field, and no unit in deploy/units.json has exactly that name (unit names are matched with their exact case)" }
    }
  }
}

# e. Comment lines of another layout
foreach ($f in @($bicepFiles | Where-Object { (Get-RelPath $_.FullName) -like 'infra/subscriptions/*' })) {
  $n = [regex]::Matches($texts[$f.FullName.ToLowerInvariant()], '(?m)^\s*//\s*(Source|rg-member):').Count
  if ($n -gt 0) { Add-LayoutFailure 'e' "$(Get-RelPath $f.FullName) has $n '// Source:' or '// rg-member:' line(s). Remove them" }
}

# f. Every file under infra/subscriptions is reached from a unit template or a main.bicep
$roots = @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'main.bicep'))) | ForEach-Object { $_.FullName }) +
         @(([IO.Path]::Combine($infra, 'tenant', 'main.bicep'))) +
         @($units | Where-Object { $_.template } | ForEach-Object { Get-RepoPath $_.template })
$reached = @{}
$queue = New-Object System.Collections.Generic.Queue[string]
foreach ($r in $roots) { if ((Test-Path -LiteralPath $r) -and -not $reached.ContainsKey($r.ToLowerInvariant())) { $reached[$r.ToLowerInvariant()] = $true; $queue.Enqueue($r) } }
while ($queue.Count -gt 0) {
  $cur = $queue.Dequeue()
  if (Test-Retired $cur) { continue }
  foreach ($r in (Get-FileRefs $cur)) {
    $k = $r.ToLowerInvariant()
    if ($reached.ContainsKey($k) -or -not (Test-Path -LiteralPath $r) -or (Test-Retired $r)) { continue }
    $reached[$k] = $true; $queue.Enqueue($r)
  }
}
$subFiles = @($bicepFiles | Where-Object { (Get-RelPath $_.FullName) -like 'infra/subscriptions/*' })
foreach ($f in $subFiles) {
  if (-not $reached.ContainsKey($f.FullName.ToLowerInvariant())) { Add-LayoutFailure 'f' "$(Get-RelPath $f.FullName) is not reached from any unit template or main.bicep" }
}
$rgFileCount = @($subFiles | Where-Object { $_.Directory.Name -eq 'resource-groups' }).Count

# g. Files of another layout
$retiredFiles = @($allInfraFiles | Where-Object { Test-Retired $_.FullName })
$scriptsDir = Join-Path $repo 'scripts'
if (Test-Path -LiteralPath $scriptsDir) { $retiredFiles += @(Get-SortedByPath (Get-ChildItem -LiteralPath $scriptsDir -File) | Where-Object { Test-Retired $_.FullName }) }
$typedCount = @($retiredFiles | Where-Object { (Get-RelPath $_.FullName) -like 'infra/typed/*' }).Count
if ($typedCount -gt 0) { Add-LayoutFailure 'g' "infra/typed ($typedCount files) is not part of the layout and nothing uses it. Remove the folder" }
foreach ($f in @($retiredFiles | Where-Object { (Get-RelPath $_.FullName) -notlike 'infra/typed/*' } | Sort-Object FullName)) {
  Add-LayoutFailure 'g' "$(Get-RelPath $f.FullName) is not part of the layout. Remove it (git rm)"
}

# h. Line endings. One line ending per line in every Bicep and parameters file
$eolFiles = @($allInfraFiles | Where-Object { $_.Extension -ieq '.bicep' -or $_.Extension -ieq '.bicepparam' })
$pipelinesDir = Join-Path $repo 'pipelines'
if (Test-Path -LiteralPath $pipelinesDir) {
  $eolFiles += @(Get-SortedFilesRecurse $pipelinesDir | Where-Object { $_.Extension -ieq '.bicep' -or $_.Extension -ieq '.bicepparam' })
}
foreach ($f in $eolFiles) {
  $text = [IO.File]::ReadAllText($f.FullName)
  $at = $text.IndexOf("`r`r")
  if ($at -ge 0) {
    $line = ([regex]::Matches($text.Substring(0, $at), "`n")).Count + 1
    Add-LayoutFailure 'h' "$(Get-RelPath $f.FullName):$line ends in two carriage returns. Save the file with one line ending per line"
  }
}
$layoutFailures = $failures.Count - $layoutStart
Write-Host "  $($bicepFiles.Count) Bicep files read, $($subFiles.Count) under infra/subscriptions ($rgFileCount group files), $($reached.Count) reached, $layoutFailures layout failure(s)"

# 5. Duplicate declarations, per unit and across units
$dupRuns = 0; $dupSkipped = 0; $crossKeys = 0; $crossCount = 0; $crossUnresolved = 0
if (-not $SkipDuplicates) {
  $csvDir = $OutDir
  $csvTemp = $null
  if (-not $csvDir) { $csvTemp = Join-Path ([IO.Path]::GetTempPath()) ('preflight-dups-' + [guid]::NewGuid().ToString('N')); $csvDir = $csvTemp }
  New-Item -ItemType Directory -Force -Path $csvDir | Out-Null
  $checker = Join-Path $PSScriptRoot 'find-duplicate-declarations.ps1'
  # The checker runs in a child process of the PowerShell that runs this script: powershell.exe for
  # Windows PowerShell 5.1, pwsh for PowerShell 7 (pwsh.exe on Windows). Where $PSHOME holds no such program
  # (PowerShell installed as a dotnet tool), the program running this script is used.
  $psExe = if ($PSVersionTable.PSEdition -ne 'Core') { Join-Path $PSHOME 'powershell.exe' } elseif ($sep -eq '\') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'pwsh' }
  if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = (Get-Process -Id $PID).Path }

  # Runs the checker once and returns the declarations CSV path, or $null when the run did not finish.
  function Invoke-DuplicateCheck([string]$label, [string]$template, [string]$paramFile) {
    $safe = $label -replace '[^A-Za-z0-9_.-]', '_'
    $csv = Join-Path $csvDir "duplicates__$safe.csv"
    if (Test-Path -LiteralPath $csv) { Remove-Item -LiteralPath $csv -Force }
    $chkArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $checker, '-Template', $template, '-DeclarationsCsv', $csv)
    if ($paramFile) { $chkArgs += @('-Parameters', $paramFile) } else { $chkArgs += '-NoParameters' }
    Write-Host "Duplicate declarations: $label"
    $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    $out = @(& $psExe @chkArgs 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = $prev
    $script:dupRuns++
    if ($OutDir) { Set-Content -LiteralPath (Join-Path $OutDir "duplicates__$safe.log") -Value $out -Encoding $utf8Bom }
    $res = @($out | Where-Object { $_ -like 'RESULT:*' } | Select-Object -Last 1)
    if ($res.Count -gt 0) { Write-Host "  $($res[0])" }
    # Exit 1 with a RESULT line means duplicates were found. Any other exit code but 0 means the check
    # could not run (compile or tool error).
    if ($code -ne 0 -and -not ($code -eq 1 -and $res.Count -gt 0)) {
      $script:failures.Add("duplicate check error: $label")
      @($out | Select-Object -Last 10) | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
      return $null
    }
    if ($code -ne 0) {
      $script:failures.Add("duplicates: $label")
      @($out | Where-Object { $_ -match 'ACTIVE|duplicate' } | Select-Object -First 20) | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    if (Test-Path -LiteralPath $csv) { return $csv }
    return $null
  }

  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($unit in @($units | Where-Object { $_.kind -in 'subscription', 'resourceGroup' -and $_.template })) {
    $t = Get-RepoPath $unit.template
    $p = $null; if ($unit.parameters) { $p = Get-RepoPath $unit.parameters }
    if (-not (Test-Path -LiteralPath $t) -or ($p -and -not (Test-Path -LiteralPath $p))) { continue }
    if ($p) {
      $unset = @(Get-UnsetSecureInputs $p)
      if ($unset.Count -gt 0) { $dupSkipped++; Write-Host "Duplicate declarations: $($unit.name) skipped (secure input $($unset -join ', ') not set)" -ForegroundColor Yellow; continue }
    }
    $csv = Invoke-DuplicateCheck $unit.name $t $p
    if (-not $csv) { continue }
    $subId = ([string]$u.subscriptions.($unit.subscription)).ToLowerInvariant()
    $unitRg = ''; if ($unit.PSObject.Properties['resourceGroup']) { $unitRg = ([string]$unit.resourceGroup).ToLowerInvariant() }
    foreach ($r in @(Import-Csv -LiteralPath $csv)) {
      if ($r.status -eq 'gated-off') { continue }
      if ($r.resolved -ne 'True') { $crossUnresolved++; continue }
      $scope = ([string]$r.scope).ToLowerInvariant()
      if ($scope -eq 'subscription') { $scope = "sub:$subId" }
      elseif ($scope -eq 'rg:<current>') { $scope = "rg:$subId/$unitRg" }
      elseif ($scope -match '^rg:([^/]+)$') { $scope = "rg:$subId/$($Matches[1])" }
      if ($scope -like '*<*') { $crossUnresolved++; continue }
      $key = ('{0}|{1}|{2}|{3}' -f $scope, $r.extScope, $r.type, $r.name).ToLowerInvariant()
      $file = [string]$r.declaredIn
      if ($r.viaFile -and $r.viaFile -ne $r.declaredIn) { $file = "$($r.viaFile) > $file" }
      $rows.Add([pscustomobject]@{ Key = $key; Unit = $unit.name; File = $file; Type = $r.type; Name = $r.name; Scope = $scope })
    }
  }
  # The subscriptions that keep a parameters.verify.bicepparam are checked with it too (switches on), not merged.
  foreach ($v in @(Get-SortedByPath (Get-ChildItem ([IO.Path]::Combine($infra, 'subscriptions', '*', 'parameters.verify.bicepparam'))) | Where-Object { -not (Test-Retired $_.FullName) })) {
    $usingRel = Get-UsingPath $v.FullName
    if ($null -eq $usingRel) { $failures.Add("duplicate check error: $(Get-RelPath $v.FullName) has no using line"); continue }
    $t = [IO.Path]::GetFullPath((Join-Path $v.DirectoryName (Get-SysPath $usingRel)))
    $label = (Split-Path -Leaf $v.DirectoryName) + '/parameters.verify.bicepparam'
    $unset = @(Get-UnsetSecureInputs $v.FullName)
    if ($unset.Count -gt 0) { $dupSkipped++; Write-Host "Duplicate declarations: $label skipped (secure input $($unset -join ', ') not set)" -ForegroundColor Yellow; continue }
    $null = Invoke-DuplicateCheck $label $t $v.FullName
  }

  # The check across units for one resource declared by two units.
  Write-Host "Duplicate declarations across units ($($rows.Count) declarations with a resolved name, while $crossUnresolved with a name or scope the checker cannot resolve take no part)"
  # Group-Object returns groups in first-seen order on Windows PowerShell 5.1 and sorted by name (culture order)
  # on PowerShell 7, so both groupings are put in ordinal name order before printing.
  $keyGroups = @($rows | Group-Object Key)
  if ($keyGroups.Count -gt 1) { $gk = [string[]]@($keyGroups | ForEach-Object { $_.Name }); [Array]::Sort($gk, $keyGroups, [Collections.IComparer][StringComparer]::Ordinal) }
  foreach ($g in $keyGroups) {
    $byUnit = @($g.Group | Group-Object Unit)
    if ($byUnit.Count -gt 1) { $uk = [string[]]@($byUnit | ForEach-Object { $_.Name }); [Array]::Sort($uk, $byUnit, [Collections.IComparer][StringComparer]::Ordinal) }
    if ($byUnit.Count -lt 2) { continue }
    $crossKeys++
    $first = $g.Group[0]
    $failures.Add("duplicates across units: $($first.Type) '$($first.Name)' in $($first.Scope)")
    Write-Host "  $($first.Type) '$($first.Name)' in $($first.Scope) is declared by:" -ForegroundColor Red
    foreach ($bu in $byUnit) { Write-Host "    unit $($bu.Name): $((@($bu.Group | ForEach-Object { $_.File } | Select-Object -Unique)) -join ', ')" -ForegroundColor Red }
  }
  $crossCount = $rows.Count
  Write-Host "  $crossKeys resource(s) declared by more than one unit"
  if ($csvTemp) { Remove-Item -LiteralPath $csvTemp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Host ''
Write-Host 'Summary:'
Write-Host "  $($units.Count) units, $($entries.Count) entry points compiled, $($params.Count) parameters files built ($paramsSkipped skipped for a secure input)"
Write-Host "  layout: $layoutFailures failure(s)"
if ($SkipDuplicates) { Write-Host '  duplicates: skipped' }
else { Write-Host "  duplicates: $dupRuns checker runs ($dupSkipped skipped for a secure input), $crossCount declarations merged ($crossUnresolved unresolved left out), $crossKeys declared by more than one unit" }

if ($failures.Count -gt 0) {
  Write-Host 'FAILED:' -ForegroundColor Red
  $failures | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
  exit 1
}
Write-Host 'All preflight checks passed.'
exit 0
