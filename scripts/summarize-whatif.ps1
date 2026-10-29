# Summarizes the what-if JSON files written by whatif-rg-sweep.sh / whatif-sub-sweep.sh (one file per scope).
# -Detail also lists every record that is not NoChange or Ignore, with its delta paths, for classification.
#
# In the demo subscription a resource group can have two resource group files, previewed one at a time (<slug>.json and
# <slug>.deploy-excluded.json, or <slug>-deploy-excluded.json when a preview is saved under its unit's name,
# for example rg-demo-network-deploy-excluded.json). Each preview reports the other file's resources as Ignore,
# so records are merged per resource ID within a resource group. A declared result (NoChange, Modify, ...) wins
# over Ignore, and every resource is counted once. A subscription preview (whatif-sub-sweep.sh) is one file per
# subscription or unit and already holds both files of a group, so nothing is merged there.
#
# A file that is empty or not JSON is a failed preview (a failed what-if writes nothing to the .json file and its
# reason to the .err file next to it), and so is a preview whose status is not Succeeded. Its row shows EMPTY,
# PARSE-ERROR or the status, and TOTALS ends with Failed=<n>, the number of such files.
# Runs unchanged under Windows PowerShell 5.1 and PowerShell 7 (Windows and Linux).
param(
  [Parameter(Mandatory = $true)][string]$Dir,
  [switch]$Detail
)
# A folder given with '\' is used with '/' on Linux.
if ([IO.Path]::DirectorySeparatorChar -ne '\') { $Dir = $Dir.Replace('\', '/') }
$rank = @{ Ignore = 0; NoChange = 1; Deploy = 1; Modify = 2; Create = 3; Delete = 3 }
$groups = [ordered]@{}   # base slug -> @{ Status; Diag; Records = @{ id -> change } }
$failed = 0              # files that hold no preview or a preview that did not succeed

# Files in character-code order of their names, the same under every PowerShell and operating system.
# The comparer is cast to IComparer so that PowerShell calls Array.Sort(Array, Array, IComparer), which sorts the
# items in place. With a StringComparer it picks the generic overload, passes a converted copy of the items, and
# only the keys end up sorted.
$files = @(Get-ChildItem -Path $Dir -Filter *.json)
$names = [string[]]@($files | ForEach-Object { $_.Name })
[Array]::Sort($names, $files, [Collections.IComparer][StringComparer]::Ordinal)
# A file is read by its byte order mark, as UTF-8 when it is valid UTF-8, and otherwise in the ANSI code page
# (Windows-1252 on Linux), the same under every PowerShell. az > file writes the ANSI code page on Windows and
# UTF-8 on Linux, and Get-Content alone would read such a file differently under 5.1 and 7.
$utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
function Read-TextFile([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -eq 0) { return }
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return $utf8Strict.GetString($b, 3, $b.Length - 3) }
  if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
  if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
  try { return $utf8Strict.GetString($b) } catch { if ([IO.Path]::DirectorySeparatorChar -eq '\') { return [Text.Encoding]::GetEncoding(0).GetString($b) } else { return [Text.Encoding]::GetEncoding(1252).GetString($b) } }
}
$files | ForEach-Object {
  $slug = [IO.Path]::GetFileNameWithoutExtension($_.Name)
  $base = $slug -replace '[.-]deploy-excluded$', ''
  # Records keep the order they were read in, so -Detail lists them in the same order under every PowerShell
  # (a hashtable has no fixed order in PowerShell 7). Keys are lower-case resource IDs.
  if (-not $groups.Contains($base)) { $groups[$base] = @{ Status = @(); Diag = 0; Records = (New-Object 'System.Collections.Generic.Dictionary[string,object]') } }
  $g = $groups[$base]
  $raw = Read-TextFile $_.FullName
  if ([string]::IsNullOrWhiteSpace($raw)) { $g.Status += "$slug=EMPTY"; $failed++; return }
  try { $obj = $raw | ConvertFrom-Json } catch { $g.Status += "$slug=PARSE-ERROR"; $failed++; return }
  $changes = $obj.changes
  if ($null -eq $changes) { $changes = $obj.properties.changes }
  $status = $obj.status
  if ($null -eq $status) { $status = $obj.properties.provisioningState }
  $g.Status += [string]$status
  if ([string]$status -ne 'Succeeded') { $failed++ }
  if ($obj.diagnostics) { $g.Diag += @($obj.diagnostics).Count }
  foreach ($ch in $changes) {
    $id = ([string]$ch.resourceId).ToLowerInvariant()
    $t = [string]$ch.changeType
    $r = if ($rank.ContainsKey($t)) { $rank[$t] } else { 2 }
    if (-not $g.Records.ContainsKey($id) -or $r -gt $g.Records[$id].Rank) {
      $g.Records[$id] = @{ Rank = $r; Type = $t; Change = $ch }
    }
  }
}

$rows = @(); $details = @()
$totals = [ordered]@{ NoChange = 0; Modify = 0; Ignore = 0; Create = 0; Delete = 0; Deploy = 0; Other = 0 }
foreach ($base in $groups.Keys) {
  $g = $groups[$base]
  $c = [ordered]@{ NoChange = 0; Modify = 0; Ignore = 0; Create = 0; Delete = 0; Deploy = 0; Other = 0 }
  foreach ($rec in $g.Records.Values) {
    if ($c.Contains($rec.Type)) { $c[$rec.Type]++ } else { $c['Other']++ }
    if ($rec.Type -ne 'NoChange' -and $rec.Type -ne 'Ignore') {
      $ch = $rec.Change
      $details += [pscustomobject]@{
        Slug = $base; ChangeType = $rec.Type; ResourceId = [string]$ch.resourceId
        Delta = if ($ch.delta) { (@($ch.delta) | ForEach-Object { "$($_.path):$($_.propertyChangeType)" }) -join '; ' } else { '' }
      }
    }
  }
  foreach ($k in @($c.Keys)) { $totals[$k] += $c[$k] }
  $rows += [pscustomobject]@{
    Slug = $base; Status = (($g.Status | Select-Object -Unique) -join ','); NoChange = $c.NoChange; Modify = $c.Modify
    Ignore = $c.Ignore; Create = $c.Create; Delete = $c.Delete; Diag = $g.Diag
  }
}
$rows | Format-Table -AutoSize | Out-String -Width 250
"TOTALS: " + (($totals.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '  ') + "  Failed=$failed"
if ($Detail) { $details | Format-Table -AutoSize -Wrap | Out-String -Width 400 }
