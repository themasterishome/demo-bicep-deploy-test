<#
.SYNOPSIS
  The pipeline's own code around the official deployment action: the repository checks of mirror-validate, the
  list of units a workflow works on, the deployment stack preview of one unit, and the drift issue.

.DESCRIPTION
  A deployment from the pipeline is a plan followed by an apply, both jobs of one run of mirror-deploy-unit on one
  commit of master. The plan signs in with the reader identity and previews the unit's deployment stack. The apply
  waits for the required reviewers of the unit's mirror-production or mirror-privileged environment and then
  creates or updates the stack with the action azure/bicep-deploy. This script holds only what that action and
  GitHub do not do themselves. The workflows call it in one of these modes:

    Hygiene        mirror-validate. Catches workflow files that could hand a deploy token to code nobody reviewed
                   (a check for mistakes, the controls are GitHub settings), and a job without the pipeline switch
                   (the repository variable MIRROR_PIPELINE_ENABLED). It also reads the two local actions under
                   .github/actions, and it reads every unit of deploy/units.json. Each unit must give a stack
                   row, the unit of a deploy-excluded file may be neither enabled nor marked deployed, and
                   stackDeletes stays off where it is not allowed. Nothing is compiled
    PortabilityScope
                   mirror-validate, portability job. Decides whether the job runs the full preflight on its runner
                   image. It does when the event is Run workflow or any event but a push or a pull request, when the
                   change touches scripts/, .github/scripts/, .github/actions/, bicepconfig.json, .gitattributes,
                   .gitignore or the validate workflow, when it adds a path whose name differs only in case from another path of the
                   tree, or when the changed files cannot be read. Writes the step output full
    InputCheck     mirror-pr, mirror-deploy-unit and mirror-drift, before the sign-in to Azure. Reads every Bicep
                   file of the checkout and refuses one that reads an environment variable, a registry module or a
                   file outside the repository, or uses a form this check does not read
    Units          mirror-deploy-unit, mirror-pr and mirror-drift, first job. Reads deploy/units.json and writes
                   the job matrix, one row for each unit with the scope, the name and the files of its deployment
                   stack. SELECT says which units: unit (the one named in UNIT, which must be enabled and may not
                   be the unit of a deploy-excluded file), deployed
                   (every unit marked "deployed": true) or pullRequest (the units whose files the pull request
                   changes)
    StackWhatIf    mirror-deploy-unit (plan job), mirror-pr and mirror-drift. Validates the deployment stack of
                   the unit in UNIT and previews it with the Azure CLI (az stack validate, az stack-whatif), at the
                   validation level a reader identity can run. Writes the preview to the job summary and to the
                   folder -Dir. Fails when the preview cannot be taken, and also when FAIL_ON_CHANGES is true
                   (the drift check) and the preview shows a change or carries a diagnostic message of Azure
    StackSummary   mirror-deploy-unit, apply job. Reads the stack after the action created or updated it and writes
                   its state and its resource counts to the job summary
    DriftReport    mirror-drift, report job. Opens, updates or closes the one drift issue from the results of the
                   drift jobs. No Azure

  The plan and the apply are jobs of the same run, so the apply deploys the commit the plan previewed, and GitHub
  holds the apply until a reviewer of the environment approves it on the run page, where the plan's summary is.

  With no -Mode the script only defines its functions, so the tests can dot-source it.
  A unit has a tier in deploy/units.json. A unit with no tier is production, and its deploy identity cannot write
  an Owner-class role assignment or a role definition. The privileged tier holds those, deployed by a separate
  identity through a separate environment with its own approvers. Tenant-kind units are privileged and deploy at
  management group scope. The preflight (scripts/preflight-validate.ps1, the delegated roles) fails a production
  unit that declares a role assignment of a role that is not on the list of its subscription.

  Values reach the script through environment variables that the workflow sets with env:, never through text
  pasted into the command line.

.NOTES
  Exit codes: 0 passed. 1 a check refused. 2 a tool or set-up error. Runs on Windows PowerShell 5.1 and on PowerShell 7
  on Windows and Linux.
#>
[CmdletBinding()]
param(
  [ValidateSet('', 'Hygiene', 'PortabilityScope', 'InputCheck', 'Units', 'StackWhatIf', 'StackSummary', 'DriftReport')]
  [string]$Mode = '',
  [string]$Dir
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------------------------
# Settings. Repository variables of the same name override the numbers (Settings > Secrets and variables >
# Actions > Variables). The workflows pass them in through env:.
# ---------------------------------------------------------------------------------------------------------------
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Files that every unit is compiled with. A change there needs a preview of every unit, not of one.
$script:GlobalFiles = @('bicepconfig.json')
# A job matrix holds at most 256 jobs (GitHub's limit), so a run that needs more is refused and not cut short.
$script:MaxMatrixJobs = 256
# The account that writes as the workflow's own token. Only its issues are the pipeline's own.
$script:BotLogin = 'github-actions[bot]'
# The longest preview text a job summary shows. GitHub accepts 1 MiB for the summary of one step. The whole text is
# in the artifact of the job.
$script:MaxSummaryChars = 400000
# The findings of one unit that the drift issue lists. The artifact of the unit's job holds all of them.
$script:MaxFindingsPerUnit = 40
# Every deployment stack of the pipeline is named mirror-<unit>, and its previews are kept for the shortest time
# Azure accepts, one hour. Azure deletes a preview after that time. The removal is not immediate and can follow
# some hours later.
$script:StackPrefix = 'mirror-'
$script:WhatIfRetention = 'PT1H'
# The scopes whose units never delete what leaves the template: the tenant units, whose templates place
# subscriptions under management groups, and the subscription of the API Management platform. A line leaves this
# list in a reviewed change when IT agrees that a unit of the scope may delete.
$script:NoStackDeletesScopes = @('tenant', 'fdm-apim')
# The diagnostic messages of one preview that the job summary and the drift issue list.
$script:MaxDiagnostics = 20
# The only actions a workflow may use, each pinned to a full commit SHA. azure/bicep-deploy is Microsoft's action
# for Bicep deployments and deployment stacks, and only the apply job of mirror-deploy-unit.yml uses it.
$script:AllowedActions = @('actions/checkout', 'actions/upload-artifact', 'actions/download-artifact', 'azure/login', 'azure/bicep-deploy')
# The only local actions a workflow may use, with their folders under .github/actions. Each holds run steps only.
$script:AllowedLocalActions = @('./.github/actions/runner-check', './.github/actions/setup-bicep')
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
# The runner images a job may run on, the two the scripts and the pinned tools are checked on. A -latest label
# moves to a new system without a change in the repository, and a repository variable changes without a review.
# So a job names one of the two images, or one of the two expressions below. They map the repository variable
# MIRROR_RUNNER to the two images and nothing else. The first gives ubuntu-24.04 when the variable is
# ubuntu-24.04 and windows-2025 for any other value or none. The second gives the other image, for the
# portability job. The runner check, the step after the checkout in every job, stops the job on any other runner.
$script:RunnerImages = @('windows-2025', 'ubuntu-24.04')
$script:RunnerChoices = @(
  '${{ vars.MIRROR_RUNNER == ''ubuntu-24.04'' && ''ubuntu-24.04'' || ''windows-2025'' }}',
  '${{ vars.MIRROR_RUNNER == ''ubuntu-24.04'' && ''windows-2025'' || ''ubuntu-24.04'' }}'
)
$script:RunnerCheckStep = 'Runner check'
# The pipeline switch. Every job's condition starts with it, so every job is skipped and no runner starts until IT
# sets the repository variable MIRROR_PIPELINE_ENABLED to true after the setup.
$script:PipelineSwitch = 'vars.MIRROR_PIPELINE_ENABLED == ''true'''
# ConvertFrom-Json in PowerShell 7 turns a text that looks like a date into a DateTime, and Windows PowerShell 5.1
# keeps it as text. -DateKind String (PowerShell 7.5 and later) keeps the text, so a field such as a reason
# that looks like a time reads the same on every host. Every ConvertFrom-Json in this file passes these arguments.
$MirrorJsonArgs = @{}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $MirrorJsonArgs['DateKind'] = 'String' }
# The path separator of the system the script runs on, and how paths compare there. Windows ignores case in file
# names and Linux does not.
$script:Sep = [IO.Path]::DirectorySeparatorChar
$script:PathCompare = if ($script:Sep -eq '\') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }


# ---------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------

# Strict mode throws on a missing property. JSON from git, GitHub and Azure omits fields freely.
function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  if ($obj -is [System.Collections.IDictionary]) { if ($obj.Contains($name)) { return $obj[$name] } else { return $null } }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

# Unit names, file names, IDs and commits compare by their exact characters. The -eq, -ceq, -contains and
# Sort-Object -Unique of PowerShell compare by culture, and on PowerShell 7 that ignores characters such as a
# zero-width space, so two names that only look the same would match there and not on Windows PowerShell 5.1.
function Test-Same([string]$A, [string]$B) { return [string]::Equals($A, $B, [StringComparison]::Ordinal) }

function Test-InList($List, [string]$Item) {
  foreach ($x in @($List)) { if ($null -ne $x -and [string]::Equals([string]$x, $Item, [StringComparison]::Ordinal)) { return $true } }
  return $false
}

function Get-EnvValue([string]$Name, [string]$Default = '') {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
  return $v.Trim()
}

# A repository path as git and deploy/units.json write it (forward slashes), in the form of the running system.
function ConvertTo-NativePath([string]$Path) {
  return $Path.Replace('\', '/').Replace('/', [string]$script:Sep)
}

# A file or folder of the repository, from its path relative to $Root.
function Join-RepoPath([string]$Root, [string]$RelativePath) {
  return (Join-Path $Root (ConvertTo-NativePath $RelativePath))
}

# The full path of $Root with one separator at its end, so a prefix test cannot match a sibling folder.
function Get-RootPrefix([string]$Root) {
  return ([IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/')) + $script:Sep)
}

function ConvertTo-CompactJson($Value) {
  return (ConvertTo-Json -InputObject $Value -Depth 20 -Compress)
}

# A step output. A value with a line break uses the delimiter form GitHub documents for multi-line values.
function Set-StepOutput([string]$Name, [string]$Value) {
  $file = Get-EnvValue 'GITHUB_OUTPUT'
  if (-not $file) { Write-Host "output $Name=$Value"; return }
  if ($Value -match "[`r`n]") {
    $d = 'EOF_' + [guid]::NewGuid().ToString('N')
    [IO.File]::AppendAllText($file, "$Name<<$d`n$Value`n$d`n", $script:Utf8NoBom)
  } else {
    [IO.File]::AppendAllText($file, "$Name=$Value`n", $script:Utf8NoBom)
  }
}

function Write-Summary([string[]]$Lines) {
  $file = Get-EnvValue 'GITHUB_STEP_SUMMARY'
  $text = (@($Lines) -join "`n") + "`n"
  if (-not $file) { Write-Host $text; return }
  [IO.File]::AppendAllText($file, $text, $script:Utf8NoBom)
}

# One line of text for the log. The runner reads workflow commands (lines that start with ::) line by line and
# treats a lone carriage return or a Unicode line separator as a line end too, so every kind of line break in
# echoed text, such as a field name from a request, becomes ' | ' and cannot start a command line.
function ConvertTo-OneLine([string]$Text) {
  return ($Text -replace '[\r\n\u0085\u2028\u2029]+', ' | ')
}

# Free text for a job summary, which GitHub renders as Markdown. It is one line, has its backticks removed, and is
# written as a code span, so it cannot make a link, a heading, a table cell or HTML.
function ConvertTo-CodeSpan([string]$Text) {
  return ('`' + ((ConvertTo-OneLine $Text) -replace '`', '') + '`')
}

# Ends the mode with an error annotation and a summary line. Exit 1 is a refusal, 2 a tool or set-up error.
function Stop-Check([string]$Message, [int]$Code = 1) {
  $one = ConvertTo-OneLine $Message
  Write-Host "::error::$one"
  Write-Summary @("**Stopped (exit $Code):** $one")
  exit $Code
}

function Stop-WithErrors([string]$Title, [string[]]$Errors, [int]$Code = 1) {
  foreach ($e in $Errors) { Write-Host "::error::$(ConvertTo-OneLine $e)" }
  Write-Summary (@("**$Title**", '') + @($Errors | ForEach-Object { "- $_" }))
  exit $Code
}

# Runs a program and keeps stdout and stderr apart. Windows PowerShell turns native stderr into error records,
# so the preference is relaxed for the call itself, and output is read as UTF-8.
function Invoke-Native([string]$Exe, [string[]]$ArgList, [switch]$AllowFailure) {
  $prevEap = $ErrorActionPreference
  $prevEnc = $null
  try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = $script:Utf8NoBom } catch { }
  try {
    $ErrorActionPreference = 'Continue'
    $all = & $Exe @ArgList 2>&1
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $prevEap
    if ($null -ne $prevEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
  }
  $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" })
  $err = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { "$_" }) -join "`n"
  if ($code -ne 0 -and -not $AllowFailure) {
    throw ("{0} {1} failed (exit {2}): {3}" -f $Exe, ($ArgList[0..([Math]::Min(2, $ArgList.Count - 1))] -join ' '), $code, $err)
  }
  return [pscustomobject]@{ Code = $code; Out = $out; Err = $err }
}

function Invoke-Git([string[]]$GitArgs, [switch]$AllowFailure) {
  return Invoke-Native 'git' (@('-C', $script:RepoRoot) + $GitArgs) -AllowFailure:$AllowFailure
}

# The text of one file at one commit, or $null when the file is not there.
function Get-GitText([string]$Commit, [string]$Path) {
  $r = Invoke-Git @('show', "${Commit}:$Path") -AllowFailure
  if ($r.Code -ne 0) { return $null }
  return ($r.Out -join "`n")
}

function Test-GitCommit([string]$Commit) {
  return ((Invoke-Git @('cat-file', '-e', "$Commit^{commit}") -AllowFailure).Code -eq 0)
}

# Files that differ between two commits, as objects with Status (A, M, D, T) and Path. Renames are listed as a
# delete and an add, so a renamed file reads as a deleted one. -ThreeDot compares with the merge base,
# as a pull request does.
function Get-GitChanges([string]$From, [string]$To, [switch]$ThreeDot) {
  $range = if ($ThreeDot) { "$From...$To" } else { $From }
  $a = @('diff', '--name-status', '--no-renames', $range)
  if (-not $ThreeDot) { $a += $To }
  return @(ConvertFrom-NameStatus (Invoke-Git $a).Out)
}

# GitHub REST through the GitHub CLI, signed in with GH_TOKEN. -Paginate reads every page.
function Invoke-GhApi([string]$Path, [switch]$Paginate) {
  $a = @('api', '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28')
  if ($Paginate) { $a += @('--paginate', '--slurp') }
  $a += $Path
  $r = Invoke-Native 'gh' $a -AllowFailure
  if ($r.Code -ne 0) { throw "gh api $Path failed (exit $($r.Code)): $($r.Err)" }
  $doc = ConvertFrom-Json @MirrorJsonArgs -InputObject ($r.Out -join "`n")
  if (-not $Paginate) { return $doc }
  $items = New-Object System.Collections.Generic.List[object]
  foreach ($page in @($doc)) { foreach ($i in @($page)) { if ($null -ne $i) { $items.Add($i) } } }
  # Returned item by item, so a caller collects them with @().
  return $items.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------
# Pure functions, with no git and no network. The tests call these.
# ---------------------------------------------------------------------------------------------------------------
function ConvertFrom-NameStatus([string[]]$Lines) {
  foreach ($l in @($Lines)) {
    if (-not $l) { continue }
    $parts = $l -split "`t"
    if ($parts.Count -lt 2) { continue }
    [pscustomobject]@{ Status = $parts[0].Substring(0, 1); Path = $parts[$parts.Count - 1] }
  }
}

# The tier of a unit: 'production' when deploy/units.json gives it none, 'privileged' when it says so, and always
# 'privileged' for a tenant-kind unit. Any other value gives $null, so a misspelled tier is refused by the callers
# and never falls back to production.
function Get-UnitTier($UnitDef) {
  $t = Get-Prop $UnitDef 'tier'
  $kind = [string](Get-Prop $UnitDef 'kind')
  if ($null -eq $t) { if ($kind -ceq 'tenant') { return 'privileged' } else { return 'production' } }
  if ($t -is [string] -and $t -ceq 'privileged') { return 'privileged' }
  return $null
}

# The scope name of a unit: its subscription folder, or 'tenant' for a tenant-kind unit.
function Get-UnitScope($UnitDef) {
  if ([string](Get-Prop $UnitDef 'kind') -ceq 'tenant') { return 'tenant' }
  return [string](Get-Prop $UnitDef 'subscription')
}

function Find-UnitDef($UnitsDoc, [string]$Name) {
  $m = @(@(Get-Prop $UnitsDoc 'units') | Where-Object { Test-Same ([string](Get-Prop $_ 'name')) $Name })
  if ($m.Count -ne 1) { return $null }
  return $m[0]
}

# ---------------------------------------------------------------------------------------------------------------
# Bicep files: the files a unit is compiled from, and the inputs a branch's Bicep may not use.
# ---------------------------------------------------------------------------------------------------------------

# Bicep text with its comments (// and /* */) turned into spaces. Line breaks stay, so a position still has its
# line number. Strings stay, with the expressions inside ${...}, and a multi-line string ('''...''') stays as it
# is. A multi-line string ends at the first three quotes and takes any quotes right after them, as Bicep reads it,
# so '''x'''' is the text x'. Comments are read the way Bicep reads them, so a comment marker inside a string is text, and code after a
# block comment on the same line is code. A multi-line string stays, because the input check refuses one where a
# path is expected.
if (-not ('MirrorPipeline.BicepText' -as [type])) {
  Add-Type -Language CSharp -TypeDefinition @'
namespace MirrorPipeline {
  public static class BicepText {
    public static string BlankComments(string t) {
      System.Text.StringBuilder sb = new System.Text.StringBuilder(t.Length);
      // -1 marks a single-quoted string, 0 or more an expression inside ${...} with that many open braces.
      System.Collections.Generic.List<int> stack = new System.Collections.Generic.List<int>();
      int i = 0, n = t.Length;
      while (i < n) {
        char c = t[i];
        if (stack.Count > 0 && stack[stack.Count - 1] < 0) {
          if (c == '\\' && i + 1 < n) { sb.Append(c); sb.Append(t[i + 1]); i += 2; continue; }
          if (c == '\'') { stack.RemoveAt(stack.Count - 1); sb.Append(c); i++; continue; }
          if (c == '$' && i + 1 < n && t[i + 1] == '{') { stack.Add(0); sb.Append("${"); i += 2; continue; }
          sb.Append(c); i++; continue;
        }
        if (c == '\'') {
          if (i + 2 < n && t[i + 1] == '\'' && t[i + 2] == '\'') {
            int e = t.IndexOf("'''", i + 3, System.StringComparison.Ordinal);
            int stop = e < 0 ? n : e + 3;
            // Bicep keeps any quote right after the closing three in the string, so '''x'''' is the text x'.
            if (e >= 0) { while (stop < n && t[stop] == '\'') { stop++; } }
            sb.Append(t, i, stop - i); i = stop; continue;
          }
          stack.Add(-1); sb.Append(c); i++; continue;
        }
        if (c == '/' && i + 1 < n && t[i + 1] == '/') {
          while (i < n && t[i] != '\n' && t[i] != '\r') { sb.Append(' '); i++; }
          continue;
        }
        if (c == '/' && i + 1 < n && t[i + 1] == '*') {
          int e = t.IndexOf("*/", i + 2, System.StringComparison.Ordinal);
          int stop = e < 0 ? n : e + 2;
          for (; i < stop; i++) { char d = t[i]; sb.Append(d == '\n' || d == '\r' ? d : ' '); }
          continue;
        }
        if (stack.Count > 0) {
          int top = stack.Count - 1;
          if (c == '{') { stack[top] = stack[top] + 1; }
          else if (c == '}') { if (stack[top] == 0) { stack.RemoveAt(top); } else { stack[top] = stack[top] - 1; } }
        }
        sb.Append(c); i++;
      }
      return sb.ToString();
    }
  }
}
'@
}

function Get-BicepCodeText([string]$FullPath) {
  return [MirrorPipeline.BicepText]::BlankComments([IO.File]::ReadAllText($FullPath))
}

# The files one Bicep file names: module, using, extends and import sources. Read from the text without comments
# and with no line anchor, so a reference after a block comment or over several lines is found. A string that is
# not a reference only adds a file to the set, which costs nothing. Registry references (br:, ts:) are left out.
function Get-BicepReferences([string]$FullPath) {
  $refs = @()
  if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return $refs }
  $dir = Split-Path -Parent $FullPath
  $text = Get-BicepCodeText $FullPath
  foreach ($m in [regex]::Matches($text, "(?:\bmodule\s+[A-Za-z_][A-Za-z0-9_]*\s+|\busing\s+|\bextends\s+|\bfrom\s+|\bimport\s+)'([^'\\]+)'")) {
    $p = $m.Groups[1].Value
    if ($p -match '^(?:br|ts)[:/]') { continue }
    try { $refs += [IO.Path]::GetFullPath((Join-Path $dir (ConvertTo-NativePath $p))) } catch { }
  }
  return $refs
}

function ConvertTo-RepoPath([string]$FullPath, [string]$Root) {
  $r = Get-RootPrefix $Root
  if ($FullPath.StartsWith($r, $script:PathCompare)) { return $FullPath.Substring($r.Length).Replace('\', '/').ToLowerInvariant() }
  return $FullPath.Replace('\', '/')
}

# Files each unit reads: its template, its parameters file, and every file those reach through references.
# Paths are relative to the repository root, forward slashes, lower case. A path outside the repository keeps its
# full form and its case (a drive letter or a leading slash), so it can still be found on Linux.
function Get-UnitFiles($UnitsDoc, [string]$Root) {
  $map = @{}
  foreach ($u in @(Get-Prop $UnitsDoc 'units')) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($f in @((Get-Prop $u 'template'), (Get-Prop $u 'parameters'))) {
      if ($f) { try { $queue.Enqueue([IO.Path]::GetFullPath((Join-RepoPath $Root ([string]$f)))) } catch { } }
    }
    while ($queue.Count -gt 0) {
      $full = $queue.Dequeue()
      if (-not $set.Add((ConvertTo-RepoPath $full $Root))) { continue }
      foreach ($r in @(Get-BicepReferences $full)) { $queue.Enqueue($r) }
    }
    $map[[string]$u.name] = $set
  }
  return $map
}

# The units a code change touches. Returns the units to preview and notes for the job summary. A change to a file
# that every unit is compiled with (bicepconfig.json in any folder) previews no unit. The preview job takes
# bicepconfig.json from master, so a preview could not show the effect of the changed copy. The preflight job
# compiles and lints every unit with it, and a code owner reviews it. Bicep reads the bicepconfig.json nearest to
# each file, so one in a subfolder applies to every file below it.
# No standard tool names the deployments a changed Bicep file belongs to without compiling every unit, so the
# units come from the references the files hold (module, using, the load functions).
function Resolve-AffectedUnits([string[]]$ChangedPaths, $UnitsDoc, $UnitFiles, [string[]]$ChangedUnitEntries = @()) {
  $preview = New-Object System.Collections.Generic.List[string]
  $notes = New-Object System.Collections.Generic.List[string]
  $all = $false
  $hits = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($p in @($ChangedPaths)) {
    if (-not $p) { continue }
    $lp = $p.Replace('\', '/').ToLowerInvariant()
    if ($script:GlobalFiles -contains $lp -or $lp.EndsWith('/bicepconfig.json')) {
      $all = $true
      $notes.Add("$p changed. Every unit is compiled with it. The preview job takes bicepconfig.json from master, so a preview cannot show the effect of this copy. The preflight job compiles and lints every unit with it, and a code owner reviews it.")
      continue
    }
    $found = $false
    foreach ($u in @(Get-Prop $UnitsDoc 'units')) {
      $n = [string]$u.name
      if ($UnitFiles.ContainsKey($n) -and $UnitFiles[$n].Contains($lp)) { [void]$hits.Add($n); $found = $true }
    }
    if (-not $found -and $lp.StartsWith('infra/')) { $notes.Add("$p is reached by no unit in deploy/units.json.") }
  }
  foreach ($n in @($ChangedUnitEntries)) { if ($n) { [void]$hits.Add($n) } }
  foreach ($u in @(Get-Prop $UnitsDoc 'units')) {
    $n = [string]$u.name
    if (-not $hits.Contains($n)) { continue }
    $preview.Add($n)
  }
  if ($all -and $preview.Count -gt 0) { $preview.Clear() }
  return [pscustomobject]@{ preview = [string[]]$preview.ToArray(); notes = [string[]]$notes.ToArray(); all = $all }
}

# Unit entries that differ between two copies of deploy/units.json (added or changed), so enabling a unit
# previews it.
function Get-ChangedUnitEntries($OldDoc, $NewDoc) {
  $old = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
  foreach ($u in @(Get-Prop $OldDoc 'units')) { $old[[string]$u.name] = (ConvertTo-CompactJson $u) }
  $changed = @()
  foreach ($u in @(Get-Prop $NewDoc 'units')) {
    $n = [string]$u.name
    if (-not $old.ContainsKey($n) -or -not (Test-Same $old[$n] (ConvertTo-CompactJson $u))) { $changed += $n }
  }
  return $changed
}

# Inputs in Bicep files that could carry the job's sign-in or other runner files into a preview. A job that holds
# the reader token runs the Bicep of a branch, and Bicep can read an environment variable (readEnvironmentVariable,
# and the job's environment holds what is needed to ask for a new token), fetch a module from a registry with the
# job's Azure sign-in, and load any file the runner can read (loadTextContent and the other load functions). The
# routine units use none of these, so Bicep from a branch that adds one is not run with the token. The forms this
# check cannot read safely are refused too, because the routine units use none of them: a multi-line string, a
# \u{...} escape, import, extends and extension statements, and a load whose path is anything but plain letters,
# digits, dots, dashes, underscores and forward slashes. Comments are left out the way Bicep reads them. $RepoPaths
# are paths relative to $Root. Returns one line per finding.
function Find-UnsafeBicepInputs([string[]]$RepoPaths, [string]$Root) {
  $findings = @()
  $rootFull = Get-RootPrefix $Root
  $rules = @(
    @{ rx = '\breadEnvironmentVariable\s*\('; what = 'reads an environment variable' },
    @{ rx = '\bexternalInput\s*\('; what = 'asks the deploying tool for an external input' },
    @{ rx = '''(?:br|ts)[:/]'; what = 'uses a module from a registry' },
    @{ rx = '(?m)^[ \t]*import\b'; what = 'imports from another file, which the routine units never do' },
    @{ rx = '(?m)^[ \t]*extends\b'; what = 'extends another parameters file, which the routine units never do' },
    @{ rx = '(?m)^[ \t]*extension\b'; what = 'declares a Bicep extension, which the routine units never do' },
    @{ rx = ''''''''; what = 'uses a multi-line string, which the routine units never do' },
    @{ rx = '\\u\{'; what = 'uses a \u{...} escape, which the routine units never do' }
  )
  foreach ($rp in @(@($RepoPaths) | Where-Object { $_ } | Sort-Object -Unique)) {
    if ($rp -notmatch '\.(bicep|bicepparam)$') { continue }
    $full = Join-RepoPath $Root $rp
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $dir = Split-Path -Parent $full
    $text = Get-BicepCodeText $full
    foreach ($rule in $rules) {
      foreach ($m in [regex]::Matches($text, $rule.rx)) { $findings += "${rp} line $(Get-LineNumber $text $m.Index) $($rule.what)" }
    }
    foreach ($m in [regex]::Matches($text, '\b(?<fn>load[A-Z][A-Za-z0-9_]*)\s*\(\s*(?<arg>[^,)]*)')) {
      $n = Get-LineNumber $text $m.Index
      if (@('loadTextContent', 'loadJsonContent', 'loadYamlContent', 'loadFileAsBase64', 'loadDirectoryFileInfo') -cnotcontains $m.Groups['fn'].Value) {
        $findings += "${rp} line ${n} calls $($m.Groups['fn'].Value), a load function this check does not know"; continue
      }
      $lit = [regex]::Match($m.Groups['arg'].Value.Trim(), '^''(?<p>[A-Za-z0-9._/-]+)''$')
      if (-not $lit.Success) { $findings += "${rp} line ${n} loads a file whose path is not plain text"; continue }
      $target = $null
      try { $target = [IO.Path]::GetFullPath([IO.Path]::Combine($dir, (ConvertTo-NativePath $lit.Groups['p'].Value))) } catch { }
      if (-not $target -or -not $target.StartsWith($rootFull, $script:PathCompare)) { $findings += "${rp} line ${n} loads a file outside the repository"; continue }
      if (Test-LinkOnPath $target $rootFull) { $findings += "${rp} line ${n} loads a file through a link" }
    }
  }
  return $findings
}

# The line number of a position in a text, counted from 1.
function Get-LineNumber([string]$Text, [int]$Index) {
  return ([regex]::Matches($Text.Substring(0, $Index), "`n").Count + 1)
}

# True when the path, or a folder between it and the repository root, is a link (a symbolic link or a junction).
# A link inside the checkout can point anywhere on the runner.
function Test-LinkOnPath([string]$FullPath, [string]$RootFull) {
  $seps = [char[]]@('\', '/')
  $p = $FullPath.TrimEnd($seps)
  $top = $RootFull.TrimEnd($seps)
  while ($p.Length -ge $top.Length -and $p.StartsWith($top, $script:PathCompare)) {
    if (Test-Path -LiteralPath $p) {
      if (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    }
    $parent = Split-Path -Parent $p
    if (-not $parent -or $parent -eq $p) { break }
    $p = $parent
  }
  return $false
}

# Every file and folder of the checkout, apart from .git, as paths relative to $Root with forward slashes. A link
# is listed and not followed.
function Get-CheckoutEntries([string]$Root) {
  $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char[]]@('\', '/'))
  $out = New-Object System.Collections.Generic.List[object]
  $stack = New-Object System.Collections.Generic.Stack[string]
  $stack.Push($rootFull)
  while ($stack.Count -gt 0) {
    $d = $stack.Pop()
    foreach ($e in ([IO.DirectoryInfo]$d).GetFileSystemInfos()) {
      $rel = $e.FullName.Substring($rootFull.Length + 1).Replace([string]$script:Sep, '/')
      if ($rel -ieq '.git') { continue }
      $link = (($e.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
      $dirEntry = (($e.Attributes -band [IO.FileAttributes]::Directory) -ne 0)
      $out.Add([pscustomobject]@{ path = $rel; link = $link; dir = $dirEntry })
      if ($dirEntry -and -not $link) { $stack.Push($e.FullName) }
    }
  }
  return $out.ToArray()
}

# A job condition that holds the pipeline switch. It is the switch alone, or the switch followed by && and the
# job's own condition. An || in that condition binds looser than the && and would let the job run with the switch
# off, so a condition with an || is accepted only as one bracketed group. A ${{ }} wrapper, outer double quotes and
# a trailing comment are read past.
function Test-PipelineSwitch([string]$Condition) {
  $c = ($Condition -replace '\s+#.*$', '').Trim()
  if ($c -match '^"(.*)"$') { $c = $Matches[1].Trim() }
  if ($c -match '^\$\{\{(.*)\}\}$') { $c = $Matches[1].Trim() }
  if (Test-Same $c $script:PipelineSwitch) { return $true }
  $prefix = "$($script:PipelineSwitch) && "
  if (-not $c.StartsWith($prefix, [StringComparison]::Ordinal)) { return $false }
  $rest = $c.Substring($prefix.Length).Trim()
  if ($rest.Length -eq 0) { return $false }
  if ($rest.IndexOf('||', [StringComparison]::Ordinal) -lt 0) { return $true }
  if (-not ($rest.StartsWith('(') -and $rest.EndsWith(')'))) { return $false }
  $depth = 0
  for ($i = 0; $i -lt $rest.Length; $i++) {
    if ($rest[$i] -eq '(') { $depth++ }
    elseif ($rest[$i] -eq ')') {
      $depth--
      if ($depth -eq 0 -and $i -lt $rest.Length - 1) { return $false }
    }
  }
  return ($depth -eq 0)
}

# The steps of one job, as the text of each step without its leading dash, in order. The job text is one job of a
# workflow body (full-line comments already left out). The steps are the entries of the job's steps: list.
function Get-JobSteps([string]$JobText) {
  $m = [regex]::Match($JobText, '(?m)^[ \t]*steps:[ \t]*\r?\n(?<ind>[ \t]*)-[ \t]')
  if (-not $m.Success) { return @() }
  $ind = $m.Groups['ind'].Value
  $rest = $JobText.Substring($m.Groups['ind'].Index)
  $parts = @([regex]::Split($rest, "(?m)^$([regex]::Escape($ind))-[ \t]+") | Where-Object { $_.Trim().Length -gt 0 })
  return @($parts | ForEach-Object { $_.TrimEnd() })
}

# The rules for the two local actions under .github/actions. Each is a composite action of run steps in pwsh. It uses
# no other action and no expression, so nothing a caller or an event supplies reaches its commands. The runner check
# must read the runner's three facts, and the Bicep setup must keep the pinned version, both hashes, the check of the
# binary and the PATH setting.
function Test-ActionHygiene([hashtable]$Files) {
  $errors = @()
  $needs = @{
    'runner-check' = @('RUNNER_ENVIRONMENT', 'RUNNER_ARCH', 'ImageOS')
    'setup-bicep'  = @('az bicep install --version', 'BICEP_VERSION', 'BICEP_SHA256_WINDOWS', 'BICEP_SHA256_LINUX', 'Get-FileHash', 'GITHUB_PATH', 'AZURE_BICEP_USE_BINARY_FROM_PATH', 'az bicep version')
  }
  foreach ($name in @($Files.Keys | Sort-Object)) {
    $label = ".github/actions/$name/action.yml"
    if (-not (Test-InList @('runner-check', 'setup-bicep') $name)) { $errors += "${label}: is not one of the local actions the workflows may use (runner-check, setup-bicep)"; continue }
    $body = (@(([string]$Files[$name]) -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n")
    if ($body -notmatch '(?ms)^runs:[ \t]*\n[ \t]+using:[ \t]*composite[ \t]*\n') { $errors += "${label}: must be a composite action (runs: using: composite)" }
    if ($body -match '(?m)^\s*(?:-\s*)?uses:') { $errors += "${label}: uses another action, and a local action holds run steps only" }
    if ($body.Contains('${{')) { $errors += "${label}: uses an expression, and a local action reads only the environment of the job" }
    foreach ($m in [regex]::Matches($body, '(?m)^[ \t]*(?:-[ \t]+)?shell:(?<v>[^\r\n]*)$')) {
      $v = ($m.Groups['v'].Value -replace '\s+#.*$', '').Trim().Trim([char[]]@("'", '"'))
      if (-not (Test-Same $v 'pwsh')) { $errors += "${label}: a step uses the shell '$v'. The steps use pwsh" }
    }
    $runCount = [regex]::Matches($body, '(?m)^[ \t]*(?:-[ \t]+)?run:[ \t]*\S').Count
    $shellCount = [regex]::Matches($body, '(?m)^[ \t]*(?:-[ \t]+)?shell:').Count
    if ($runCount -gt $shellCount) { $errors += "${label}: $($runCount - $shellCount) run step(s) name no shell. Each names shell: pwsh" }
    foreach ($word in $needs[$name]) {
      if (-not $body.Contains($word)) { $errors += "${label}: must keep $word" }
    }
  }
  return $errors
}

# Workflow rules. A deploy token is issued to any job that names a production or privileged environment from master, whatever
# workflow file the job is in. These rules catch honest mistakes early. They are text matches and a determined
# writer can get past them, and on a pull request they run the pull request's own copy of this file. The
# controls are the production environments' branch policy (master only), the code owners' review and the push
# ruleset on .github/**. Full-line comments are ignored. In a workflow with more than one azure/login, the steps
# must come before the first.
function Test-WorkflowHygiene([hashtable]$Files) {
  $errors = @()
  foreach ($name in @($Files.Keys | Sort-Object)) {
    $body = (@(([string]$Files[$name]) -split "`r?`n" | Where-Object { -not $_.TrimStart().StartsWith('#') }) -join "`n")
    $deployWorkflow = Test-Same $name 'mirror-deploy-unit.yml'
    if (-not $deployWorkflow -and $body -match 'mirror-(production|privileged)-') {
      $errors += "${name}: names a mirror-production or mirror-privileged environment, and only mirror-deploy-unit.yml may"
    }
    # An environment name built from an expression could name a production environment without saying so.
    if (-not $deployWorkflow -and $body -match '(?m)^\s*environment:[^\n]*\$\{\{|(?m)^\s*environment:\s*\n\s+name:[^\n]*\$\{\{') {
      $errors += "${name}: builds an environment name from an expression, and only mirror-deploy-unit.yml may"
    }
    foreach ($t in @('pull_request_target', 'workflow_run', 'repository_dispatch')) {
      if ([regex]::IsMatch($body, "(?<![A-Za-z0-9_-])$t(?![A-Za-z0-9_-])")) { $errors += "${name}: uses the $t trigger, which runs with the master branch's rights" }
    }
    if ($body -match '(?<![A-Za-z0-9_])pull_request(?![A-Za-z0-9_])' -and $body -match '(?<![A-Za-z0-9_-])closed(?![A-Za-z0-9_-])' -and $body -match 'id-token:\s*write') {
      $errors += "${name}: requests id-token: write in a workflow that runs when a pull request is closed"
    }
    # Only the deploy workflow uses the action that writes to Azure.
    if (-not $deployWorkflow -and $body -match '(?i)azure/bicep-deploy@') {
      $errors += "${name}: uses azure/bicep-deploy, and only the apply job of mirror-deploy-unit.yml may"
    }
    # The jobs that sign in with the reader identity and run Bicep check the Bicep inputs first. The jobs that run a
    # branch's Bicep (mirror-pr, mirror-drift) also take master's scripts first. The plan job of the deploy workflow
    # runs master's own commit, so it takes no scripts from elsewhere.
    $inputSteps = @{ 'mirror-pr.yml' = @('- name: Take the scripts from master', '- name: Check the Bicep inputs')
                     'mirror-drift.yml' = @('- name: Take the scripts from master', '- name: Check the Bicep inputs')
                     'mirror-deploy-unit.yml' = @('- name: Check the Bicep inputs') }
    if ($inputSteps.ContainsKey($name)) {
      $login = $body.IndexOf('azure/login@', [StringComparison]::Ordinal)
      foreach ($step in $inputSteps[$name]) {
        $at = $body.IndexOf($step, [StringComparison]::Ordinal)
        if ($at -lt 0 -or ($login -ge 0 -and $at -gt $login)) { $errors += "${name}: the step ""$($step.Substring(8))"" must come before the Azure sign-in" }
      }
      if ($body -notmatch '-Mode InputCheck') { $errors += "${name}: the step ""Check the Bicep inputs"" must run mirror-pipeline.ps1 -Mode InputCheck" }
    }
    # Every job runs on windows-2025 or ubuntu-24.04, named as they are or through one of the two expressions that
    # map MIRROR_RUNNER to them. No other value of the variable can reach runs-on.
    foreach ($m in [regex]::Matches($body, '(?m)^[ \t]*(?:-[ \t]+)?runs-on:(?<v>[^\r\n]*)$')) {
      $v = ($m.Groups['v'].Value -replace '\s+#.*$', '').Trim()
      $img = $v
      if ($img -match '^([''"])(.*)\1$') { $img = $Matches[2] }
      if (-not (Test-InList $script:RunnerImages $img) -and -not (Test-InList $script:RunnerChoices $img)) {
        $errors += "${name}: runs-on '$v' is not windows-2025, ubuntu-24.04 or one of the two MIRROR_RUNNER expressions in .github/scripts/mirror-pipeline.ps1"
      }
    }
    # The runner check follows the checkout in every job. It is the local action .github/actions/runner-check, which
    # stops the job unless the runner is GitHub-hosted, x64 and one of the two images, so a runner label set
    # elsewhere or a changed image never runs the job's other steps. A local action needs the repository, so the
    # pinned checkout is the first step and nothing runs between the two.
    $jobsAt = [regex]::Match($body, '(?m)^jobs:[ \t]*$')
    if ($jobsAt.Success) {
      $jobText = $body.Substring($jobsAt.Index + $jobsAt.Length)
      $heads = @([regex]::Matches($jobText, '(?m)^  (?<job>[A-Za-z_][A-Za-z0-9_-]*):[ \t]*$'))
      for ($k = 0; $k -lt $heads.Count; $k++) {
        $to = if ($k + 1 -lt $heads.Count) { $heads[$k + 1].Index } else { $jobText.Length }
        $job = $jobText.Substring($heads[$k].Index, $to - $heads[$k].Index)
        $steps = @(Get-JobSteps $job)
        $checkoutFirst = ($steps.Count -ge 1 -and $steps[0] -match '^uses:[ \t]*actions/checkout@')
        $checkSecond = ($steps.Count -ge 2 -and $steps[1] -match "^name:[ \t]*$([regex]::Escape($script:RunnerCheckStep))[ \t]*\r?\n[ \t]*uses:[ \t]*\./\.github/actions/runner-check[ \t]*(\r?\n|$)")
        if (-not ($checkoutFirst -and $checkSecond)) {
          $errors += "${name}: the first step of the job $($heads[$k].Groups['job'].Value) is not the checkout, or the second is not the runner check (- name: $($script:RunnerCheckStep), uses: ./.github/actions/runner-check)"
        }
        # Every job carries the pipeline switch in its job condition, so no runner starts until IT turns the
        # pipeline on.
        $cond = [regex]::Match($job, '(?m)^    if:[ \t]*(?<v>[^\n]*)$')
        if (-not (Test-PipelineSwitch $(if ($cond.Success) { $cond.Groups['v'].Value } else { '' }))) {
          $errors += "${name}: the job $($heads[$k].Groups['job'].Value) does not carry the pipeline switch. Its condition must be if: $($script:PipelineSwitch), alone or followed by && and the job's own condition (bracketed when it holds an ||), so the job is skipped and starts no runner until IT sets the repository variable MIRROR_PIPELINE_ENABLED to true"
        }
      }
    }
    # Every run step names pwsh, PowerShell 7, which the Windows and the Linux images both carry. Windows PowerShell
    # exists on Windows only, and the default shell differs between the two systems.
    foreach ($m in [regex]::Matches($body, '(?m)^[ \t]*(?:-[ \t]+)?shell:(?<v>[^\r\n]*)$')) {
      $v = ($m.Groups['v'].Value -replace '\s+#.*$', '').Trim().Trim([char[]]@("'", '"'))
      if (-not (Test-Same $v 'pwsh')) { $errors += "${name}: a step uses the shell '$v'. The steps use pwsh, which runs the same on Windows and Linux runners" }
    }
    $runCount = [regex]::Matches($body, '(?m)^[ \t]*(?:-[ \t]+)?run:[ \t]*\S').Count
    $shellCount = [regex]::Matches($body, '(?m)^[ \t]*(?:-[ \t]+)?shell:').Count
    if ($runCount -gt $shellCount) { $errors += "${name}: $($runCount - $shellCount) run step(s) name no shell. Each names shell: pwsh, because the default shell differs between Windows and Linux" }
    if ($deployWorkflow) {
      # The deploy workflow starts only by hand (Run workflow). A push, a pull request or a schedule never starts it.
      if ($body -match '(?<![A-Za-z0-9_-])(push|schedule|pull_request)(?![A-Za-z0-9_-])') {
        $errors += "${name}: the deploy workflow starts only with Run workflow, so it has no push, schedule or pull_request trigger"
      }
      if ($body -notmatch '(?ms)^on:[ \t]*\n[ \t]+workflow_dispatch:') {
        $errors += "${name}: the deploy workflow must start on workflow_dispatch and on nothing else"
      }
      # Every trigger under on: at the indent of its first entry. Only workflow_dispatch may be there.
      $onBlock = [regex]::Match($body, '(?m)^on:[ \t]*\n(?<b>(?:[ \t]+[^\n]*\n|[ \t]*\n)*)')
      if ($onBlock.Success) {
        $first = [regex]::Match($onBlock.Groups['b'].Value, '(?m)^(?<i>[ \t]+)[A-Za-z_]')
        if ($first.Success) {
          $ind = [regex]::Escape($first.Groups['i'].Value)
          foreach ($k in [regex]::Matches($onBlock.Groups['b'].Value, "(?m)^$ind(?<k>[A-Za-z_][A-Za-z0-9_-]*)[ \t]*:")) {
            if ($k.Groups['k'].Value -cne 'workflow_dispatch') { $errors += "${name}: the deploy workflow must start on workflow_dispatch and on nothing else, and it also names $($k.Groups['k'].Value)" }
          }
        }
      }
      # The apply job is the only job in a production or a privileged environment, and the only one that uses the
      # deployment action. It waits for the plan job, runs only on the first attempt of a run, because a re-run of
      # the apply alone would deploy without a fresh plan, and its environment is built from the two matrix values
      # the units job wrote (the tier and the scope of the unit) and nothing else. Before it signs in it checks
      # that the plan is still current (master's tip is the commit of the run, and the plan is not too old),
      # because the approval can come days after the plan. It never applies deny settings, and it never deletes a
      # resource group or a management group.
      if ($jobsAt.Success) {
        $sawApply = $false
        foreach ($k in 0..($heads.Count - 1)) {
          $to = if ($k + 1 -lt $heads.Count) { $heads[$k + 1].Index } else { $jobText.Length }
          $job = $jobText.Substring($heads[$k].Index, $to - $heads[$k].Index)
          $jn = $heads[$k].Groups['job'].Value
          if ($jn -ceq 'apply') {
            $sawApply = $true
            if ($job -notmatch '(?m)^    environment:[ \t]*mirror-\$\{\{ matrix\.tier \}\}-\$\{\{ matrix\.scope \}\}[ \t]*$') { $errors += "${name}: the apply job must have environment: mirror-`${{ matrix.tier }}-`${{ matrix.scope }} and no other environment" }
            if ($job -notmatch '(?m)^    needs:.*plan') { $errors += "${name}: the apply job must need the plan job" }
            if ($job -notmatch "(?m)^    if:[^\n]*github\.run_attempt == '1'") { $errors += "${name}: the apply job must run only on the first attempt of a run (github.run_attempt == '1' in its condition)" }
            $current = $job.IndexOf('- name: Check the plan is still current', [StringComparison]::Ordinal)
            $signIn = $job.IndexOf('azure/login@', [StringComparison]::Ordinal)
            if ($current -lt 0 -or ($signIn -ge 0 -and $current -gt $signIn) -or $job -notmatch 'git/ref/heads/master' -or $job -notmatch 'github\.sha' -or $job -notmatch 'needs\.plan\.outputs\.planned') {
              $errors += "${name}: the apply job must check that the plan is still current before the Azure sign-in (the step ""Check the plan is still current"", which compares master's tip with github.sha and reads the time of the plan from needs.plan.outputs.planned)"
            }
            if ($job -notmatch '(?m)^[ \t]*operation:[ \t]*create[ \t]*$' -or $job -notmatch '(?m)^[ \t]*deny-settings-mode:[ \t]*none[ \t]*$') { $errors += "${name}: the apply job must create the stack with azure/bicep-deploy (operation: create) and with deny-settings-mode: none" }
            if ($job -notmatch '(?m)^[ \t]*action-on-unmanage-resources:[ \t]*\$\{\{ matrix\.unmanage \}\}[ \t]*$') { $errors += "${name}: the apply job must take action-on-unmanage-resources from the unit's row (`${{ matrix.unmanage }}), because stackDeletes is read and refused for some units in that row" }
            foreach ($g in @('resourcegroups', 'managementgroup', 'managementgroups')) {
              if ($job -notmatch "(?m)^[ \t]*action-on-unmanage-${g}:[ \t]*detach[ \t]*`$") { $errors += "${name}: the apply job must keep action-on-unmanage-${g}: detach, so a stack never deletes a resource group or a management group" }
            }
          } else {
            if ($job -match 'mirror-(production|privileged)-' -or $job -match '(?m)^\s*environment:\s*[^\n]*\$\{\{|(?m)^\s*environment:\s*\n\s+name:[^\n]*\$\{\{') { $errors += "${name}: the job $jn names a mirror-production or mirror-privileged environment or builds an environment name from an expression, and only the apply job may" }
            if ($job -match '(?i)azure/bicep-deploy@') { $errors += "${name}: the job $jn uses azure/bicep-deploy, and only the apply job may" }
          }
        }
        if (-not $sawApply) { $errors += "${name}: the deploy workflow has no apply job" }
      }
    }
    # A token for Azure is requested only by a job that has an environment, because the federated credentials trust
    # an environment. No workflow asks for it in its top-level permissions.
    $topPerm = [regex]::Match($body, '(?m)^permissions:[ \t]*\n(?<b>(?:[ \t]+[^\n]*\n?)*)')
    if ($topPerm.Success -and $topPerm.Groups['b'].Value -match 'id-token') { $errors += "${name}: requests id-token in its top-level permissions, which every job would get" }
    if ($jobsAt.Success) {
      foreach ($k in 0..($heads.Count - 1)) {
        $to = if ($k + 1 -lt $heads.Count) { $heads[$k + 1].Index } else { $jobText.Length }
        $job = $jobText.Substring($heads[$k].Index, $to - $heads[$k].Index)
        if ($job -match 'id-token:[ \t]*write' -and $job -notmatch '(?m)^    environment:') { $errors += "${name}: the job $($heads[$k].Groups['job'].Value) requests id-token: write and has no environment" }
      }
    }
    foreach ($m in [regex]::Matches($body, '(?m)^\s*(?:-\s*)?uses:\s*[''"]?([^\s''"#]+)')) {
      $ref = $m.Groups[1].Value
      if ($ref.StartsWith('./')) {
        if (-not (Test-InList $script:AllowedLocalActions $ref)) { $errors += "${name}: uses the local action $ref, and only $($script:AllowedLocalActions -join ' and ') are allowed" }
        continue
      }
      $mm = [regex]::Match($ref, '^(?<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[^@]*)?@(?<sha>[^@]+)$')
      if (-not $mm.Success -or $mm.Groups['sha'].Value -cnotmatch '^[0-9a-f]{40}$') { $errors += "${name}: $ref is not pinned to a full commit SHA"; continue }
      if ($script:AllowedActions -notcontains $mm.Groups['action'].Value.ToLowerInvariant()) { $errors += "${name}: $($mm.Groups['action'].Value) is not one of the allowed actions ($($script:AllowedActions -join ', '))" }
    }
  }
  return $errors
}

# ---------------------------------------------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------------------------------------------

function Read-JsonText([string]$Text, [string]$What) {
  try { return (ConvertFrom-Json @MirrorJsonArgs -InputObject $Text) } catch { Stop-Check "$What is not valid JSON: $($_.Exception.Message)" }
}

function Read-JsonFile([string]$Path) {
  return (ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText($Path)))
}

function Invoke-HygieneMode {
  $dir = if ($Dir) { $Dir } else { Join-RepoPath $script:RepoRoot '.github/workflows' }
  $files = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in '.yml', '.yaml' })) { $files[$f.Name] = [IO.File]::ReadAllText($f.FullName) }
  $errors = @(Test-WorkflowHygiene $files)
  # The local actions sit in the folder next to the workflows folder. Both must exist, and no other may.
  $actionsDir = Join-Path (Split-Path -Parent $dir) 'actions'
  $actions = @{}
  if (Test-Path -LiteralPath $actionsDir -PathType Container) {
    foreach ($d in @(Get-ChildItem -LiteralPath $actionsDir -Directory -Force)) {
      $f = Join-Path $d.FullName 'action.yml'
      $actions[$d.Name] = if (Test-Path -LiteralPath $f -PathType Leaf) { [IO.File]::ReadAllText($f) } else { '' }
    }
  }
  foreach ($a in $script:AllowedLocalActions) {
    $short = $a.Substring($a.LastIndexOf('/') + 1)
    if (-not $actions.ContainsKey($short) -or -not $actions[$short]) { $errors += ".github/actions/$short/action.yml is missing, and the workflows use it" }
  }
  $errors += @(Test-ActionHygiene $actions)
  $units = Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/units.json')
  $errors += @(Test-UnitRules $units)
  if ($errors.Count -gt 0) { Stop-WithErrors 'Workflow rules or unit rules broken' $errors }
  Write-Summary @("Workflow rules: $($files.Count) workflow file(s) and $($actions.Count) local action(s) checked, all pass. Unit rules: $(@(Get-Prop $units 'units').Count) unit(s) of deploy/units.json checked, all pass.")
}

# The paths whose change makes the portability job run the full preflight on its image: the scripts the preflight and
# the pipeline run, the local actions that pin Bicep and check the runner, the Bicep settings, the git settings that decide line endings and which files a checkout holds,
# and the validate workflow itself. Paths are repository paths with /, and they
# match exactly as written, so the case counts on every system (the repository has these folders in lower case).
function Test-PortabilitySensitivePath([string]$Path) {
  $p = $Path.Replace('\', '/')
  if ($p.StartsWith('scripts/', [StringComparison]::Ordinal) -or $p.StartsWith('.github/scripts/', [StringComparison]::Ordinal)) { return $true }
  if ($p.StartsWith('.github/actions/', [StringComparison]::Ordinal)) { return $true }
  return (Test-InList @('bicepconfig.json', '.gitattributes', '.gitignore', '.github/workflows/mirror-validate.yml') $p)
}

# The added paths whose name differs only in case from another path of the tree, each as "added (other)". A Windows
# checkout keeps only one of two such files, so only a Linux runner sees the second, and the preflight's layout
# check fails it there.
function Find-CaseCollisions([string[]]$Added, [string[]]$All) {
  # Every folder and file path of the tree, keyed by its lower-case form, with each spelling seen.
  $byLower = @{}
  foreach ($p in @($All) + @($Added)) {
    if (-not $p) { continue }
    $parts = $p.Replace('\', '/').Split('/')
    for ($i = 1; $i -le $parts.Count; $i++) {
      $pre = ($parts[0..($i - 1)] -join '/')
      $k = $pre.ToLowerInvariant()
      if (-not $byLower.ContainsKey($k)) { $byLower[$k] = New-Object System.Collections.Generic.List[string] }
      if (-not $byLower[$k].Contains($pre)) { $byLower[$k].Add($pre) }
    }
  }
  foreach ($a in @($Added)) {
    if (-not $a) { continue }
    $parts = $a.Replace('\', '/').Split('/')
    for ($i = 1; $i -le $parts.Count; $i++) {
      $pre = ($parts[0..($i - 1)] -join '/')
      $others = @($byLower[$pre.ToLowerInvariant()] | Where-Object { $_ -cne $pre })
      if ($others.Count -gt 0) { "$($a.Replace('\', '/')) ($pre and $($others -join ', '))"; break }
    }
  }
}

# mirror-validate, portability job. Writes the step output full (true or false) and one summary line with the reason.
# The full preflight runs on a manual run, on any event but a push or a pull request, when the change touches a
# sensitive path, when it adds a path whose name differs only in case from another path of the tree, and when the
# changed files cannot be read. A pull request's checkout is GitHub's merge commit, so
# its change is HEAD compared with its first parent. A push's change is the commit before the push (BEFORE)
# compared with HEAD.
function Invoke-PortabilityScopeMode {
  $evt = Get-EnvValue 'EVENT_NAME'
  $full = $true; $reason = ''
  if ($evt -cne 'pull_request' -and $evt -cne 'push') {
    $reason = "the event is $(if ($evt) { $evt } else { 'not known' }), and only a pull request or a push is judged by its changed files"
  } else {
    $from = if ($evt -ceq 'pull_request') { 'HEAD^1' } else { Get-EnvValue 'BEFORE' }
    $paths = $null
    if (-not $from -or $from -match '^0+$') { $reason = 'the commit before the change is not known, so the changed files are not known' }
    elseif (-not (Test-GitCommit $from)) { $reason = "the commit $from is not in the checkout, so the changed files are not known" }
    else {
      try {
        $changes = @(Get-GitChanges $from 'HEAD')
        $paths = @($changes | ForEach-Object { $_.Path })
        $added = @($changes | Where-Object { $_.Status -ceq 'A' } | ForEach-Object { $_.Path })
        $collisions = @()
        if ($added.Count -gt 0) { $collisions = @(Find-CaseCollisions $added @((Invoke-Git @('ls-files')).Out)) }
      }
      catch { $paths = $null; $reason = 'the changed files could not be read' }
    }
    if ($null -ne $paths) {
      $hits = @($paths | Where-Object { Test-PortabilitySensitivePath $_ })
      if ($collisions.Count -gt 0) {
        $reason = "the change adds $(@($collisions | Select-Object -First 3) -join ', '), a name that differs only in case from another path, which a Windows checkout cannot hold"
      } elseif ($hits.Count -gt 0) {
        $shown = (@($hits | Select-Object -First 3) -join ', ')
        $reason = "the change touches $shown" + $(if ($hits.Count -gt 3) { " and $($hits.Count - 3) more" } else { '' })
      } else {
        $full = $false
        $reason = "the $($paths.Count) changed file(s) touch no script, no bicepconfig.json, no .gitattributes or .gitignore and no validate workflow"
      }
    }
  }
  Set-StepOutput 'full' $(if ($full) { 'true' } else { 'false' })
  $line = if ($full) { "Portability scope: full preflight, because $reason." } else { "Portability scope: no full preflight, because $reason." }
  Write-Host $line
  Write-Summary @($line)
}

# mirror-drift, report job. The drift job writes drift-summary.json, one row per unit with its result (clean, DRIFT,
# ERROR or SKIP) and its findings. The report keeps one open issue with the title below, written with the workflow's
# own token, so a finding reaches everyone who watches the repository. A run that finds drift, or cannot check a
# unit, opens the issue, or updates it when it is open. When the findings differ from the ones the issue shows, the
# update adds a comment, which notifies the watchers. The same findings a week later update the link to the run and
# add no comment. A run that finds every unit clean closes the issue with a comment. The report never signs in to
# Azure and changes nothing but the issue.
$script:DriftIssueTitle = 'The drift check found a difference between live Azure and the code, or a unit it could not check'
$script:DriftMarker = '<!-- mirror-drift findings '

# The state of one drift run: drift when a unit shows drift, error when a unit could not be checked, when no drift
# job wrote a result or when a job failed for another reason, and clean otherwise. A drift job fails on purpose when
# its unit shows drift, so the result of the jobs counts only when no row says drift or error.
function Get-DriftState($Rows, [string]$JobResult) {
  $r = @(@($Rows) | Where-Object { $null -ne $_ })
  if ($r.Count -eq 0) { return 'error' }
  if (@($r | Where-Object { [string](Get-Prop $_ 'result') -ceq 'DRIFT' }).Count -gt 0) { return 'drift' }
  if (@($r | Where-Object { [string](Get-Prop $_ 'result') -ceq 'ERROR' }).Count -gt 0) { return 'error' }
  if ($JobResult -and $JobResult -cne 'success') { return 'error' }
  return 'clean'
}

# The findings of every unit that is not clean, as Markdown lines. Each finding is one line in a code
# span, so text from Azure cannot make a link, a heading or HTML. The units and the findings of each unit are sorted
# (ordinal), because Azure lists resources in no fixed order, and the same findings must give the same text.
function Format-DriftFindings($Rows) {
  $lines = @()
  $list = [object[]]@(@($Rows) | Where-Object { $null -ne $_ })
  if ($list.Count -gt 1) {
    $keys = [string[]]@($list | ForEach-Object { [string](Get-Prop $_ 'unit') })
    [Array]::Sort($keys, $list, [Collections.IComparer][StringComparer]::Ordinal)
  }
  foreach ($row in $list) {
    $res = [string](Get-Prop $row 'result')
    if ($res -ceq 'clean') { continue }
    $lines += "- $(ConvertTo-CodeSpan ([string](Get-Prop $row 'unit'))) $res"
    $found = [string[]]@(@(Get-Prop $row 'findings') | Where-Object { $null -ne $_ -and "$_" } | ForEach-Object { ConvertTo-CodeSpan ([string]$_) })
    if ($found.Count -gt 1) { [Array]::Sort($found, [Collections.IComparer][StringComparer]::Ordinal) }
    foreach ($f in $found) { $lines += "  - $f" }
  }
  return [string[]]$lines
}

# The text of the issue. It ends with a marker that holds the SHA256 of the findings, so the next run can tell
# whether they changed.
function Format-DriftIssueBody($Rows, [string]$State, [string]$RunUrl, [string]$JobResult) {
  $r = @(@($Rows) | Where-Object { $null -ne $_ })
  $count = { param($v) @($r | Where-Object { [string](Get-Prop $_ 'result') -ceq $v }).Count }
  $findings = @(Format-DriftFindings $r)
  if ($r.Count -eq 0) { $findings = @("- The drift jobs ended before they wrote a result (result $(ConvertTo-CodeSpan $JobResult)). Their logs say why.") }
  elseif ($findings.Count -eq 0) { $findings = @("- No unit shows drift, but the drift jobs did not succeed (result $(ConvertTo-CodeSpan $JobResult)). Their logs say why.") }
  $what = if ($State -ceq 'drift') { 'Live Azure differs from the code in at least one unit.' } else { 'At least one unit could not be checked, so its drift is not known.' }
  $sha = [System.Security.Cryptography.SHA256]::Create()
  $fp = (($sha.ComputeHash($script:Utf8NoBom.GetBytes("$State`n" + ($findings -join "`n"))) | ForEach-Object { $_.ToString('x2') }) -join '')
  $lines = @(
    $what,
    '',
    "Units checked: $($r.Count). Clean: $(& $count 'clean'). Drift: $(& $count 'DRIFT'). Not checked: $(& $count 'ERROR').",
    '',
    'Findings:',
    '') + $findings + @(
    '',
    "Last run: $RunUrl",
    '',
    'Each finding is a change type and a resource, as the stack preview of the unit reports it. The job summary and the artifact of each unit''s drift job hold the whole preview. A difference is fixed in a code pull request when the code should follow live, or by a deployment with Run workflow when live should follow the code. A deployment writes the whole template again, so it also takes back every other difference of the unit. The check never changes Azure. A stack preview covers the resources the stack manages, so a resource added by hand beside them does not show here. This issue closes itself when a run finds every unit clean.',
    '',
    "$($script:DriftMarker)$fp -->")
  $text = $lines -join "`n"
  if ($text.Length -gt 60000) { $text = $text.Substring(0, 59000) + "`n`nThe list is cut here. The run's summary holds all of it.`n`n$($script:DriftMarker)$fp -->" }
  return [pscustomobject]@{ body = $text; fingerprint = $fp }
}

# A write to the GitHub REST API through the GitHub CLI, signed in with GH_TOKEN. The JSON body goes through a file.
function Invoke-GhApiWrite([string]$Method, [string]$Path, $Body) {
  $tmp = [IO.Path]::GetTempFileName()
  try {
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Body -Depth 5 -Compress), $script:Utf8NoBom)
    $r = Invoke-Native 'gh' @('api', '-X', $Method, '-H', 'Accept: application/vnd.github+json', '-H', 'X-GitHub-Api-Version: 2022-11-28', '--input', $tmp, $Path) -AllowFailure
    if ($r.Code -ne 0) { throw "gh api -X $Method $Path failed (exit $($r.Code)): $($r.Err)" }
    $out = ($r.Out -join "`n")
    if ($out.Trim()) { return (ConvertFrom-Json @MirrorJsonArgs -InputObject $out) }
    return $null
  } finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
}

# The open issues the drift report wrote: its title, opened by the workflow's own token, and no pull request. The
# list holds every open issue and is filtered here, so the result never depends on a query parameter of the API.
function Find-DriftIssue([string]$Repo) {
  $all = @(Invoke-GhApi "repos/$Repo/issues?state=open&per_page=100" -Paginate)
  return @($all | Where-Object { $null -ne $_ -and (Test-Same ([string](Get-Prop $_ 'title')) $script:DriftIssueTitle) -and
                                 (Test-Same ([string](Get-Prop (Get-Prop $_ 'user') 'login')) $script:BotLogin) -and $null -eq (Get-Prop $_ 'pull_request') })
}

# The result of every drift job: the whatif-result.json each one uploaded, read from the folder the artifacts were
# downloaded to. A unit of the matrix with no readable result gets an ERROR row, so the issue names it.
function Read-DriftRows([string]$Folder, [string]$MatrixJson) {
  $rows = @()
  if ($Folder -and (Test-Path -LiteralPath $Folder -PathType Container)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $Folder -Recurse -File -Filter 'whatif-result.json' | Sort-Object FullName)) {
      try { $row = Read-JsonFile $f.FullName } catch { continue }
      if ([string](Get-Prop $row 'unit')) { $rows += $row }
    }
  }
  $expected = @()
  # Windows PowerShell hands a JSON list on as one object, so the list is kept first and walked after.
  if ($MatrixJson) { try { $list = ConvertFrom-Json @MirrorJsonArgs -InputObject $MatrixJson; foreach ($m in @($list)) { $expected += [string](Get-Prop $m 'unit') } } catch { $expected = @() } }
  foreach ($n in $expected) {
    if (-not $n -or @($rows | Where-Object { Test-Same ([string](Get-Prop $_ 'unit')) $n }).Count -gt 0) { continue }
    $rows += [pscustomobject]@{ unit = $n; result = 'ERROR'; findings = @('the drift job of this unit wrote no result. Its log says why') }
  }
  return $rows
}

function Invoke-DriftReportMode {
  $repo = Get-EnvValue 'GITHUB_REPOSITORY'
  if (-not $repo) { Stop-Check 'GITHUB_REPOSITORY is not set' 2 }
  $runUrl = Get-EnvValue 'RUN_URL' 'the run'
  $job = Get-EnvValue 'DRIFT_RESULT'
  $rows = @(Read-DriftRows $Dir (Get-EnvValue 'MATRIX'))
  $state = Get-DriftState $rows $job
  $open = @(Find-DriftIssue $repo)
  if ($state -ceq 'clean') {
    $closed = @()
    foreach ($i in $open) {
      $n = [string](Get-Prop $i 'number')
      $null = Invoke-GhApiWrite 'POST' "repos/$repo/issues/$n/comments" @{ body = "Every checked unit is clean in $runUrl, so this issue is closed." }
      $null = Invoke-GhApiWrite 'PATCH' "repos/$repo/issues/$n" @{ state = 'closed'; state_reason = 'completed' }
      $closed += "#$n"
    }
    $line = if ($closed.Count -gt 0) { "Drift report: every checked unit is clean, so issue $($closed -join ', ') is closed." } else { 'Drift report: every checked unit is clean, and no drift issue is open.' }
    Write-Host $line; Write-Summary @($line); return
  }
  $b = Format-DriftIssueBody $rows $state $runUrl $job
  if ($open.Count -eq 0) {
    $new = Invoke-GhApiWrite 'POST' "repos/$repo/issues" @{ title = $script:DriftIssueTitle; body = $b.body }
    $line = "Drift report: issue #$([string](Get-Prop $new 'number')) is opened ($state)."
  } else {
    $i = $open[0]; $n = [string](Get-Prop $i 'number')
    # The last marker is the report's own, because a finding could hold the marker text too.
    $ms = [regex]::Matches([string](Get-Prop $i 'body'), [regex]::Escape($script:DriftMarker) + '(?<fp>[0-9a-f]{64}) -->')
    $oldFp = if ($ms.Count -gt 0) { $ms[$ms.Count - 1].Groups['fp'].Value } else { '' }
    if ($oldFp -cne $b.fingerprint) {
      # The comment comes first. If it fails, the issue keeps the old fingerprint and the next run comments again.
      $null = Invoke-GhApiWrite 'POST' "repos/$repo/issues/$n/comments" @{ body = "The findings changed in $runUrl. The issue text above shows them." }
      $null = Invoke-GhApiWrite 'PATCH' "repos/$repo/issues/$n" @{ body = $b.body }
      $line = "Drift report: issue #$n is updated, and its findings changed ($state)."
    } else {
      $null = Invoke-GhApiWrite 'PATCH' "repos/$repo/issues/$n" @{ body = $b.body }
      $line = "Drift report: issue #$n is updated with this run, and its findings are the same ($state)."
    }
  }
  Write-Host $line; Write-Summary @($line)
}

# True when the code in the working folder is the trusted commit itself. The workflow sets both values in the step
# that takes the scripts from master.
function Test-CodeIsTrusted {
  $t = Get-EnvValue 'MIRROR_TRUSTED_COMMIT'; $c = Get-EnvValue 'MIRROR_CODE_COMMIT'
  return ($t -cmatch '^[0-9a-f]{40}$' -and $t -ceq $c)
}

# Before the sign-in to Azure, when the code comes from a branch and not from master. The job then compiles the
# branch's Bicep with the reader token in hand, so nothing in the checkout may use the inputs
# Find-UnsafeBicepInputs lists. Every .bicep and .bicepparam file of the checkout is read, not only the files a
# unit reaches, because Bicep can reach a file in ways a text search can miss. Also refused: a link in the
# checkout, a bicepconfig.json below the root (Bicep reads the nearest one, and only the root copy is master's), a
# unit whose files lie outside the repository, a unit name or measuredWith entry that is not lower-case letters,
# digits and single hyphens, and a UNIT that does not name exactly one unit, character by character and with
# the same case. The picked units are UNIT or every enabled unit, with the units their measuredWith lists.
function Invoke-InputCheckMode {
  if (Test-CodeIsTrusted) { Write-Host "The code is master's commit $(Get-EnvValue 'MIRROR_TRUSTED_COMMIT'). Nothing to check."; return }
  $root = $script:RepoRoot
  $units = Read-JsonFile (Join-RepoPath $root 'deploy/units.json')
  $all = @(Get-Prop $units 'units')
  $unit = Get-EnvValue 'UNIT'
  $findings = @()
  # A unit name becomes part of the evidence file names, so every name and measuredWith entry is lower-case
  # letters, digits and single hyphens, the same rule as a request, and '../' never reaches a path.
  foreach ($u in $all) {
    $n = [string](Get-Prop $u 'name')
    if ($n -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\z') { $findings += "deploy/units.json: the unit name '$n' is not lower-case letters, digits and single hyphens" }
    foreach ($sib in @(Get-Prop $u 'measuredWith')) {
      if ($null -ne $sib -and [string]$sib -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\z') { $findings += "deploy/units.json: ${n}: the measuredWith entry '$sib' is not lower-case letters, digits and single hyphens" }
    }
  }
  # @() around the if, because an if hands back a list of one as the item itself.
  $pick = @(if ($unit) { $all | Where-Object { Test-Same ([string](Get-Prop $_ 'name')) $unit } }
            else { $all | Where-Object { [bool](Get-Prop $_ 'enabled') } })
  if ($unit) {
    $near = @($all | Where-Object { [string]::Equals([string](Get-Prop $_ 'name'), $unit, [StringComparison]::OrdinalIgnoreCase) })
    if ($pick.Count -ne 1 -or $near.Count -ne 1) { $findings += "UNIT '$unit' must name exactly one unit in deploy/units.json, written with the same case" }
  }
  $names = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($u in $pick) { [void]$names.Add([string](Get-Prop $u 'name')) }
  foreach ($u in @($pick)) {
    foreach ($sib in @(Get-Prop $u 'measuredWith')) {
      if (-not $sib -or $names.Contains([string]$sib)) { continue }
      $sd = @($all | Where-Object { [string]::Equals([string](Get-Prop $_ 'name'), [string]$sib, [StringComparison]::OrdinalIgnoreCase) })
      if ($sd.Count -ne 1) { $findings += "$([string](Get-Prop $u 'name')): measuredWith names '$sib', which is not exactly one unit in deploy/units.json"; continue }
      [void]$names.Add([string]$sib); $pick += $sd[0]
    }
  }
  $map = Get-UnitFiles ([pscustomobject]@{ units = $pick }) $root
  foreach ($u in $pick) {
    $n = [string](Get-Prop $u 'name')
    foreach ($p in @($map[$n])) {
      if ($p -match '^(?:[a-z]:/|/)' -and (Test-Path -LiteralPath $p)) { $findings += "${n}: reaches $p, outside the repository" }
    }
  }
  $entries = @(Get-CheckoutEntries $root)
  foreach ($e in @($entries | Where-Object { $_.link })) { $findings += "$($e.path) is a link, which the repository never holds" }
  foreach ($e in @($entries | Where-Object { -not $_.dir -and $_.path -ne 'bicepconfig.json' -and ($_.path -split '/')[-1] -ieq 'bicepconfig.json' })) {
    $findings += "$($e.path) is a Bicep configuration file below the repository root. Bicep would use it for every file below it, and only the root bicepconfig.json comes from master"
  }
  $bicepFiles = @($entries | Where-Object { -not $_.dir -and -not $_.link -and $_.path -match '\.(bicep|bicepparam)$' } | ForEach-Object { $_.path })
  $findings += @(Find-UnsafeBicepInputs $bicepFiles $root)
  if ($findings.Count -gt 0) {
    Stop-WithErrors 'Bicep from a branch uses inputs that are not run with the reader identity' $findings 2
  }
  Write-Host "Bicep inputs checked: $($bicepFiles.Count) Bicep file(s) in the checkout, $($pick.Count) unit(s). None reads an environment variable, a registry module or a file outside the repository."
}



# ---------------------------------------------------------------------------------------------------------------
# Units and their deployment stacks
# ---------------------------------------------------------------------------------------------------------------

# One row of a job matrix for one unit of deploy/units.json: the scope, the name and the files of its deployment
# stack. A resource group unit is a resource group stack, a subscription unit a subscription stack and a
# tenant-kind unit a management group stack at the unit's management group, each named mirror-<unit>. unmanage says
# what a deployment does with a resource that left the template: detach, which leaves it in Azure, or delete when
# the unit has "stackDeletes": true. A resource group and a management group are always detached, and a unit of a
# scope in $script:NoStackDeletesScopes may not have stackDeletes. Throws when a field is missing or has a form the
# stack commands do not take, so a matrix never holds a half-read unit.
function Get-UnitRow($UnitDef, $UnitsDoc) {
  $name = [string](Get-Prop $UnitDef 'name')
  if ($name -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\z') { throw "the unit name '$name' is not lower-case letters, digits and single hyphens" }
  $tier = Get-UnitTier $UnitDef
  if ($null -eq $tier) { throw "${name}: the tier must be privileged or left out" }
  $deletes = Get-Prop $UnitDef 'stackDeletes'
  if ($null -ne $deletes -and $deletes -isnot [bool]) { throw "${name}: stackDeletes must be true or false" }
  if ($deletes -eq $true -and (Test-InList $script:NoStackDeletesScopes (Get-UnitScope $UnitDef))) {
    throw "${name}: stackDeletes stays off for the units of the scope '$(Get-UnitScope $UnitDef)'. A deletion there is made by hand after IT agrees to it"
  }
  $template = [string](Get-Prop $UnitDef 'template'); $parameters = [string](Get-Prop $UnitDef 'parameters')
  if ($template -cnotmatch '\.bicep\z') { throw "${name}: the template must be a .bicep file" }
  if ($parameters -and $parameters -cnotmatch '\.bicepparam\z') { throw "${name}: the parameters file must be a .bicepparam file" }
  foreach ($f in @($template, $parameters)) {
    if ($f -and ($f -cnotmatch '^[A-Za-z0-9._/-]+\z' -or $f -match '(^|/)\.\.?(/|$)' -or $f.StartsWith('/'))) { throw "${name}: '$f' is not a path inside the repository" }
  }
  $location = [string](Get-Prop $UnitsDoc 'deploymentLocation')
  if ($location -cnotmatch '^[a-z0-9]+\z') { throw "deploymentLocation '$location' is not an Azure location name" }
  $row = [ordered]@{ unit = $name; tier = $tier; scope = (Get-UnitScope $UnitDef); stack = "$($script:StackPrefix)$name"; stackScope = ''
                     subscriptionId = ''; resourceGroup = ''; managementGroup = ''; location = $location
                     template = $template; parameters = $parameters; unmanage = $(if ($deletes -eq $true) { 'delete' } else { 'detach' }) }
  $kind = [string](Get-Prop $UnitDef 'kind')
  if ($kind -ceq 'tenant') {
    $mg = [string](Get-Prop $UnitDef 'managementGroup')
    if ($mg -cnotmatch '^[A-Za-z0-9._()-]{1,90}\z') { throw "${name}: managementGroup '$mg' is not a management group ID" }
    $row.stackScope = 'managementGroup'; $row.managementGroup = $mg
  } elseif ($kind -ceq 'subscription' -or $kind -ceq 'resourceGroup') {
    $subId = [string](Get-Prop (Get-Prop $UnitsDoc 'subscriptions') ([string](Get-Prop $UnitDef 'subscription')))
    if ($subId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z') { throw "${name}: the subscription '$(Get-Prop $UnitDef 'subscription')' has no ID in the subscriptions list" }
    if ($row.scope -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\z') { throw "${name}: the subscription '$($row.scope)' is not lower-case letters, digits and single hyphens" }
    $row.subscriptionId = $subId; $row.stackScope = 'subscription'
    if ($kind -ceq 'resourceGroup') {
      $rg = [string](Get-Prop $UnitDef 'resourceGroup')
      if ($rg -notmatch '^[\w.()-]{1,90}\z') { throw "${name}: resourceGroup '$rg' is not a resource group name" }
      $row.stackScope = 'resourceGroup'; $row.resourceGroup = $rg
    }
  } else { throw "${name}: the kind '$kind' is not resourceGroup, subscription or tenant" }
  return [pscustomobject]$row
}

# True when the unit's template is a deploy-excluded file. Such a file holds the resources a deployment must not
# write (connections without their credentials, extensions without their protected settings, held assignments),
# so its unit is previewed and never deployed.
function Test-DeployExcludedUnit($UnitDef) {
  return ([string](Get-Prop $UnitDef 'template')).EndsWith('.deploy-excluded.bicep', [StringComparison]::OrdinalIgnoreCase)
}

# The rules every unit of deploy/units.json keeps, read from the file alone with nothing compiled. Each unit gives
# a stack row (Get-UnitRow: the name, the tier, the kind, the files, the scope and stackDeletes), no two units
# share a name, enabled and deployed are true or false, and the unit of a deploy-excluded file is neither enabled
# nor marked deployed nor given stackDeletes. Returns one line per broken rule.
function Test-UnitRules($UnitsDoc) {
  $errors = @()
  $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  foreach ($u in @(Get-Prop $UnitsDoc 'units')) {
    $name = [string](Get-Prop $u 'name')
    if (-not $seen.Add($name)) { $errors += "deploy/units.json: the unit name '$name' is used more than once" }
    try { $null = Get-UnitRow $u $UnitsDoc } catch { $errors += "deploy/units.json: $($_.Exception.Message)" }
    foreach ($f in @('enabled', 'deployed')) {
      $v = Get-Prop $u $f
      if ($null -ne $v -and $v -isnot [bool]) { $errors += "deploy/units.json: ${name}: $f must be true or false" }
    }
    if (Test-DeployExcludedUnit $u) {
      foreach ($f in @('enabled', 'deployed', 'stackDeletes')) {
        if ((Get-Prop $u $f) -eq $true) { $errors += "deploy/units.json: ${name}: $f is true, and the unit of a deploy-excluded file is never deployed. Its resources are written by hand, or moved to the routine file of the group first" }
      }
    }
  }
  return $errors
}

# The resource ID of the deployment stack of a row.
function Get-StackId($Row) {
  $tail = "/providers/Microsoft.Resources/deploymentStacks/$($Row.stack)"
  if ($Row.stackScope -ceq 'resourceGroup') { return "/subscriptions/$($Row.subscriptionId)/resourceGroups/$($Row.resourceGroup)$tail" }
  if ($Row.stackScope -ceq 'subscription') { return "/subscriptions/$($Row.subscriptionId)$tail" }
  if ($Row.stackScope -ceq 'managementGroup') { return "/providers/Microsoft.Management/managementGroups/$($Row.managementGroup)$tail" }
  throw "unknown stack scope '$($Row.stackScope)'"
}

# The arguments of one Azure CLI stack command for a row. $Command is validate (az stack <scope> validate), whatif
# (az stack-whatif <scope> create, the preview as JSON), show (az stack-whatif <scope> show, the same preview as
# text with its property changes) or stack (az stack <scope> show, the stack itself). The settings are the ones
# the apply job gives the deployment action: the same action on unmanage, no deny settings and the unit's own
# parameters file. ProviderNoRbac checks read rights in place of write rights, so the reader identity can run it.
function Get-StackArguments($Row, [string]$Root, [string]$Command, [string]$ResultName = '') {
  $word = @{ resourceGroup = 'group'; subscription = 'sub'; managementGroup = 'mg' }[[string]$Row.stackScope]
  if (-not $word) { throw "unknown stack scope '$($Row.stackScope)'" }
  $where = if ($word -ceq 'group') { @('--subscription', [string]$Row.subscriptionId, '--resource-group', [string]$Row.resourceGroup) }
           elseif ($word -ceq 'sub') { @('--subscription', [string]$Row.subscriptionId) }
           else { @('--management-group-id', [string]$Row.managementGroup) }
  if ($Command -ceq 'stack') { return @('stack', $word, 'show', '--name', [string]$Row.stack) + $where + @('-o', 'json') }
  if ($Command -ceq 'show') { return @('stack-whatif', $word, 'show', '--name', $ResultName) + $where + @('--with-property-changes', 'true', '--no-color') }
  if ($Command -ceq 'validate') { $a = @('stack', $word, 'validate', '--name', [string]$Row.stack) }
  elseif ($Command -ceq 'whatif') { $a = @('stack-whatif', $word, 'create', '--name', $ResultName, '--stack-id', (Get-StackId $Row), '--retention-interval', $script:WhatIfRetention, '--no-pretty-print') }
  else { throw "unknown stack command '$Command'" }
  $a += $where
  if ($word -cne 'group') { $a += @('--location', [string]$Row.location) }
  $a += @('--action-on-unmanage', $(if ($Row.unmanage -ceq 'delete') { 'deleteResources' } else { 'detachAll' }), '--deny-settings-mode', 'none', '--validation-level', 'ProviderNoRbac')
  if ($Row.parameters) { $a += @('--parameters', (Join-RepoPath $Root ([string]$Row.parameters))) }
  else { $a += @('--template-file', (Join-RepoPath $Root ([string]$Row.template))) }
  $a += @('-o', $(if ($Command -ceq 'validate') { 'none' } else { 'json' }))
  return $a
}

# What a stack preview says, read from the JSON the Azure CLI returns for it. The counts are the resources of each
# change type as Azure names them (create, modify, delete, detach, noChange, unsupported). Nothing is compared
# here. result is clean when every resource is noChange, DRIFT when one is not, and ERROR when Azure did not finish
# the preview. firstRun is true when the stack does not exist yet, and adopted counts the resources that exist
# and come under the stack's management. diagnosticMessages holds the diagnostic messages Azure added, one line
# each. A diagnostic means Azure could not evaluate a part of the stack, so a preview with one is not a full check
# even when every listed resource is noChange.
function Get-StackWhatIfVerdict($Doc, [string]$Unit) {
  $props = Get-Prop $Doc 'properties'
  $changes = @(@(Get-Prop (Get-Prop $props 'changes') 'resourceChanges') | Where-Object { $null -ne $_ })
  $counts = [ordered]@{}
  $findings = @(); $adopted = 0
  foreach ($c in $changes) {
    $t = [string](Get-Prop $c 'changeType'); if (-not $t) { $t = 'unknown' }
    if ($counts.Contains($t)) { $counts[$t] = $counts[$t] + 1 } else { $counts[$t] = 1 }
    if ($t -cne 'noChange') { $findings += "$t $([string](Get-Prop $c 'id'))" }
    $m = Get-Prop $c 'managementStatusChange'
    if ([string](Get-Prop $m 'before') -ceq 'notManaged' -and [string](Get-Prop $m 'after') -ceq 'managed' -and $t -cne 'create') { $adopted++ }
  }
  # PowerShell 7 before 7.5 reads the time as a date, and the other hosts keep the text.
  $modified = Get-Prop $props 'deploymentStackLastModified'
  $firstRun = if ($modified -is [datetime]) { $modified.Year -le 1 } elseif ($modified -is [DateTimeOffset]) { $modified.Year -le 1 } else { ([string]$modified).StartsWith('0001-01-01') }
  $state = [string](Get-Prop $props 'provisioningState')
  $failed = ($null -eq $props -or $null -ne (Get-Prop $props 'error') -or $state -ne 'succeeded')
  if ($failed) { $findings = @("the preview ended in the state '$state'") + $findings }
  $changed = @($findings).Count
  $result = if ($failed) { 'ERROR' } elseif ($changed -gt 0) { 'DRIFT' } else { 'clean' }
  $sorted = [string[]]@($findings)
  if ($sorted.Count -gt 1) { [Array]::Sort($sorted, [StringComparer]::Ordinal) }
  $more = $sorted.Count - $script:MaxFindingsPerUnit
  if ($more -gt 0) { $sorted = [string[]]@($sorted[0..($script:MaxFindingsPerUnit - 1)]) + @("and $more more, in the job summary of the unit") }
  $diag = @(@(Get-Prop $props 'diagnostics') | Where-Object { $null -ne $_ })
  $messages = @()
  foreach ($d in $diag) {
    if ($messages.Count -ge $script:MaxDiagnostics) { $messages += "and $($diag.Count - $script:MaxDiagnostics) more, in the artifact of the job"; break }
    $line = ConvertTo-OneLine "$([string](Get-Prop $d 'level')) $([string](Get-Prop $d 'code')): $([string](Get-Prop $d 'message')) $([string](Get-Prop $d 'target'))".Trim()
    if ($line.Length -gt 400) { $line = $line.Substring(0, 400) + '...' }
    $messages += $line
  }
  return [pscustomobject]@{ unit = $Unit; result = $result; counts = $counts; resources = $changes.Count; changed = $changed
                            adopted = $adopted; firstRun = [bool]$firstRun; diagnostics = $diag.Count
                            diagnosticMessages = [string[]]$messages; findings = $sorted }
}

# Text from Azure inside a fenced code block of a job summary. The fence is longer than any run of backticks in
# the text, so the text cannot end the block. A text longer than $script:MaxSummaryChars is cut, with a line that
# says so.
function ConvertTo-CodeBlock([string]$Text, [string]$Language = 'text') {
  $t = $Text -replace "`r`n?", "`n"
  if ($t.Length -gt $script:MaxSummaryChars) { $t = $t.Substring(0, $script:MaxSummaryChars) + "`n`nThe text is cut here. The artifact of this job holds all of it." }
  $longest = 0
  foreach ($m in [regex]::Matches($t, '`+')) { if ($m.Length -gt $longest) { $longest = $m.Length } }
  $fence = '`' * [Math]::Max(3, $longest + 1)
  return "$fence$Language`n$t`n$fence"
}

# The job summary of one stack preview: where the stack is, what happens to a resource that left the template, the
# count of each change type, and the preview as the Azure CLI prints it.
function Format-StackWhatIfSummary($Row, $Verdict, [string]$PrettyText) {
  $where = if ($Row.stackScope -ceq 'resourceGroup') { "the resource group $(ConvertTo-CodeSpan $Row.resourceGroup) of the subscription $(ConvertTo-CodeSpan $Row.scope)" }
           elseif ($Row.stackScope -ceq 'subscription') { "the subscription $(ConvertTo-CodeSpan $Row.scope)" }
           else { "the management group $(ConvertTo-CodeSpan $Row.managementGroup)" }
  $leave = if ($Row.unmanage -ceq 'delete') { 'A resource that left the template is **deleted** by the deployment, because the unit has stackDeletes true. A resource group and a management group are only detached.' }
           else { 'A resource that left the template is detached by the deployment, which leaves it in Azure.' }
  $lines = @("### Stack preview of $(ConvertTo-CodeSpan $Row.unit)", '',
             "Deployment stack $(ConvertTo-CodeSpan $Row.stack) at $where. $leave No deny settings.", '')
  if ($Verdict.firstRun) { $lines += @("The stack does not exist yet, so this is the first run of the unit. $($Verdict.adopted) resource(s) that exist come under the stack's management. Before its first deployment a stack has no baseline, so this preview still lists differences that a deployment does not change.", '') }
  $lines += @('| Change type | Resources |', '|---|---|')
  foreach ($k in @($Verdict.counts.Keys)) { $lines += "| $(ConvertTo-CodeSpan $k) | $($Verdict.counts[$k]) |" }
  if (@($Verdict.counts.Keys).Count -eq 0) { $lines += '| none | 0 |' }
  $lines += ''
  $lines += $(if ($Verdict.result -ceq 'clean') { "Every one of the $($Verdict.resources) resource(s) is noChange." }
              elseif ($Verdict.result -ceq 'DRIFT') { "$($Verdict.changed) of the $($Verdict.resources) resource(s) would change. The preview below lists each one with its properties." }
              elseif ($Verdict.diagnostics -gt 0 -and @($Verdict.findings).Count -gt 0 -and ([string]$Verdict.findings[0]).StartsWith('the preview is not a full check')) { "Every one of the $($Verdict.resources) resource(s) Azure evaluated is noChange, and the unit still counts as not checked." }
              else { 'Azure did not finish the preview.' })
  if ($Verdict.diagnostics -gt 0) {
    $lines += @('', "**Azure added $($Verdict.diagnostics) diagnostic message(s) to the preview.** A diagnostic means Azure could not evaluate a part of the stack, so the preview does not show what a deployment does to that part. Read each one before the plan is approved.", '')
    $lines += @($Verdict.diagnosticMessages | ForEach-Object { "- $(ConvertTo-CodeSpan $_)" })
  }
  if ($PrettyText) { $lines += @('', '<details><summary>The preview as the Azure CLI prints it</summary>', '', (ConvertTo-CodeBlock $PrettyText), '', '</details>') }
  elseif (@($Verdict.findings).Count -gt 0) { $lines += @('', 'The text of the preview could not be read back, so the resources are listed without their properties.', '') + @($Verdict.findings | ForEach-Object { "- $(ConvertTo-CodeSpan $_)" }) }
  return ($lines + '')
}

# The unit a job works on: UNIT must name exactly one unit of deploy/units.json, with the same case.
function Get-RowFromEnvironment {
  $units = Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/units.json')
  $name = Get-EnvValue 'UNIT'
  $u = Find-UnitDef $units $name
  if ($null -eq $u) { Stop-Check "the unit '$name' is not exactly one unit in deploy/units.json. A unit name is written with the same case as in the file" }
  try { return (Get-UnitRow $u $units) } catch { Stop-Check "deploy/units.json: $($_.Exception.Message)" }
}

# Units mode. Writes the step output matrix, the rows of the units a workflow works on.
function Invoke-UnitsMode {
  $select = Get-EnvValue 'SELECT'
  $root = $script:RepoRoot
  $units = Read-JsonFile (Join-RepoPath $root 'deploy/units.json')
  $all = @(Get-Prop $units 'units')
  $notes = @(); $pick = @()
  if ($select -ceq 'unit') {
    $name = Get-EnvValue 'UNIT'
    $u = Find-UnitDef $units $name
    if ($null -eq $u) { Stop-Check "the unit '$name' is not exactly one unit in deploy/units.json. A unit name is written with the same case as in the file" }
    if (Test-DeployExcludedUnit $u) { Stop-Check "the unit $name is the unit of a deploy-excluded file, and such a unit is never deployed. Its resources are written by hand, or moved to the routine file of the group first" }
    if ((Get-Prop $u 'enabled') -isnot [bool] -or -not (Get-Prop $u 'enabled')) { Stop-Check "the unit $name is not enabled in deploy/units.json. A unit is enabled in a code pull request before its first deployment" }
    $pick = @($u)
    # The change ticket and the reason of Run workflow, for the record of the run.
    $notes += "Change ticket $(ConvertTo-CodeSpan (Get-EnvValue 'CHANGE_REF')). Reason: $(ConvertTo-CodeSpan (Get-EnvValue 'REASON')). Started by $(ConvertTo-CodeSpan (Get-EnvValue 'STARTED_BY'))."
  } elseif ($select -ceq 'deployed') {
    # The units whose stack exists. A unit gets "deployed": true in a code pull request after its first deployment.
    $pick = @($all | Where-Object { (Get-Prop $_ 'deployed') -is [bool] -and (Get-Prop $_ 'deployed') -and -not (Test-DeployExcludedUnit $_) })
    if ($pick.Count -eq 0) { $notes += 'No unit in deploy/units.json is marked "deployed": true, so there is no deployment stack to check.' }
  } elseif ($select -ceq 'pullRequest') {
    # The workflow runs only for pull requests into master, from a branch of this repository. A fork would run its
    # own Bicep with the reader identity. This repeats both in case the trigger is ever widened.
    $baseRef = Get-EnvValue 'BASE_REF'
    if ($baseRef -cne 'master') { Stop-Check "this pull request goes into '$baseRef', and the pipeline previews only pull requests into master" }
    $repo = Get-EnvValue 'GITHUB_REPOSITORY'; $headRepo = Get-EnvValue 'HEAD_REPO'
    if (-not $headRepo -or $headRepo -cne $repo) { Stop-Check "the pull request comes from the repository '$headRepo', and the pipeline previews only a branch of $repo" }
    # The run's commit is GitHub's test merge of the branch into master's tip. Its first parent is master's tip, so
    # the difference between the two is what the merge would change.
    $merge = Get-EnvValue 'MERGE_SHA'
    $base = ((Invoke-Git @('rev-parse', '--verify', "$merge^1") -AllowFailure).Out -join '').Trim()
    if ($base -cnotmatch '^[0-9a-f]{40}\z' -or -not (Test-GitCommit $base)) { Stop-Check "this run's merge commit '$merge' has no first parent in the checkout, so the commit of master to compare with is not known" 2 }
    $entries = @(Get-GitChanges $base $merge)
    $baseUnitsText = Get-GitText $base 'deploy/units.json'
    $changedEntries = @()
    if ($baseUnitsText) { $changedEntries = @(Get-ChangedUnitEntries (Read-JsonText $baseUnitsText 'deploy/units.json at the base') $units) }
    $res = Resolve-AffectedUnits @($entries | ForEach-Object { $_.Path }) $units (Get-UnitFiles $units $root) $changedEntries
    $pick = @($res.preview | ForEach-Object { Find-UnitDef $units $_ } | Where-Object { $null -ne $_ })
    $notes = @("$($entries.Count) changed file(s), $($pick.Count) unit(s) to preview.") + @($res.notes)
  } else { Stop-Check "SELECT '$select' is not unit, deployed or pullRequest" 2 }
  $rows = @()
  foreach ($u in $pick) { try { $rows += (Get-UnitRow $u $units) } catch { Stop-Check "deploy/units.json: $($_.Exception.Message)" } }
  if ($rows.Count -gt $script:MaxMatrixJobs) { Stop-Check "$($rows.Count) units are selected, and a job matrix holds at most $($script:MaxMatrixJobs) jobs" }
  Set-StepOutput 'matrix' $(if ($rows.Count -gt 0) { ConvertTo-CompactJson @($rows) } else { '[]' })
  Write-Summary (@("Units: $(if ($rows.Count -gt 0) { (@($rows | ForEach-Object { ConvertTo-CodeSpan $_.unit }) -join ', ') } else { 'none' }).") + @($notes | ForEach-Object { "- $_" }))
}

# StackWhatIf mode. Validates and previews the deployment stack of one unit with the Azure CLI. The JSON of the
# preview (whatif.json), its text (whatif.txt) and what it says (whatif-result.json) go to -Dir, and the summary
# to the job summary. The script counts the change types Azure reports and compares nothing itself.
function Invoke-StackWhatIfMode {
  if (-not $Dir) { Stop-Check '-Dir is required' 2 }
  New-Item -ItemType Directory -Force -Path $Dir | Out-Null
  $row = Get-RowFromEnvironment
  $resultFile = Join-Path $Dir 'whatif-result.json'
  $fail = {
    param([string]$What, [string]$ErrorText)
    $short = if ($ErrorText.Length -gt 6000) { $ErrorText.Substring(0, 6000) } else { $ErrorText }
    $row0 = [pscustomobject]@{ unit = $row.unit; result = 'ERROR'; findings = @("$What failed. The job log and summary of the unit say why") }
    [IO.File]::WriteAllText($resultFile, (ConvertTo-Json -InputObject $row0 -Depth 6), $script:Utf8NoBom)
    Write-Summary @("### Stack preview of $(ConvertTo-CodeSpan $row.unit)", '', "**$What failed**, so there is no preview of this unit.", '', (ConvertTo-CodeBlock $short), '')
    Write-Host "::error::$(ConvertTo-OneLine "$What of the unit $($row.unit) failed: $short")"
    Set-StepOutput 'result' 'ERROR'
    exit 2
  }
  $r = Invoke-Native 'az' (Get-StackArguments $row $script:RepoRoot 'validate') -AllowFailure
  if ($r.Code -ne 0) { & $fail 'The validation of the stack' ("$($r.Err)`n$($r.Out -join "`n")".Trim()) }
  Write-Host "The stack $($row.stack) is valid."
  # The preview is named after the stack and the run that took it, or after the time outside a workflow run.
  $runId = Get-EnvValue 'GITHUB_RUN_ID'
  $resultName = if ($runId -cmatch '^[0-9]+\z') { "$($row.stack)-$runId-$(Get-EnvValue 'GITHUB_RUN_ATTEMPT' '1')" } else { "$($row.stack)-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())" }
  $r = Invoke-Native 'az' (Get-StackArguments $row $script:RepoRoot 'whatif' $resultName) -AllowFailure
  $json = ($r.Out -join "`n").Trim()
  if ($r.Code -ne 0 -or -not $json) { & $fail 'The preview of the stack' ("$($r.Err)`n$json".Trim()) }
  [IO.File]::WriteAllText((Join-Path $Dir 'whatif.json'), $json, $script:Utf8NoBom)
  # The time Azure returned the preview, in seconds since 1970 (UTC). The apply job refuses a plan that is too old.
  Set-StepOutput 'taken' ([string][DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
  try { $doc = ConvertFrom-Json @MirrorJsonArgs -InputObject $json } catch { & $fail 'Reading the preview of the stack' "$($_.Exception.Message)" }
  $verdict = Get-StackWhatIfVerdict $doc $row.unit
  # The same stored preview as text, the way the Azure CLI prints it. The step goes on without it.
  $pretty = ''
  $s = Invoke-Native 'az' (Get-StackArguments $row $script:RepoRoot 'show' $resultName) -AllowFailure
  if ($s.Code -eq 0) { $pretty = ($s.Out -join "`n").Trim(); [IO.File]::WriteAllText((Join-Path $Dir 'whatif.txt'), $pretty, $script:Utf8NoBom) }
  else { Write-Host "::warning::$(ConvertTo-OneLine "the text of the preview could not be read back: $($s.Err)")" }
  # The drift check answers whether live equals the code. A preview with a diagnostic cannot answer that for the
  # part Azure did not evaluate, so the unit counts as not checked and never as clean.
  $drift = (Get-EnvValue 'FAIL_ON_CHANGES') -ceq 'true'
  $partial = ($drift -and $verdict.result -ceq 'clean' -and $verdict.diagnostics -gt 0)
  if ($partial) {
    $verdict.result = 'ERROR'
    $verdict.findings = [string[]](@("the preview is not a full check, because Azure added $($verdict.diagnostics) diagnostic message(s)") + @($verdict.diagnosticMessages))
  }
  [IO.File]::WriteAllText($resultFile, (ConvertTo-Json -InputObject $verdict -Depth 6), $script:Utf8NoBom)
  Write-Summary (Format-StackWhatIfSummary $row $verdict $pretty)
  Set-StepOutput 'result' $verdict.result
  if ($partial) { Write-Host "::error::the preview of the unit $($row.unit) carries $($verdict.diagnostics) diagnostic message(s) of Azure, so it is not a full check of the unit"; exit 2 }
  Write-Host "Stack preview of $($row.unit): $($verdict.result), $($verdict.changed) of $($verdict.resources) resource(s) would change."
  if ($verdict.result -ceq 'ERROR') { Write-Host "::error::Azure did not finish the preview of the unit $($row.unit)"; exit 2 }
  if ($verdict.result -ceq 'DRIFT' -and $drift) {
    Write-Host "::error::the unit $($row.unit) differs from its code in $($verdict.changed) resource(s)"
    exit 1
  }
}

# StackSummary mode. After the apply, reads the stack and writes its state and the count of the resources it
# manages, detached, deleted and failed on to the job summary.
function Invoke-StackSummaryMode {
  $row = Get-RowFromEnvironment
  $outcome = Get-EnvValue 'OUTCOME' 'unknown'
  $lines = @("### Deployment of $(ConvertTo-CodeSpan $row.unit)", '', "The step that creates or updates the deployment stack $(ConvertTo-CodeSpan $row.stack) ended with $(ConvertTo-CodeSpan $outcome).", '')
  $r = Invoke-Native 'az' (Get-StackArguments $row $script:RepoRoot 'stack') -AllowFailure
  $doc = $null
  if ($r.Code -eq 0) { try { $doc = ConvertFrom-Json @MirrorJsonArgs -InputObject ($r.Out -join "`n") } catch { $doc = $null } }
  if ($null -eq $doc) { $lines += "The stack could not be read afterwards: $(ConvertTo-CodeSpan $r.Err)" }
  else {
    $p = if ($null -ne (Get-Prop $doc 'properties')) { Get-Prop $doc 'properties' } else { $doc }
    $n = { param($k) @(Get-Prop $p $k | Where-Object { $null -ne $_ }).Count }
    $aou = Get-Prop $p 'actionOnUnmanage'
    $lines += @('| Stack | Value |', '|---|---|',
      "| State | $(ConvertTo-CodeSpan ([string](Get-Prop $p 'provisioningState'))) |",
      "| Managed resources | $(& $n 'resources') |", "| Detached in this deployment | $(& $n 'detachedResources') |",
      "| Deleted in this deployment | $(& $n 'deletedResources') |", "| Failed | $(& $n 'failedResources') |",
      "| Action on unmanage | resources $(ConvertTo-CodeSpan ([string](Get-Prop $aou 'resources'))), resource groups $(ConvertTo-CodeSpan ([string](Get-Prop $aou 'resourceGroups'))), management groups $(ConvertTo-CodeSpan ([string](Get-Prop $aou 'managementGroups'))) |",
      "| Deny settings | $(ConvertTo-CodeSpan ([string](Get-Prop (Get-Prop $p 'denySettings') 'mode'))) |")
    # The drift check previews only the units marked deployed, and the mark is set by hand.
    $def = Find-UnitDef (Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/units.json')) $row.unit
    if ($outcome -ceq 'success' -and (Get-Prop $def 'deployed') -ne $true) {
      $lines += @('', "**The unit $(ConvertTo-CodeSpan $row.unit) is not marked deployed yet.** Add ``""deployed"": true`` to its entry in deploy/units.json in a code pull request, or the weekly drift check never previews it.")
    }
  }
  Write-Summary ($lines + '')
}

# ---------------------------------------------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------------------------------------------
if (-not $Mode) { return }
try {
  switch ($Mode) {
    'Hygiene' { Invoke-HygieneMode }
    'PortabilityScope' { Invoke-PortabilityScopeMode }
    'DriftReport' { Invoke-DriftReportMode }
    'InputCheck' { Invoke-InputCheckMode }
    'Units' { Invoke-UnitsMode }
    'StackWhatIf' { Invoke-StackWhatIfMode }
    'StackSummary' { Invoke-StackSummaryMode }
  }
} catch {
  Stop-Check "$Mode failed: $($_.Exception.Message)" 2
}
exit 0
