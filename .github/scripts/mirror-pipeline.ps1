<#
.SYNOPSIS
  The pipeline's own checks around scripts/deploy-unit.ps1: the plan and the checks before a deployment, the preview
  on a pull request, and the summaries. Every workflow under .github/workflows calls this one file.

.DESCRIPTION
  A deployment from the pipeline is a plan followed by an apply, both jobs of one run of mirror-deploy-unit. The run
  starts with a push to master (a merged pull request) or with Run workflow on master. The plan signs in with the
  reader identity and runs the dry run and the gate. The apply waits for the required reviewers of the unit's
  mirror-production or mirror-privileged environment, who did not start the run, and then deploys exactly what the plan showed. The
  workflows call this script in one of these modes:

    Hygiene        mirror-validate. Catches workflow files that could hand a deploy token to code nobody reviewed
                   (a check for mistakes, the controls are GitHub settings), and a job without the pipeline switch
                   (the repository variable MIRROR_PIPELINE_ENABLED)
    PipelineScope  mirror-validate. Compiles every unit as Azure receives it (through its parameters file). Fails
                   when a production unit declares a role definition, a role assignment of Owner, User Access
                   Administrator or Role Based Access Control Administrator, or a role assignment whose role the
                   compiled template does not show, because a production deploy identity cannot write those and
                   they belong in a privileged unit. Also fails when any unit declares a data-access grant not in
                   the list of known grants
    InputCheck     mirror-pr, mirror-deploy-unit and mirror-drift, before the sign-in to Azure. Reads every Bicep
                   file of the checkout and refuses one that reads an environment variable, a registry module or a
                   file outside the repository, or uses a form this check does not read
    Plan           mirror-pr. A code pull request. Lists the units to preview
    Preview        mirror-pr. A plain what-if of one unit of the pull request's Bicep, judged offline by master's
                   deploy-unit.ps1 -WhatIfJson, because the job takes the scripts from master's tip
    Report         mirror-pr. One pull request comment with every verdict. Decides the required check
    Select         mirror-deploy-unit. Picks the units to plan. A push plans every enabled unit whose files changed.
                   Run workflow plans the one unit it names, after checking its inputs
    DeployPlan     mirror-deploy-unit, plan job. The dry run and the gate of one unit with its options. Writes the
                   verdict, the job summary and the reviewed plan
    Collect        mirror-deploy-unit. Reads the reviewed plans and lists the units whose apply waits for a reviewer,
                   one list for the production tier and one for the privileged tier
    CheckApply     mirror-deploy-unit, apply and apply-privileged jobs, after the approval. First attempt, master
                   still at the planned commit, the plan recent, the unit still enabled, still of the tier of the
                   job and still able to run in the pipeline
    ComparePlan    mirror-deploy-unit, apply and apply-privileged jobs. A fresh dry run shows the same records as the reviewed plan, apart
                   from the resources the options name
    DeploySummary  mirror-deploy-unit. Writes pipeline-deployment.json in the evidence and the job summary

  The plan belongs to one commit of master, the commit the run started on. The apply refuses when master has moved
  since, so nothing deploys from a plan of other code. A reviewer approves the plan that the run shows, with the
  options it names, and the apply takes those options from the plan and never from anything typed again.

  With no -Mode the script only defines its functions, so a workflow step or the tests can dot-source it.
  Every unit runs in the pipeline. A unit has a tier in deploy/units.json. A unit with no tier is production, and
  its deploy identity cannot write an Owner-class role assignment or a role definition. The privileged tier holds
  those, deployed by a separate identity through a separate environment with its own approvers. Tenant-kind units
  are privileged and deploy at management group scope.

  Values reach the script through environment variables that the workflow sets with env:, never through text
  pasted into the command line.

.NOTES
  Exit codes: 0 passed. 1 a check refused. 2 a tool or set-up error. Runs on Windows PowerShell 5.1 and on PowerShell 7
  on Windows and Linux.
#>
[CmdletBinding()]
param(
  [ValidateSet('', 'Hygiene', 'PipelineScope', 'InputCheck', 'Plan', 'Preview', 'Report', 'Select', 'DeployPlan',
               'Collect', 'CheckApply', 'ComparePlan', 'DeploySummary')]
  [string]$Mode = '',
  [string]$Dir,
  [string]$EvidenceRoot
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------------------------
# Settings. Repository variables of the same name override the numbers (Settings > Secrets and variables >
# Actions > Variables). The workflows pass them in through env:.
# ---------------------------------------------------------------------------------------------------------------
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
# Files that change the judgement of every unit. A change there needs a sweep, not a preview of one unit.
$script:GlobalFiles = @('bicepconfig.json', 'deploy/boundaries.json', 'scripts/deploy-unit.ps1')
# The longest a reviewed plan may wait before the apply, in hours. MIRROR_MAX_PLAN_AGE_HOURS overrides it.
$script:DefaultMaxPlanAgeHours = 24
# Resource types that grant access to data through the resource's own settings. Contributor can write them, so a
# pipeline unit may declare only the ones in $script:KnownDataGrants, each as "<unit>|<type> (<name in the
# compiled template>)".
# A new one goes into this list after IT reviews it as an access change.
$script:DataGrantTypes = @('Microsoft.KeyVault/vaults/accessPolicies', 'Microsoft.DocumentDB/databaseAccounts/*RoleAssignments',
  'Microsoft.DocumentDB/databaseAccounts/*RoleDefinitions', 'Microsoft.DocumentDB/databaseAccounts/*UserDefinitions',
  'Microsoft.Sql/servers/administrators', 'Microsoft.Sql/servers/azureADOnlyAuthentications',
  'Microsoft.Sql/managedInstances/administrators', 'Microsoft.DBforPostgreSQL/flexibleServers/administrators',
  'Microsoft.DBforMySQL/flexibleServers/administrators', 'Microsoft.Synapse/workspaces/administrators',
  'Microsoft.Kusto/clusters/principalAssignments', 'Microsoft.Kusto/clusters/databases/principalAssignments')
$script:KnownDataGrants = @()
$script:MaxPreviewUnits = 12
$script:CommentMarker = '<!-- mirror-pr -->'
# The account that writes as the workflow's own token. Only its comments are the pipeline's own.
$script:BotLogin = 'github-actions[bot]'
$script:MaxSummaryChars = 60000
# The only actions a workflow may use, each pinned to a full commit SHA.
$script:AllowedActions = @('actions/checkout', 'actions/upload-artifact', 'actions/download-artifact', 'azure/login')
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding $false
# The runner images a job may run on, the two the scripts and the pinned tools are checked on. A -latest label
# moves to a new system without a change in the repository, and a repository variable changes without a review.
# So a job names one of the two images, or one of the two expressions below. They map the repository variable
# MIRROR_RUNNER to the two images and nothing else. The first gives ubuntu-24.04 when the variable is
# ubuntu-24.04 and windows-2025 for any other value or none. The second gives the other image, for the
# portability job. The first step of every job is the runner check, which stops the job on any other runner.
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

# Strict mode throws on a missing property. JSON from git, GitHub and the gate omits fields freely.
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

# The distinct texts of a list, in ordinal order.
function Get-OrdinalSet($Items) {
  $set = New-Object 'System.Collections.Generic.SortedSet[string]' ([StringComparer]::Ordinal)
  foreach ($i in @($Items)) { if ($null -ne $i) { [void]$set.Add([string]$i) } }
  return [string[]]@($set)
}

function Get-EnvValue([string]$Name, [string]$Default = '') {
  $v = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
  return $v.Trim()
}

function Get-EnvInt([string]$Name, [int]$Default) {
  $v = Get-EnvValue $Name
  $n = 0
  if ($v -and [int]::TryParse($v, [ref]$n) -and $n -gt 0) { return $n }
  return $Default
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

function Test-GitAncestor([string]$Ancestor, [string]$Descendant) {
  return ((Invoke-Git @('merge-base', '--is-ancestor', $Ancestor, $Descendant) -AllowFailure).Code -eq 0)
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

# The roles whose assignment only a privileged unit may declare: Owner, User Access Administrator and Role Based
# Access Control Administrator.
$script:PrivilegedRoleIds = @('8e3af657-a8ff-443c-a75c-2fe8c4bcb635', '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9', 'f58310d9-a9f6-439a-9e8d-f62e7b41a168')

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

# The GitHub environment of a unit: mirror-<tier>-<scope>, or $null when the tier is not one the pipeline knows.
function Get-UnitEnvironment($UnitDef) {
  $tier = Get-UnitTier $UnitDef
  if ($null -eq $tier) { return $null }
  return "mirror-$tier-$(Get-UnitScope $UnitDef)"
}

# Why a unit cannot be previewed, or $null. What-if cannot read a resource name with a # in it, so the unit that
# holds the certificate with a # in its name never passes the gate.
function Get-UnrunnableReason($UnitDef) {
  $n = [string](Get-Prop $UnitDef 'name')
  if ($n -like '*-hash-excluded') { return 'a resource name with a # in it, which what-if cannot preview' }
  return $null
}

# The beginning of every resource ID a unit may name in allowCreate, allowModify and allowHeld, or $null when the
# subscription of the unit is not in the list. A tenant-kind unit works at management group scope, and the groups it
# declares sit beside its own, so the prefix is every management group.
function Get-UnitIdPrefix($UnitDef, $UnitsDoc) {
  if ([string](Get-Prop $UnitDef 'kind') -ceq 'tenant') { return '/providers/Microsoft.Management/managementGroups/' }
  $subId = [string](Get-Prop (Get-Prop $UnitsDoc 'subscriptions') ([string](Get-Prop $UnitDef 'subscription')))
  if (-not $subId) { return $null }
  if ([string](Get-Prop $UnitDef 'kind') -ceq 'resourceGroup') { return "/subscriptions/$subId/resourceGroups/$(Get-Prop $UnitDef 'resourceGroup')/" }
  return "/subscriptions/$subId/"
}

# One of the 11 subscription units (a subscription folder's main.bicep), the part of a subscription that is not
# privileged.
function Test-SubscriptionMainUnit($UnitDef) {
  return ([string](Get-Prop $UnitDef 'kind') -eq 'subscription' -and
          ([string](Get-Prop $UnitDef 'template')).Replace('\', '/') -match '^infra/subscriptions/[^/]+/main\.bicep$')
}

function Find-UnitDef($UnitsDoc, [string]$Name) {
  $m = @(@(Get-Prop $UnitsDoc 'units') | Where-Object { Test-Same ([string](Get-Prop $_ 'name')) $Name })
  if ($m.Count -ne 1) { return $null }
  return $m[0]
}

# The same type and name rules as deploy-unit.ps1, so an allowHeld ID is checked the way the gate checks it.
function Get-ResourceType([string]$Id) {
  $i = $Id.ToLowerInvariant().LastIndexOf('/providers/')
  if ($i -lt 0) {
    if ($Id -match '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+$') { return 'Microsoft.Resources/resourceGroups' }
    return 'unknown'
  }
  $parts = $Id.Substring($i + 11).Split('/')
  $t = @($parts[0])
  for ($k = 1; $k -lt $parts.Count; $k += 2) { $t += $parts[$k] }
  return ($t -join '/')
}

function Get-ResourceNameChain([string]$Id) {
  $i = $Id.ToLowerInvariant().LastIndexOf('/providers/')
  if ($i -lt 0) { return ($Id.Split('/')[-1]) }
  $parts = $Id.Substring($i + 11).Split('/')
  $n = @()
  for ($k = 2; $k -lt $parts.Count; $k += 2) { $n += $parts[$k] }
  return ($n -join '/')
}

function Find-Hold($Holds, [string]$Id) {
  $type = Get-ResourceType $Id
  $chain = Get-ResourceNameChain $Id
  foreach ($h in @($Holds)) {
    if ($null -eq $h) { continue }
    $idp = Get-Prop $h 'idPattern'
    if ($idp) { if ([regex]::IsMatch($Id, $idp)) { return $h } else { continue } }
    if ([string](Get-Prop $h 'type') -eq $type -and [regex]::IsMatch("/$chain", [string](Get-Prop $h 'namePattern'))) { return $h }
  }
  return $null
}

function Test-IdList($Value, [string]$Field, [string]$Prefix) {
  $errors = @()
  if ($null -eq $Value -or -not ($Value -is [System.Array])) { return @("$Field must be a list of resource IDs (use [] for none)") }
  $seen = @{}
  foreach ($id in $Value) {
    if (-not ($id -is [string]) -or [string]::IsNullOrWhiteSpace($id)) { $errors += "$Field holds an entry that is not a resource ID"; continue }
    # \p{C} holds the control and the invisible format characters (a zero-width space among them), and the class
    # after it every space but the plain one. The soft hyphen is named too, because .NET Framework, which Windows
    # PowerShell 5.1 runs on, classes it as a dash and not as a format character.
    if (-not (Test-Same $id $id.Trim()) -or $id -match '\p{C}|[\p{Z}-[\x20]]|\u00AD' -or $id.EndsWith('/')) { $errors += "$Field entry '$id' has spaces at its ends, a control or invisible character, or a trailing slash"; continue }
    if (-not $id.StartsWith($Prefix, [StringComparison]::OrdinalIgnoreCase) -or $id.Length -le $Prefix.Length) { $errors += "$Field entry '$id' is not inside the unit's scope ($Prefix...)"; continue }
    $k = $id.ToLowerInvariant()
    if ($seen.ContainsKey($k)) { $errors += "$Field lists '$id' twice" }
    $seen[$k] = $true
  }
  return $errors
}

# The arguments for scripts/deploy-unit.ps1, for splatting. -Deploy builds the deploy run: -DryRun:$false
# -Approve and, with allowModify, -ApprovedChanges pointing at the folder of the reviewed plan. Without
# -Deploy it is the dry run with the same options, which is what the reviewer reads.
function Get-GateArguments($Options, [string]$EvidenceRoot, [string]$ApprovedDir, [switch]$Deploy) {
  $o = Get-DeployOptions $Options
  $a = @{ EvidenceRoot = $EvidenceRoot }
  if ($o.acknowledgeReview) { $a.AcknowledgeReview = $true }
  if ($o.allowCreate.Count -gt 0) { $a.AllowCreate = $o.allowCreate }
  if ($o.allowHeld.Count -gt 0) { $a.AllowHeld = $o.allowHeld }
  if ($o.allowModify.Count -gt 0) { $a.AllowModify = $o.allowModify }
  if ($Deploy) {
    $a.DryRun = $false
    $a.Approve = $true
    if ($o.allowModify.Count -gt 0) {
      $gates = @(Get-ChildItem -LiteralPath $ApprovedDir -Recurse -Filter 'pre-gate.json' -File -ErrorAction SilentlyContinue)
      if ($gates.Count -ne 1) { throw "expected one pre-gate.json in the approved dry run under $ApprovedDir, found $($gates.Count)" }
      $a.ApprovedChanges = $gates[0].DirectoryName
    }
  }
  return $a
}

# The header of a pre-summary.txt (the lines before the first blank line), read the way deploy-unit.ps1 reads
# it for -ApprovedChanges, where the first line of a key counts. AllowModify carries an optional note after two
# spaces, and AllowHeld has two spaces after its colon.
function Read-DryRunHeader([string[]]$Lines) {
  $fields = @{}
  $create = @(); $modify = @(); $held = @()
  foreach ($l in @($Lines)) {
    if ($l -eq '') { break }
    if ($l -match '^AllowModify: (.+?)(  \(no Modify record for it in this preview\))?$') { $modify += $Matches[1]; continue }
    if ($l -match '^AllowCreate: (.+)$') { $create += $Matches[1]; continue }
    if ($l -match '^AllowHeld:  (.+)$') { $held += $Matches[1]; continue }
    if ($l -match '^(\w+):\s+(.*)$' -and -not $fields.ContainsKey($Matches[1])) { $fields[$Matches[1]] = $Matches[2].Trim() }
  }
  return [pscustomobject]@{ fields = $fields; allowCreate = $create; allowModify = $modify; allowHeld = $held }
}

function Test-SameIdSet([string[]]$A, [string[]]$B) {
  $x = @(Get-OrdinalSet @(@($A) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }))
  $y = @(Get-OrdinalSet @(@($B) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() }))
  return (Test-Same ($x -join "`n") ($y -join "`n"))
}

# Can a person approve this dry run? Its gate passed, or it stopped for review only because the resources named in
# allowModify would change (a dry run never writes them). A review boundary or a review record still waiting for
# acknowledgeReview, a failed record or a problem with the preview makes it not approvable.
function Test-Approvable($Gate) {
  $reasons = @()
  $overall = [string](Get-Prop $Gate 'overall')
  foreach ($p in @(Get-Prop $Gate 'problems')) { if ($p) { $reasons += "problem with the preview: $p" } }
  $failed = 0; [void][int]::TryParse([string](Get-Prop $Gate 'failed'), [ref]$failed)
  if ($failed -gt 0) { $reasons += "$failed record(s) fail the gate" }
  if (-not (Test-InList @('pass', 'review', 'fail') $overall)) { $reasons += "the gate result '$overall' is not one the pipeline knows" }
  elseif ($overall -eq 'fail' -and $failed -eq 0 -and $reasons.Count -eq 0) { $reasons += 'the gate failed' }
  foreach ($d in @(Get-Prop $Gate 'decisions')) {
    if ($null -eq $d -or [string](Get-Prop $d 'verdict') -ne 'review') { continue }
    $id = [string](Get-Prop $d 'resourceId')
    $notes = @(@(Get-Prop $d 'notes') | ForEach-Object { [string]$_ })
    $why = $false
    if (@($notes | Where-Object { $_ -like 'review boundary *' -and $_ -notlike 'review boundary accepted:*' }).Count -gt 0) { $reasons += "review boundary waiting for acknowledgeReview: $id"; $why = $true }
    if (@($notes | Where-Object { $_ -like 'review record: *' }).Count -gt 0) { $reasons += "review record waiting for acknowledgeReview: $id"; $why = $true }
    if (-not $why -and @($notes | Where-Object { $_ -like '*; would be allowed with -AllowModify' }).Count -eq 0) { $reasons += "review verdict with no reason the pipeline knows: $id" }
  }
  return [pscustomobject]@{ ok = ($reasons.Count -eq 0); reasons = $reasons }
}

# The review items a run accepted with -AcknowledgeReview: review boundaries (resource and property) and review
# records (resource and record type).
function Get-AcceptedReviewItems($Gate) {
  $items = @()
  foreach ($d in @(Get-Prop $Gate 'decisions')) {
    if ($null -eq $d) { continue }
    foreach ($n in @(Get-Prop $d 'notes')) {
      $m = [regex]::Match([string]$n, '^review boundary accepted: (.+)$')
      if ($m.Success) { $items += ('boundary | {0} | {1}' -f ([string](Get-Prop $d 'resourceId')).ToLowerInvariant(), $m.Groups[1].Value) }
    }
  }
  foreach ($r in @(Get-Prop $Gate 'reviewRecords')) {
    if ($null -eq $r) { continue }
    if ([string](Get-Prop $r 'status') -eq 'acknowledged with -AcknowledgeReview') {
      $items += ('record | {0} | {1}' -f ([string](Get-Prop $r 'resourceId')).ToLowerInvariant(), [string](Get-Prop $r 'changeType'))
    }
  }
  return @(Get-OrdinalSet $items)
}

# Review items accepted now that the approved dry run did not show.
function Compare-ReviewItems($ApprovedGate, $NowGate) {
  $want = @(Get-AcceptedReviewItems $ApprovedGate)
  $have = @(Get-AcceptedReviewItems $NowGate)
  return @($have | Where-Object { -not (Test-InList $want $_) })
}

# ---------------------------------------------------------------------------------------------------------------
# The deployment request: what a push or Run workflow asks for, and what the plan and the apply check again.
# ---------------------------------------------------------------------------------------------------------------

# The option fields of a request, with the ID lists as string arrays.
function Get-DeployOptions($Request) {
  return [pscustomobject]@{
    acknowledgeReview = [bool](Get-Prop $Request 'acknowledgeReview')
    allowCreate = [string[]]@(@(Get-Prop $Request 'allowCreate') | Where-Object { $_ })
    allowModify = [string[]]@(@(Get-Prop $Request 'allowModify') | Where-Object { $_ })
    allowHeld = [string[]]@(@(Get-Prop $Request 'allowHeld') | Where-Object { $_ })
  }
}

# Checks a deployment request against deploy/units.json and deploy/boundaries.json as the run's commit holds them.
# $Request has unit, changeRef, reason, acknowledgeReview, allowCreate, allowModify and allowHeld. Returns the unit's
# definition and the list of what is wrong (empty when the request is good).
function Test-DeployRequest($Request, $UnitsDoc, $BoundariesDoc) {
  $errors = @()
  $unitDef = $null
  $unitName = [string](Get-Prop $Request 'unit')
  # A unit name is lower-case letters, digits and single hyphens, so a name with an invisible character never
  # reaches the lookup or the workflow outputs.
  if ($unitName -cnotmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\z') { $errors += 'unit must be a unit name from deploy/units.json (lower-case letters, digits and hyphens)' }
  else {
    $unitDef = Find-UnitDef $UnitsDoc $unitName
    if ($null -eq $unitDef) { $errors += "unit '$unitName' is not in deploy/units.json at this commit" }
    else {
      $unrunnable = Get-UnrunnableReason $unitDef
      if ($unrunnable) { $errors += "unit '$unitName' cannot run in the pipeline: $unrunnable" }
      if ($null -eq (Get-UnitTier $unitDef)) { $errors += "unit '$unitName' has the tier '$(Get-Prop $unitDef 'tier')' in deploy/units.json, which is neither absent (production) nor privileged" }
      if (-not [bool](Get-Prop $unitDef 'enabled')) { $errors += "unit '$unitName' is disabled in deploy/units.json at this commit. Enable it in a code pull request first" }
      $kind = [string](Get-Prop $unitDef 'kind')
      if ($kind -ceq 'tenant') {
        if (Get-Prop $unitDef 'subscription') { $errors += "unit '$unitName' is a tenant-kind unit and must have no subscription in deploy/units.json" }
        $mg = Get-Prop $unitDef 'managementGroup'
        if (-not ($mg -is [string]) -or $mg -cnotmatch '^[A-Za-z0-9._()-]{1,90}$') { $errors += "unit '$unitName' is a tenant-kind unit and must name its managementGroup in deploy/units.json" }
      } elseif ($kind -ceq 'resourceGroup' -or $kind -ceq 'subscription') {
        $sub = [string](Get-Prop $unitDef 'subscription')
        if (-not (Get-Prop (Get-Prop $UnitsDoc 'subscriptions') $sub)) { $errors += "unit '$unitName' names subscription '$sub', which is not in the subscriptions list" }
        if ($null -ne (Get-Prop $unitDef 'managementGroup')) { $errors += "unit '$unitName' names a managementGroup, and only a tenant-kind unit may" }
      } else { $errors += "unit '$unitName' has the kind '$kind', which is not resourceGroup, subscription or tenant" }
      if ($null -ne (Get-Prop $unitDef 'parameterOverrides')) { $errors += "unit '$unitName' has parameterOverrides, which the pipeline does not preview" }
    }
  }
  $ref = Get-Prop $Request 'changeRef'
  if (-not ($ref -is [string]) -or $ref -cnotmatch '^[A-Za-z0-9._/-]{3,64}$') { $errors += 'changeRef must be the change ticket number: 3 to 64 letters, digits or . _ / -' }
  $reason = Get-Prop $Request 'reason'
  if (-not ($reason -is [string]) -or -not $reason.Trim()) { $errors += 'reason must say what this deployment is for' }
  elseif ($reason.Length -gt 500) { $errors += 'reason is longer than 500 characters' }
  if (-not ((Get-Prop $Request 'acknowledgeReview') -is [bool])) { $errors += 'acknowledgeReview must be true or false' }

  $prefix = $null
  if ($null -ne $unitDef) { $prefix = Get-UnitIdPrefix $unitDef $UnitsDoc }
  if ($null -ne $unitDef -and $prefix) {
    # Read through PSObject, not Get-Prop, because a function return would unroll a list of one into a plain string.
    foreach ($f in @('allowCreate', 'allowModify', 'allowHeld')) {
      $p = $Request.PSObject.Properties[$f]
      $val = $null
      if ($null -ne $p) { $val = $p.Value }
      $errors += @(Test-IdList $val $f $prefix)
    }
    $held = $Request.PSObject.Properties['allowHeld']
    if ($null -ne $held -and $held.Value -is [System.Array]) {
      foreach ($id in @($held.Value)) {
        if ($id -is [string] -and $id -and $null -eq (Find-Hold (Get-Prop $BoundariesDoc 'holds') $id)) { $errors += "allowHeld entry '$id' matches no hold in deploy/boundaries.json" }
      }
    }
  }
  return [pscustomobject]@{ unitDef = $unitDef; errors = [string[]]$errors }
}

# The change ticket a merged pull request names, or '' when it names none. A line of the title or the body starts
# with the label, "Change: CHG0012345" or "Ticket: CHG0012345", followed by the ticket number alone. A ticket number
# is 3 to 64 letters, digits, dots, dashes, underscores or slashes, with at least one digit and no space, so a
# sentence that happens to begin with "Change:" names no ticket.
function Get-ChangeTicketFromText([string]$Title, [string]$Body) {
  foreach ($line in @(("$Title`n$Body") -split '\r?\n')) {
    $m = [regex]::Match($line, '^[ \t]*(?:change(?:[ \t]+ticket)?|ticket)[ \t]*:[ \t]*(?<t>[A-Za-z0-9._/-]{3,64})[ \t]*$', 'IgnoreCase')
    if ($m.Success -and $m.Groups['t'].Value -match '[0-9]') { return $m.Groups['t'].Value }
  }
  return ''
}

# Entries of deploy/boundaries.json that differ between two copies, as compact JSON texts. Holds and expected
# Ignore patterns can name a subscription (scoped). The boundaries, by resource type, and the holds by name never do
# (typeWide).
function Get-BoundaryChanges($OldDoc, $NewDoc) {
  $scoped = @(); $typeWide = @()
  foreach ($list in @('boundaries', 'holds', 'expectedIgnore')) {
    $old = @(@(Get-Prop $OldDoc $list) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-CompactJson $_ })
    $new = @(@(Get-Prop $NewDoc $list) | Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-CompactJson $_ })
    $diff = @(@($new | Where-Object { -not (Test-InList $old $_) }) + @($old | Where-Object { -not (Test-InList $new $_) }))
    foreach ($d in $diff) {
      if ($list -eq 'boundaries' -or ($list -eq 'holds' -and $d -notmatch '"idPattern"')) { $typeWide += $d } else { $scoped += $d }
    }
  }
  return [pscustomobject]@{ scoped = [string[]]$scoped; typeWide = [string[]]$typeWide }
}

# The units whose subscription appears in a changed hold or expected Ignore pattern.
function Get-BoundaryScopeUnits($Changes, $UnitsDoc) {
  $names = @()
  foreach ($u in @(Get-Prop $UnitsDoc 'units')) {
    $subId = [string](Get-Prop (Get-Prop $UnitsDoc 'subscriptions') ([string](Get-Prop $u 'subscription')))
    if (-not $subId) { continue }
    foreach ($c in @($Changes.scoped)) {
      if ($c.IndexOf($subId, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $names += [string](Get-Prop $u 'name'); break }
    }
  }
  return [string[]]$names
}

# True when the gate holds an effective change: a Create, Delete or Deploy record, or a Modify with at least one
# changed property that is neither NoEffect nor covered by an inert boundary. A Modify that passes the gate without
# any option holds only such properties, so it is no effective change. A Modify that does not pass, or one whose
# changed properties the gate lists and name another reason, is one. When the gate lists no records, only its
# counts are read, and a Modify count then counts as a change.
function Test-HasChanges($Gate) {
  $c = Get-Prop $Gate 'counts'
  if ($null -eq $c) { return $false }
  foreach ($k in @('Create', 'Delete', 'Deploy')) {
    $v = Get-Prop $c $k
    if ($null -ne $v -and [int]$v -gt 0) { return $true }
  }
  $m = Get-Prop $c 'Modify'
  if ($null -eq $m -or [int]$m -le 0) { return $false }
  $decisions = @(@(Get-Prop $Gate 'decisions') | Where-Object { $null -ne $_ })
  if ($decisions.Count -eq 0) { return $true }
  foreach ($d in $decisions) {
    if ([string](Get-Prop $d 'changeType') -cne 'Modify') { continue }
    if ([string](Get-Prop $d 'verdict') -cne 'pass') { return $true }
    foreach ($r in @(@(Get-Prop $d 'propertyChanges') | Where-Object { $null -ne $_ })) {
      $why = [string](Get-Prop $r 'decision')
      if (-not ($why.StartsWith('no effect', [StringComparison]::Ordinal) -or $why -ceq 'listed boundary')) { return $true }
    }
  }
  return $false
}

# The most hours a reviewed plan may wait before the apply.
function Get-MaxPlanAgeHours { return (Get-EnvInt 'MIRROR_MAX_PLAN_AGE_HOURS' $script:DefaultMaxPlanAgeHours) }

# The plan is recent enough for its apply. $Planned is the time the plan wrote.
function Test-PlanAge([string]$Planned, [DateTimeOffset]$Now, [int]$MaxHours) {
  $r = [DateTimeOffset]::MinValue
  if (-not [DateTimeOffset]::TryParse($Planned, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$r)) {
    return @('the plan has no readable time')
  }
  $age = ($Now - $r).TotalHours
  if ($age -lt -0.1) { return @('the plan time is in the future') }
  if ($age -gt $MaxHours) { return @(("the plan is {0:N1} hours old, and the limit is {1} hours (the repository variable MIRROR_MAX_PLAN_AGE_HOURS). Start the deployment again" -f $age, $MaxHours)) }
  return @()
}

# The reviewed plan is a dry run of this unit at this commit from a clean tree, its gate ended PASS or REVIEW, and
# it was taken with exactly the options of the run.
function Test-PlanMatches($Header, $Options, [string]$Unit, [string]$Commit) {
  $errors = @()
  $f = $Header.fields
  if (-not (Test-Same ([string]$f['Unit']) $Unit)) { $errors += "the plan is of unit '$($f['Unit'])', the run deploys '$Unit'" }
  if ($Commit -cnotmatch '^[0-9a-f]{40}$') { $errors += "the commit '$Commit' is not a full commit ID" }
  elseif (-not (Test-Same ([string]$f['Commit']) $Commit)) { $errors += "the plan was taken at '$($f['Commit'])', but this run is at $Commit. A plan taken from a tree with uncommitted changes never matches" }
  if (-not (Test-Same ([string]$f['Mode']) 'dry run')) { $errors += "the plan's mode is '$($f['Mode'])', not 'dry run'" }
  if (-not (Test-InList @('PASS', 'REVIEW') ([string]$f['Gate']))) { $errors += "the plan's gate ended '$($f['Gate'])'. Only PASS or REVIEW can be deployed" }
  if (-not (Test-SameIdSet $Header.allowCreate $Options.allowCreate)) { $errors += 'the plan was taken with another allowCreate list than the options of the run' }
  if (-not (Test-SameIdSet $Header.allowModify $Options.allowModify)) { $errors += 'the plan was taken with another allowModify list than the options of the run' }
  if (-not (Test-SameIdSet $Header.allowHeld $Options.allowHeld)) { $errors += 'the plan was taken with another allowHeld list than the options of the run' }
  return $errors
}

# The records of a gate result as "<resource ID in lower case> | <change type> | <verdict>", apart from the resources
# the options name, whose records the options are there to accept.
function Get-PlanRecords($Gate, $Options) {
  $named = @(@($Options.allowCreate) + @($Options.allowModify) + @($Options.allowHeld) | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
  $items = @()
  foreach ($d in @(Get-Prop $Gate 'decisions')) {
    if ($null -eq $d) { continue }
    $id = ([string](Get-Prop $d 'resourceId')).ToLowerInvariant()
    if (Test-InList $named $id) { continue }
    $items += ('{0} | {1} | {2}' -f $id, [string](Get-Prop $d 'changeType'), [string](Get-Prop $d 'verdict'))
  }
  return @(Get-OrdinalSet $items)
}

# What differs between the reviewed plan and a fresh dry run. Records only the fresh run shows, records only the plan
# showed, and review items accepted now that the plan did not show.
function Compare-PlanRecords($PlanGate, $FreshGate, $Options) {
  $p = @(Get-PlanRecords $PlanGate $Options)
  $f = @(Get-PlanRecords $FreshGate $Options)
  $out = @()
  foreach ($x in $f) { if (-not (Test-InList $p $x)) { $out += "new since the plan: $x" } }
  foreach ($x in $p) { if (-not (Test-InList $f $x)) { $out += "gone since the plan: $x" } }
  foreach ($x in @(Compare-ReviewItems $PlanGate $FreshGate)) { $out += "review item the plan did not show: $x" }
  return $out
}

# Which option would accept each record that stops the gate, as lines for the job summary and the Run workflow
# command that starts the same unit with those options. accepted is false when a record stops the gate and no
# option can accept it.
function Get-ExceptionHints($Gate, [string]$Unit) {
  $create = @(); $modify = @(); $held = @(); $ack = $false; $other = @(); $lines = @()
  foreach ($d in @(Get-Prop $Gate 'decisions')) {
    if ($null -eq $d) { continue }
    $v = [string](Get-Prop $d 'verdict')
    if ($v -ne 'fail' -and $v -ne 'review') { continue }
    $id = [string](Get-Prop $d 'resourceId'); $ct = [string](Get-Prop $d 'changeType')
    $notes = @(@(Get-Prop $d 'notes') | ForEach-Object { [string]$_ })
    if (@($notes | Where-Object { $_ -like 'outside the unit scope*' -or $_ -like 'change type * is never allowed' -or $_ -like 'Key Vault access policy delta*' }).Count -gt 0) { $other += $id; $lines += "- $id ($ct) stops the gate, and no option accepts it." }
    elseif (@($notes | Where-Object { $_ -like 'held:*' }).Count -gt 0) { $held += $id; $lines += "- $id is held. The option allowHeld lifts the hold for one run." }
    elseif ($v -eq 'fail' -and $ct -eq 'Create') { $create += $id; $lines += "- $id would be created. The option allowCreate accepts a new resource." }
    elseif ($v -eq 'fail' -and $ct -eq 'Modify') { $modify += $id; $lines += "- $id would change. The option allowModify accepts the change the plan shows." }
    elseif ($v -eq 'review') { $ack = $true; $lines += "- $id needs a person to read it. The option acknowledgeReview accepts the review items after that." }
    else { $other += $id; $lines += "- $id ($ct) stops the gate, and no option accepts it." }
  }
  $cmd = "gh workflow run mirror-deploy-unit --ref master -f unit=$Unit -f changeRef=<ticket> -f reason=""<why>"" -f apply=true"
  if ($ack) { $cmd += ' -f acknowledgeReview=true' }
  if ($create.Count -gt 0) { $cmd += " -f allowCreate=$($create -join ',')" }
  if ($modify.Count -gt 0) { $cmd += " -f allowModify=$($modify -join ',')" }
  if ($held.Count -gt 0) { $cmd += " -f allowHeld=$($held -join ',')" }
  return [pscustomobject]@{ lines = [string[]]$lines; command = $cmd; accepted = ($other.Count -eq 0 -and $lines.Count -gt 0) }
}

# The markdown of one plan, for the job summary: who and what at the top, then the verdict and the records.
function Format-PlanMarkdown($Plan, $Verdict) {
  $o = $Plan.options
  $opts = @()
  if ($o.acknowledgeReview) { $opts += 'acknowledgeReview' }
  foreach ($k in @('allowCreate', 'allowModify', 'allowHeld')) { if (@($o.$k).Count -gt 0) { $opts += "$k ($(@($o.$k).Count))" } }
  $lines = @("## Plan for $($Plan.unit)", '',
    "- Scope: $($Plan.scope), tier $($Plan.tier), environment $($Plan.environment)",
    "- Commit: $($Plan.commit), the tip of master when this run started",
    "- Started by: $($Plan.startedBy), $($Plan.trigger)",
    "- Change ticket: $($Plan.changeRef)",
    "- Reason: $(ConvertTo-CodeSpan $Plan.reason)",
    "- Options in force: $(if ($opts.Count -gt 0) { $opts -join ', ' } else { 'none' })")
  foreach ($k in @('allowCreate', 'allowModify', 'allowHeld')) { foreach ($id in @($o.$k)) { $lines += "  - ${k}: $id" } }
  $lines += @('', (Format-VerdictMarkdown $Verdict))
  return ($lines -join "`n")
}

# Bicep text with its comments (// and /* */) turned into spaces. Line breaks stay, so a position still has its
# line number. Strings stay, with the expressions inside ${...}, and a multi-line string ('''...''') stays as it
# is. A multi-line string ends at the first three quotes and takes any quotes right after them, as Bicep reads it,
# so '''x'''' is the text x'. Comments are read the way Bicep reads them, so a comment marker inside a string is text, and code after a
# block comment on the same line is code. BlankCommentsAndMultiLineStrings also turns the inside of each
# multi-line string into spaces, for a search that must find only statements, such as the using line of a
# .bicepparam file. The input check keeps multi-line strings, because it refuses one where a path is expected.
if (-not ('MirrorPipeline.BicepText' -as [type])) {
  Add-Type -Language CSharp -TypeDefinition @'
namespace MirrorPipeline {
  public static class BicepText {
    public static string BlankComments(string t) { return Blank(t, false); }
    public static string BlankCommentsAndMultiLineStrings(string t) { return Blank(t, true); }
    static string Blank(string t, bool blankMultiLine) {
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
            if (!blankMultiLine) { sb.Append(t, i, stop - i); i = stop; continue; }
            for (; i < stop; i++) { char d = t[i]; sb.Append(d == '\n' || d == '\r' ? d : ' '); }
            continue;
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

# The units a code change touches. Returns the units to preview (at most $script:MaxPreviewUnits) and
# notes for the pull request comment. A change to a file
# that judges every unit (bicepconfig.json in any folder, deploy/boundaries.json, scripts/deploy-unit.ps1)
# previews nothing, because such a change needs a sweep. Bicep reads the bicepconfig.json nearest to each file, so
# one in a subfolder judges every file below it.
function Resolve-AffectedUnits([string[]]$ChangedPaths, $UnitsDoc, $UnitFiles, [string[]]$ChangedUnitEntries = @(), [switch]$AfterMerge) {
  $preview = New-Object System.Collections.Generic.List[string]
  $notes = New-Object System.Collections.Generic.List[string]
  $sweep = $false
  $hits = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($p in @($ChangedPaths)) {
    if (-not $p) { continue }
    $lp = $p.Replace('\', '/').ToLowerInvariant()
    if ($script:GlobalFiles -contains $lp -or $lp.EndsWith('/bicepconfig.json')) {
      $sweep = $true
      if ($AfterMerge) { $notes.Add("$p changed. It judges every unit, so no unit was planned for it. Start Run workflow for each unit that must be checked.") }
      else { $notes.Add("$p changed. It judges every unit, so no single preview covers it. Run a read-only sweep of the enabled units before this is merged.") }
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
    $why = Get-UnrunnableReason $u
    if ($why) { $notes.Add("$n cannot be previewed or deployed in the pipeline: $why."); continue }
    if ($null -ne (Get-Prop $u 'parameterOverrides')) { $notes.Add("$n has parameterOverrides and is not previewed here."); continue }
    $preview.Add($n)
  }
  if ($sweep -and $preview.Count -gt 0) { $preview.Clear() }
  if ($preview.Count -gt $script:MaxPreviewUnits) {
    if ($AfterMerge) { $notes.Add("$($preview.Count) units are affected, more than the $($script:MaxPreviewUnits) a push plans. Start Run workflow for each unit instead.") }
    else { $notes.Add("$($preview.Count) units are affected, more than the $($script:MaxPreviewUnits) a pull request previews. Run a read-only sweep instead.") }
    $preview.Clear()
  }
  return [pscustomobject]@{ preview = [string[]]$preview.ToArray(); notes = [string[]]$notes.ToArray(); sweep = $sweep }
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

# The what-if a code pull request takes for one unit, with the same scope and file arguments deploy-unit.ps1
# uses, at the validation level a reader identity can run.
function Get-WhatIfArguments($UnitDef, $UnitsDoc, [string]$Root) {
  $name = ('whatif-{0}-{1}' -f $UnitDef.name, [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -replace '[^A-Za-z0-9._()-]', '-'
  if ($name.Length -gt 64) { $name = $name.Substring(0, 64) }
  $loc = [string](Get-Prop $UnitsDoc 'deploymentLocation')
  if ([string]$UnitDef.kind -eq 'tenant') { $a = @('deployment', 'mg', 'what-if', '--management-group-id', [string](Get-Prop $UnitDef 'managementGroup'), '--location', $loc) }
  else {
    $subId = [string](Get-Prop (Get-Prop $UnitsDoc 'subscriptions') ([string]$UnitDef.subscription))
    if ([string]$UnitDef.kind -eq 'resourceGroup') { $a = @('deployment', 'group', 'what-if', '--subscription', $subId, '--resource-group', [string]$UnitDef.resourceGroup) }
    else { $a = @('deployment', 'sub', 'what-if', '--subscription', $subId, '--location', $loc) }
  }
  $a += @('--name', $name)
  $prm = Get-Prop $UnitDef 'parameters'
  if ($prm) { $a += @('--parameters', (Join-RepoPath $Root ([string]$prm))) }
  else { $a += @('--template-file', (Join-RepoPath $Root ([string]$UnitDef.template))) }
  $a += @('--result-format', 'FullResourcePayloads', '--validation-level', 'ProviderNoRbac', '--no-pretty-print', '-o', 'json')
  return $a
}

# The Microsoft.Authorization resources a compiled template writes: role assignments, role definitions, policy
# definitions, assignments and exemptions, and locks. Nested deployments (Bicep modules) are searched too. An
# existing reference writes nothing and is left out. A resource behind a condition counts, because the condition
# can be switched on. Returns one line per resource.
function Find-AuthorizationResources($Template, [string]$Path = '') {
  return @(Find-TemplateResources $Template @('Microsoft.Authorization/*') $Path)
}

# The privileged authorization a compiled template writes: a role definition, and a role assignment of Owner, User
# Access Administrator or Role Based Access Control Administrator. A role assignment whose role the compiled
# template does not show as a GUID (a parameter, say) counts too, because the check cannot tell which role it is.
# Policy, exemptions, locks and the other role assignments pass. Returns one line per resource.
function Find-PrivilegedAuthorization($Template, [string]$Path = '') {
  $describe = {
    param($Resource)
    $type = [string](Get-Prop $Resource 'type')
    if ($type -ieq 'Microsoft.Authorization/roleDefinitions') { return 'a role definition' }
    $rid = Get-Prop (Get-Prop $Resource 'properties') 'roleDefinitionId'
    if (-not ($rid -is [string])) { return 'the role cannot be read from the compiled template' }
    $ids = @([regex]::Matches($rid, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}') | ForEach-Object { $_.Value.ToLowerInvariant() })
    if ($ids.Count -eq 0) { return 'the role cannot be read from the compiled template' }
    foreach ($id in $ids) { if ($script:PrivilegedRoleIds -contains $id) { return "the role $id is Owner, User Access Administrator or Role Based Access Control Administrator" } }
    return ''
  }
  return @(Find-TemplateResources $Template @('Microsoft.Authorization/roleDefinitions', 'Microsoft.Authorization/roleAssignments') $Path $describe)
}

# The data-access grants a compiled template writes ($script:DataGrantTypes), found the same way.
function Find-DataAccessGrants($Template, [string]$Path = '') {
  return @(Find-TemplateResources $Template $script:DataGrantTypes $Path)
}

# The resources of a compiled template whose type matches one of $Types (wildcards allowed), as
# "<module > ><type> (<symbolic name or name>)". With $Describe, a block that takes the resource and returns the
# reason it counts, or an empty string when it does not, only those resources are returned, each with its reason.
function Find-TemplateResources($Template, [string[]]$Types, [string]$Path = '', [scriptblock]$Describe = $null) {
  $hits = @()
  # The property is read here and not through Get-Prop, because a function hands back a list of one as the item
  # itself, and a template with one resource would then look like a template keyed by symbolic name.
  $res = $null
  if ($Template -is [System.Collections.IDictionary]) { if ($Template.Contains('resources')) { $res = $Template['resources'] } }
  elseif ($null -ne $Template) { $rp = $Template.PSObject.Properties['resources']; if ($null -ne $rp) { $res = $rp.Value } }
  if ($null -eq $res) { return $hits }
  # A template in language version 2.0 keys its resources by symbolic name, an older one lists them.
  $items = @()
  if ($res -is [System.Collections.IList]) { $items = @($res | ForEach-Object { [pscustomobject]@{ key = ''; value = $_ } }) }
  elseif ($res -is [System.Collections.IDictionary]) { $items = @($res.Keys | ForEach-Object { [pscustomobject]@{ key = [string]$_; value = $res[$_] } }) }
  else { $items = @($res.PSObject.Properties | ForEach-Object { [pscustomobject]@{ key = $_.Name; value = $_.Value } }) }
  foreach ($i in $items) {
    $r = $i.value
    if ($null -eq $r -or $r -is [string] -or $r -is [ValueType]) { continue }
    if ([bool](Get-Prop $r 'existing')) { continue }
    $type = [string](Get-Prop $r 'type')
    $label = if ($i.key) { $i.key } else { [string](Get-Prop $r 'name') }
    if ($label.Length -gt 100) { $label = $label.Substring(0, 100) + '...' }
    if (@($Types | Where-Object { $type -like $_ }).Count -gt 0) {
      # With a describing block, only a resource it gives a reason for is a hit.
      if ($null -eq $Describe) { $hits += "$Path$type ($label)" }
      else {
        $why = [string](& $Describe $r)
        if ($why) { $hits += "$Path$type ($label): $why" }
      }
    }
    if ($null -ne (Get-Prop $r 'resources')) { $hits += @(Find-TemplateResources $r $Types $Path $Describe) }
    if ($type -ieq 'Microsoft.Resources/deployments') {
      $inner = Get-Prop (Get-Prop $r 'properties') 'template'
      if ($null -ne $inner) { $hits += @(Find-TemplateResources $inner $Types "$Path$label > " $Describe) }
    }
  }
  return $hits
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
    if (-not $deployWorkflow -and $body -match '(?m)^\s*environment:\s*(\$\{\{|\{[^}]*\$\{\{)|(?m)^\s*environment:\s*\n\s+name:\s*[''"]?\$\{\{') {
      $errors += "${name}: builds an environment name from an expression, and only mirror-deploy-unit.yml may"
    }
    foreach ($t in @('pull_request_target', 'workflow_run', 'repository_dispatch')) {
      if ([regex]::IsMatch($body, "(?<![A-Za-z0-9_-])$t(?![A-Za-z0-9_-])")) { $errors += "${name}: uses the $t trigger, which runs with the master branch's rights" }
    }
    if ($body -match '(?<![A-Za-z0-9_])pull_request(?![A-Za-z0-9_])' -and $body -match '(?<![A-Za-z0-9_-])closed(?![A-Za-z0-9_-])' -and $body -match 'id-token:\s*write') {
      $errors += "${name}: requests id-token: write in a workflow that runs when a pull request is closed"
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
    # The first step of every job is the runner check. It stops the job unless the runner is GitHub-hosted, x64 and
    # one of the two images, so a runner label set elsewhere or a changed image never runs the job's other steps.
    $jobsAt = [regex]::Match($body, '(?m)^jobs:[ \t]*$')
    if ($jobsAt.Success) {
      $jobText = $body.Substring($jobsAt.Index + $jobsAt.Length)
      $heads = @([regex]::Matches($jobText, '(?m)^  (?<job>[A-Za-z_][A-Za-z0-9_-]*):[ \t]*$'))
      for ($k = 0; $k -lt $heads.Count; $k++) {
        $to = if ($k + 1 -lt $heads.Count) { $heads[$k + 1].Index } else { $jobText.Length }
        $job = $jobText.Substring($heads[$k].Index, $to - $heads[$k].Index)
        $first = [regex]::Match($job, '(?m)^[ \t]*steps:[ \t]*\n[ \t]*-[ \t]+(?<first>[^\n]*)')
        $firstText = if ($first.Success) { $first.Groups['first'].Value.Trim() } else { '' }
        if (-not (Test-Same $firstText "name: $($script:RunnerCheckStep)") -or $job -cnotmatch 'RUNNER_ENVIRONMENT' -or $job -cnotmatch 'RUNNER_ARCH' -or $job -cnotmatch 'ImageOS') {
          $errors += "${name}: the first step of the job $($heads[$k].Groups['job'].Value) is not the runner check (- name: $($script:RunnerCheckStep), which reads RUNNER_ENVIRONMENT, RUNNER_ARCH and ImageOS)"
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
      # The deploy workflow starts on a push to master and by hand (Run workflow). A pull request, a schedule or a
      # push to another branch never starts it.
      if ($body -match '(?<![A-Za-z0-9_-])(schedule|pull_request)(?![A-Za-z0-9_-])') {
        $errors += "${name}: the deploy workflow runs only on a push to master and by Run workflow, so it has no schedule or pull_request trigger"
      }
      if ($body -notmatch '(?ms)^on:[ \t]*\n[ \t]+push:[ \t]*\n[ \t]+branches:[ \t]*\[[ \t]*master[ \t]*\]' -or $body -notmatch '(?m)^[ \t]+workflow_dispatch:') {
        $errors += "${name}: the deploy workflow must start on push with branches [ master ] and on workflow_dispatch, and on nothing else"
      }
      # The apply and the apply-privileged jobs are the only jobs in a production or a privileged environment. They
      # wait for the plan jobs through the collect job, and the environment is built from the matrix value the
      # collect job wrote and nothing else.
      if ($jobsAt.Success) {
        foreach ($k in 0..($heads.Count - 1)) {
          $to = if ($k + 1 -lt $heads.Count) { $heads[$k + 1].Index } else { $jobText.Length }
          $job = $jobText.Substring($heads[$k].Index, $to - $heads[$k].Index)
          $jn = $heads[$k].Groups['job'].Value
          if ($jn -ceq 'apply') {
            if ($job -notmatch '(?m)^    environment:[ \t]*mirror-production-\$\{\{ matrix\.scope \}\}[ \t]*$') { $errors += "${name}: the apply job must have environment: mirror-production-`${{ matrix.scope }} and no other environment" }
            if ($job -notmatch '(?m)^    needs:.*collect') { $errors += "${name}: the apply job must need the collect job" }
          } elseif ($jn -ceq 'apply-privileged') {
            if ($job -notmatch '(?m)^    environment:[ \t]*mirror-privileged-\$\{\{ matrix\.scope \}\}[ \t]*$') { $errors += "${name}: the apply-privileged job must have environment: mirror-privileged-`${{ matrix.scope }} and no other environment" }
            if ($job -notmatch '(?m)^    needs:.*collect') { $errors += "${name}: the apply-privileged job must need the collect job" }
          } elseif ($job -match 'mirror-(production|privileged)-') { $errors += "${name}: the job $jn names a mirror-production or mirror-privileged environment, and only the apply and apply-privileged jobs may" }
        }
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
      if ($ref.StartsWith('./')) { $errors += "${name}: uses the local action $ref, and the workflows use none"; continue }
      $mm = [regex]::Match($ref, '^(?<action>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(?:/[^@]*)?@(?<sha>[^@]+)$')
      if (-not $mm.Success -or $mm.Groups['sha'].Value -cnotmatch '^[0-9a-f]{40}$') { $errors += "${name}: $ref is not pinned to a full commit SHA"; continue }
      if ($script:AllowedActions -notcontains $mm.Groups['action'].Value.ToLowerInvariant()) { $errors += "${name}: $($mm.Groups['action'].Value) is not one of the allowed actions ($($script:AllowedActions -join ', '))" }
    }
  }
  return $errors
}

# The verdict of one dry run, for the job summary and the pull request comment.
function New-Verdict([string]$Unit, [string]$PreviewMode, [int]$Exit, [string]$EvidenceDir) {
  $v = [ordered]@{ unit = $Unit; mode = $PreviewMode; exit = $Exit; gate = 'none'; approvable = $null; technical = $false; counts = ''; reasons = @(); summary = @() }
  $sum = $null; $gate = $null
  if ($EvidenceDir -and (Test-Path -LiteralPath $EvidenceDir)) {
    $sum = @(Get-ChildItem -LiteralPath $EvidenceDir -Recurse -Filter 'pre-summary.txt' -File | Sort-Object LastWriteTime | Select-Object -Last 1)
    $g = @(Get-ChildItem -LiteralPath $EvidenceDir -Recurse -Filter 'pre-gate.json' -File | Sort-Object LastWriteTime | Select-Object -Last 1)
    if ($g.Count -eq 1) { $gate = ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText($g[0].FullName)) }
    if ($sum.Count -eq 1) {
      $lines = [IO.File]::ReadAllLines($sum[0].FullName)
      $h = Read-DryRunHeader $lines
      $v.gate = [string]$h.fields['Gate']
      $v.counts = [string]$h.fields['Counts']
      $v.summary = $lines
    } else {
      $stop = @(Get-ChildItem -LiteralPath $EvidenceDir -Recurse -Filter 'stop.txt' -File | Select-Object -Last 1)
      if ($stop.Count -eq 1) { $v.summary = [IO.File]::ReadAllLines($stop[0].FullName) }
    }
  }
  if ($null -eq $gate -or ($Exit -ne 0 -and $Exit -ne 1)) {
    $v.technical = $true
    $v.reasons = @("no gate result (exit $Exit). The preview could not run, so read the job log")
  } elseif ($PreviewMode -eq 'plan') {
    $t = Test-Approvable $gate
    $v.approvable = [bool]$t.ok
    $v.reasons = @($t.reasons)
  }
  return [pscustomobject]$v
}

function Format-VerdictMarkdown($Verdict) {
  $lines = @("### $($Verdict.unit) ($($Verdict.mode))", '')
  if ($Verdict.technical) { $lines += "**Could not preview.** $(@($Verdict.reasons) -join '; ')" }
  elseif ($Verdict.mode -eq 'plan') {
    if ($Verdict.approvable) { $lines += "Gate **$($Verdict.gate)**, approvable. Counts: $($Verdict.counts)" }
    else { $lines += "Gate **$($Verdict.gate)**, **not approvable**: $(@($Verdict.reasons) -join '; ')" }
  } else {
    $lines += "Gate **$($Verdict.gate)** (for information, a deliberate change shows as FAIL until a deployment names it in allowModify). Counts: $($Verdict.counts)"
  }
  $body = @($Verdict.summary) -join "`n"
  if ($body) {
    if ($body.Length -gt $script:MaxSummaryChars) { $body = $body.Substring(0, $script:MaxSummaryChars) + "`n... (cut, the whole summary is in the run's artifact)" }
    $lines += @('', '```text', $body, '```')
  }
  return ($lines -join "`n")
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
  if ($errors.Count -gt 0) { Stop-WithErrors 'Workflow rules broken' $errors }
  Write-Summary @("Workflow rules: $($files.Count) workflow file(s) checked, all pass.")
}

# The Bicep CLI. In the preflight job the checked binary is first on PATH. On a workstation it is the copy the
# Azure CLI installed (bin/bicep.exe on Windows, bin/bicep on Linux, in the Azure CLI folder).
function Get-BicepExe {
  $first = Get-Command bicep -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($first) { return $first.Source }
  $cfg = if ($env:AZURE_CONFIG_DIR) { $env:AZURE_CONFIG_DIR } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.azure' }
  $own = Join-Path (Join-Path $cfg 'bin') $(if ($script:Sep -eq '\') { 'bicep.exe' } else { 'bicep' })
  if (Test-Path -LiteralPath $own -PathType Leaf) { return $own }
  Stop-Check 'no Bicep CLI found (bicep on PATH, or the copy in the bin folder of the Azure CLI folder)' 2
}

# The template a .bicepparam file names in its using line, as a full path, or '' when it has none. Azure deploys
# that template when the unit is given with --parameters only, which is how deploy-unit.ps1 and the preview run it.
# The file is read as Bicep reads it, so a using line inside a comment or a multi-line string is not taken, as in
# preflight-validate.ps1.
function Get-BicepparamUsing([string]$FullPath) {
  if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) { return '' }
  $m = [regex]::Match([MirrorPipeline.BicepText]::BlankCommentsAndMultiLineStrings([IO.File]::ReadAllText($FullPath)), "(?m)^[ \t]*using\s+'([^'\\]+)'")
  if (-not $m.Success) { return '' }
  try { return [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $FullPath) (ConvertTo-NativePath $m.Groups[1].Value))) } catch { return '' }
}

# Every unit (enabled or not) is compiled as Azure receives it, through its parameters file when it has one (bicep
# build-params, whose template is the one the using line names, and that must be the unit's template in
# deploy/units.json), else through its template. A production unit may declare no role definition and no role
# assignment of Owner, User Access Administrator or Role Based Access Control Administrator, and none whose role the
# compiled template does not show. A production deploy identity holds a role-assignment right limited by a condition
# that excludes those three roles, so such a record would fail in the middle of a deployment, and an identity that
# could write them could raise its own rights. Those records sit in the privileged unit of the subscription.
# Policy, exemptions, locks and the other role assignments are allowed in both tiers.
# Contributor can grant access to data through a resource's own settings, so a data-access grant of the types in
# $script:DataGrantTypes must be one of $script:KnownDataGrants.
function Invoke-PipelineScopeMode {
  $root = $script:RepoRoot
  $units = Read-JsonFile (Join-RepoPath $root 'deploy/units.json')
  $bicep = Get-BicepExe
  $errors = @(); $checked = 0; $grants = 0; $production = 0; $privileged = 0
  foreach ($u in @(Get-Prop $units 'units')) {
    $name = [string](Get-Prop $u 'name')
    $tier = Get-UnitTier $u
    if ($null -eq $tier) { $errors += "${name}: the tier '$(Get-Prop $u 'tier')' is neither absent (production) nor privileged"; continue }
    if ($tier -ceq 'privileged') { $privileged++ } else { $production++ }
    $tpl = [string](Get-Prop $u 'template'); $prm = [string](Get-Prop $u 'parameters')
    $full = Join-RepoPath $root $tpl
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $errors += "${name}: the template $tpl is not in the repository"; continue }
    $doc = $null
    if ($prm -match '\.bicepparam$') {
      $pfull = Join-RepoPath $root $prm
      if (-not (Test-Path -LiteralPath $pfull -PathType Leaf)) { $errors += "${name}: the parameters file $prm is not in the repository"; continue }
      $usingPath = Get-BicepparamUsing $pfull
      if (-not [string]::Equals($usingPath, [IO.Path]::GetFullPath($full), $script:PathCompare)) {
        $named = if ($usingPath) { ConvertTo-RepoPath $usingPath $root } else { 'no template' }
        $errors += "${name}: $prm names $named in its using line, but the unit's template in deploy/units.json is $tpl"; continue
      }
      $r = Invoke-Native $bicep @('build-params', $pfull, '--stdout') -AllowFailure
      if ($r.Code -ne 0) { $errors += "${name}: bicep build-params of $prm failed (exit $($r.Code)). $(ConvertTo-OneLine $r.Err)"; continue }
      try { $doc = ConvertFrom-Json @MirrorJsonArgs -InputObject ([string](Get-Prop (ConvertFrom-Json @MirrorJsonArgs -InputObject ($r.Out -join "`n")) 'templateJson')) }
      catch { $errors += "${name}: the template compiled through $prm is not valid JSON. $($_.Exception.Message)"; continue }
    } else {
      $r = Invoke-Native $bicep @('build', $full, '--stdout') -AllowFailure
      if ($r.Code -ne 0) { $errors += "${name}: bicep build of $tpl failed (exit $($r.Code)). $(ConvertTo-OneLine $r.Err)"; continue }
      try { $doc = ConvertFrom-Json @MirrorJsonArgs -InputObject ($r.Out -join "`n") } catch { $errors += "${name}: the compiled $tpl is not valid JSON. $($_.Exception.Message)"; continue }
    }
    if ($tier -ceq 'production') {
      foreach ($h in @(Find-PrivilegedAuthorization $doc)) {
        $errors += "$name is a production unit but declares $h. A production deploy identity cannot write it. Move the resource to the privileged unit of the subscription (a unit with ""tier"": ""privileged"" in deploy/units.json)"
      }
    }
    foreach ($h in @(Find-DataAccessGrants $doc)) {
      $grants++
      if (-not (Test-InList $script:KnownDataGrants "$name|$h")) {
        $errors += "$name is a unit and declares the data-access grant $h, which is not in the list of known grants in .github/scripts/mirror-pipeline.ps1. Contributor can write it, so a new one is an access change. Add it to the list after IT reviews it"
      }
    }
    $checked++
    Write-Host "$name ($(if ($prm -match '\.bicepparam$') { $prm } else { $tpl })) compiled"
  }
  if ($errors.Count -gt 0) { Stop-WithErrors 'A unit declares privileged authorization in the production tier, or a new data-access grant' $errors }
  Write-Summary @("Units: $checked compiled. $production production units declare no role definition and no Owner, User Access Administrator or Role Based Access Control Administrator assignment, $privileged privileged units. $grants data-access grant(s), each in the list of known grants.")
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
# the same case, as deploy-unit.ps1 matches it. The picked units are UNIT or every enabled unit, with the units
# their measuredWith lists, because the drift check previews those too. A refusal writes a verdict when
# -EvidenceRoot is given, so the pull request comment says why the unit was not previewed.
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
    if ($EvidenceRoot -and $unit) {
      New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
      $v = New-Verdict $unit (Get-EnvValue 'PREVIEW_MODE' 'by hand') 2 ''
      $v.reasons = @("not previewed with the reader identity, because Bicep from a branch may not read environment variables, registry modules or files outside the repository, nor use a form the input check does not read: $($findings -join ' | ')")
      [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'verdict.json'), (ConvertTo-Json -InputObject $v -Depth 6), $script:Utf8NoBom)
      [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'verdict.md'), (Format-VerdictMarkdown $v), $script:Utf8NoBom)
    }
    Stop-WithErrors 'Bicep from a branch uses inputs that are not run with the reader identity' $findings 2
  }
  Write-Host "Bicep inputs checked: $($bicepFiles.Count) Bicep file(s) in the checkout, $($pick.Count) unit(s). None reads an environment variable, a registry module or a file outside the repository."
}


function Invoke-PlanMode {
  $head = Get-EnvValue 'HEAD_SHA'; $merge = Get-EnvValue 'MERGE_SHA'
  # The workflow runs only for pull requests into master. This repeats it in case the trigger is ever widened.
  $baseRef = Get-EnvValue 'BASE_REF'
  if ($baseRef -cne 'master') { Stop-Check "this pull request goes into '$baseRef', and the pipeline previews only pull requests into master" }
  # The commit of master this run compares with is the first parent of GitHub's test merge commit of the run (the
  # merge of the branch into master's tip). The base commit in the pull request event can be older than master's tip
  # after the branch is updated, so it is not used.
  $x = ((Invoke-Git @('rev-parse', '--verify', "$merge^1") -AllowFailure).Out -join '').Trim()
  if ($x -cnotmatch '^[0-9a-f]{40}$') { $x = '' }
  # The preview comes only from a branch of this repository, never from a fork. A fork would run its own Bicep with
  # the reader identity's token.
  $repo = Get-EnvValue 'GITHUB_REPOSITORY'; $headRepo = Get-EnvValue 'HEAD_REPO'
  if (-not $headRepo -or $headRepo -cne $repo) { Stop-Check "the pull request comes from the repository '$headRepo', and the pipeline previews only a branch of $repo" }
  # The branch must be built on master's tip, so the preview and the merge see the same code. When master moves,
  # the branch is updated and this workflow runs again on the new tip.
  if (-not $x -or -not (Test-GitCommit $x)) { Stop-Check "this run's merge commit '$merge' has no first parent in the checkout, so the commit of master to preview is not known" 2 }
  $tip = ((Invoke-Git @('rev-parse', '--verify', 'refs/remotes/origin/master') -AllowFailure).Out -join '').Trim()
  if ($tip -cnotmatch '^[0-9a-f]{40}$') { Stop-Check 'the checkout has no copy of master (refs/remotes/origin/master), so master''s tip is not known' 2 }
  if ($x -cne $tip) { Stop-Check "master's tip ($tip) is not the base of this run's merge commit ($x). Update the branch with master (Update branch on the pull request), and this workflow takes the preview again" }
  if (-not (Test-GitAncestor $x $head)) { Stop-Check "the branch is behind master and does not contain master's commit $x. Update the branch with master (Update branch on the pull request), and this workflow takes the preview again" }
  $entries = @(Get-GitChanges $x $head -ThreeDot)

  # A code pull request previews the units it touches, for information.
  $root = $script:RepoRoot
  $units = Read-JsonFile (Join-RepoPath $root 'deploy/units.json')
  $baseUnitsText = Get-GitText $x 'deploy/units.json'
  $changedEntries = @()
  if ($baseUnitsText) { $changedEntries = @(Get-ChangedUnitEntries (Read-JsonText $baseUnitsText 'deploy/units.json at the base') $units) }
  $res = Resolve-AffectedUnits @($entries | ForEach-Object { $_.Path }) $units (Get-UnitFiles $units $root) $changedEntries
  $rows = @()
  foreach ($n in $res.preview) {
    $u = Find-UnitDef $units $n
    $rows += [ordered]@{ unit = $n; subscription = [string]$u.subscription; ref = $merge; mode = 'code' }
  }
  $kind = if ($rows.Count -gt 0) { 'code' } else { 'none' }
  Set-StepOutput 'kind' $kind
  Set-StepOutput 'matrix' $(if ($rows.Count -gt 0) { ConvertTo-CompactJson @($rows) } else { '[]' })
  Set-StepOutput 'notes' (ConvertTo-CompactJson @($res.notes))
  Write-Summary (@("Code pull request: $($entries.Count) changed file(s), $($rows.Count) unit(s) to preview.") + @($res.notes | ForEach-Object { "- $_" }))
}

function Invoke-GateScript([hashtable]$GateArgs, [string]$Unit) {
  # Out-Host keeps anything the script writes out of this function's return value. The exit code still arrives.
  & (Join-RepoPath $script:RepoRoot 'scripts/deploy-unit.ps1') -Unit $Unit @GateArgs | Out-Host
  return $LASTEXITCODE
}

function Invoke-PreviewMode {
  $unit = Get-EnvValue 'UNIT'; $previewMode = Get-EnvValue 'PREVIEW_MODE'
  if (-not $EvidenceRoot) { Stop-Check '-EvidenceRoot is required' 2 }
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  $gateRoot = Join-Path $EvidenceRoot 'gate'
  if ($previewMode -eq 'code') {
    $units = Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/units.json')
    $u = Find-UnitDef $units $unit
    if ($null -eq $u) { Stop-Check "unit $unit is not in deploy/units.json" 2 }
    $wiFile = Join-Path $EvidenceRoot "whatif-$unit.json"
    $r = Invoke-Native 'az' (Get-WhatIfArguments $u $units $script:RepoRoot) -AllowFailure
    if ($r.Code -ne 0 -or -not ($r.Out -join '').Trim()) {
      [IO.File]::WriteAllText((Join-Path $EvidenceRoot "whatif-$unit.err"), $r.Err, $script:Utf8NoBom)
      $exit = 2
    } else {
      [IO.File]::WriteAllText($wiFile, ($r.Out -join "`n"), $script:Utf8NoBom)
      $exit = Invoke-GateScript @{ WhatIfJson = @($wiFile); EvidenceRoot = $gateRoot } $unit
    }
  } else { Stop-Check "unknown preview mode '$previewMode'" 2 }
  $v = New-Verdict $unit $previewMode $exit $gateRoot
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'verdict.json'), (ConvertTo-Json -InputObject $v -Depth 6), $script:Utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'verdict.md'), (Format-VerdictMarkdown $v), $script:Utf8NoBom)
  if ($v.technical) { exit 2 }
  exit 0
}

# Creates or edits the one comment this workflow keeps on the pull request.
function Set-PullRequestComment([string]$Pr, [string]$Body) {
  $repo = Get-EnvValue 'GITHUB_REPOSITORY'
  $file = Join-Path ([IO.Path]::GetTempPath()) ("mirror-comment-{0}.md" -f [guid]::NewGuid().ToString('N'))
  [IO.File]::WriteAllText($file, $Body, $script:Utf8NoBom)
  try {
    # Only a comment the workflow's own token wrote is edited. A person's comment that starts with the marker is
    # left alone.
    $existing = @(Invoke-GhApi "repos/$repo/issues/$Pr/comments?per_page=100" -Paginate | Where-Object {
        ([string](Get-Prop $_ 'body')).StartsWith($script:CommentMarker) -and
        [string](Get-Prop (Get-Prop $_ 'user') 'login') -ceq $script:BotLogin -and [string](Get-Prop (Get-Prop $_ 'user') 'type') -ceq 'Bot' })
    if ($existing.Count -gt 0) { $r = Invoke-Native 'gh' @('api', '-X', 'PATCH', "repos/$repo/issues/comments/$($existing[0].id)", '-F', "body=@$file") -AllowFailure }
    else { $r = Invoke-Native 'gh' @('api', "repos/$repo/issues/$Pr/comments", '-F', "body=@$file") -AllowFailure }
    if ($r.Code -ne 0) { Write-Host "::warning::the pull request comment could not be written: $($r.Err)" }
  } catch { Write-Host "::warning::the pull request comment could not be written: $_" }
  finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
}


# Splits a list of resource IDs (commas or line breaks) into an array.
function Split-IdList([string]$Text) {
  return [string[]]@(@($Text -split '[,\r\n]+') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

# The options of a plan as the compact JSON the matrix carries to the plan job.
function ConvertTo-OptionsJson($Options) {
  return (ConvertTo-CompactJson ([ordered]@{ acknowledgeReview = [bool]$Options.acknowledgeReview; allowCreate = @($Options.allowCreate); allowModify = @($Options.allowModify); allowHeld = @($Options.allowHeld) }))
}

# The request a plan or an apply job checks, from the matrix row the plan job received.
function Read-RowRequest {
  $opts = Read-JsonText (Get-EnvValue 'OPTIONS' '{}') 'the options passed by the select job'
  return [pscustomobject]@{
    unit = Get-EnvValue 'UNIT'
    changeRef = Get-EnvValue 'CHANGE_REF'
    reason = Get-EnvValue 'REASON'
    acknowledgeReview = [bool](Get-Prop $opts 'acknowledgeReview')
    allowCreate = [string[]]@(@(Get-Prop $opts 'allowCreate') | Where-Object { $_ })
    allowModify = [string[]]@(@(Get-Prop $opts 'allowModify') | Where-Object { $_ })
    allowHeld = [string[]]@(@(Get-Prop $opts 'allowHeld') | Where-Object { $_ })
  }
}

# The tip of master, from the GitHub API.
function Get-MasterTip {
  $repo = Get-EnvValue 'GITHUB_REPOSITORY'
  return ([string](Get-Prop (Get-Prop (Invoke-GhApi "repos/$repo/branches/master") 'commit') 'sha'))
}

# Which units a run of mirror-deploy-unit plans. A push plans every enabled unit the pipeline may deploy whose files
# changed in the push. Run workflow plans the unit it names, after the checks of its inputs.
function Invoke-SelectMode {
  $evt = Get-EnvValue 'EVENT_NAME'
  $root = $script:RepoRoot
  $units = Read-JsonFile (Join-RepoPath $root 'deploy/units.json')
  $bounds = Read-JsonFile (Join-RepoPath $root 'deploy/boundaries.json')
  $actor = Get-EnvValue 'GITHUB_ACTOR' 'unknown'
  $rows = @(); $notes = @()
  if ((Get-EnvValue 'GITHUB_REF') -cne 'refs/heads/master') { Stop-Check "the run is on '$(Get-EnvValue 'GITHUB_REF')'. The deployment runs only on master" }

  if ($evt -eq 'workflow_dispatch') {
    $req = [pscustomobject]@{
      unit = Get-EnvValue 'UNIT'
      changeRef = Get-EnvValue 'CHANGE_REF'
      reason = Get-EnvValue 'REASON'
      acknowledgeReview = ((Get-EnvValue 'ACK') -eq 'true')
      allowCreate = [string[]]@(Split-IdList (Get-EnvValue 'ALLOW_CREATE'))
      allowModify = [string[]]@(Split-IdList (Get-EnvValue 'ALLOW_MODIFY'))
      allowHeld = [string[]]@(Split-IdList (Get-EnvValue 'ALLOW_HELD'))
    }
    $chk = Test-DeployRequest $req $units $bounds
    if (@($chk.errors).Count -gt 0) { Stop-WithErrors 'The inputs of this run do not pass their checks' $chk.errors }
    $rows += [ordered]@{ unit = $req.unit; subscription = [string]$chk.unitDef.subscription; scope = Get-UnitScope $chk.unitDef; tier = Get-UnitTier $chk.unitDef; trigger = 'Run workflow'
                         apply = $(if ((Get-EnvValue 'APPLY') -eq 'true') { 'true' } else { 'false' }); startedBy = $actor
                         changeRef = $req.changeRef; reason = $req.reason; options = (ConvertTo-OptionsJson (Get-DeployOptions $req)) }
  } elseif ($evt -eq 'push') {
    $before = Get-EnvValue 'BEFORE'; $after = Get-EnvValue 'AFTER'
    $from = if (-not $before -or $before -match '^0+$') { "$after^" } else { $before }
    if (-not (Test-GitCommit $from)) { Stop-Check "the commit $from is not in the checkout, so the changed files of this push are not known" 2 }
    $entries = @(Get-GitChanges $from $after)
    $paths = @($entries | ForEach-Object { $_.Path })
    $oldUnitsText = Get-GitText $from 'deploy/units.json'
    $changedEntries = @()
    if ($oldUnitsText) { $changedEntries = @(Get-ChangedUnitEntries (Read-JsonText $oldUnitsText 'deploy/units.json before the push') $units) }
    # deploy/boundaries.json is read entry by entry. A changed hold or expected Ignore pattern that names a
    # subscription plans that subscription's units. A change by resource type plans nothing.
    $scope = @()
    if ($paths -contains 'deploy/boundaries.json') {
      $oldBoundsText = Get-GitText $from 'deploy/boundaries.json'
      if ($oldBoundsText) {
        $bc = Get-BoundaryChanges (Read-JsonText $oldBoundsText 'deploy/boundaries.json before the push') $bounds
        $scope = @(Get-BoundaryScopeUnits $bc $units)
        if (@($bc.typeWide).Count -gt 0) { $notes += "deploy/boundaries.json changed for whole resource types ($(@($bc.typeWide).Count) entr$(if (@($bc.typeWide).Count -eq 1) { 'y' } else { 'ies' })), which judge every unit. No unit was planned for it. Start Run workflow for each unit that must be checked." }
      } else { $notes += 'deploy/boundaries.json is new in this push, which judges every unit. No unit was planned for it. Start Run workflow for each unit that must be checked.' }
    }
    $res = Resolve-AffectedUnits @($paths | Where-Object { $_ -ne 'deploy/boundaries.json' }) $units (Get-UnitFiles $units $root) @($changedEntries + $scope) -AfterMerge
    $notes += @($res.notes)
    $off = 0
    foreach ($n in @($res.preview)) {
      $u = Find-UnitDef $units $n
      if (Get-UnrunnableReason $u) { continue }
      if (-not [bool](Get-Prop $u 'enabled')) { $off++; continue }
      if ($null -eq (Get-UnitTier $u)) { $notes += "$n has a tier that is neither absent nor privileged, so it is not planned."; continue }
      # The client ID of the deploy identity lives in the environment of the unit's scope, not in deploy/units.json.
      # The apply job stops with a clear message when the environment has none, so the plan does not look for it.
      $rows += [ordered]@{ unit = $n; subscription = [string]$u.subscription; scope = Get-UnitScope $u; tier = Get-UnitTier $u; trigger = 'push'; apply = 'true'; startedBy = $actor
                           changeRef = ''; reason = ''; options = (ConvertTo-OptionsJson (Get-DeployOptions ([pscustomobject]@{}))) }
    }
    if ($off -gt 0) { $notes += "$off unit(s) this push touches are not enabled in deploy/units.json, so they are not planned." }
    if ($rows.Count -gt 0) {
      $ticket = ''; $why = "Push to master, commit $($after.Substring(0, [Math]::Min(12, $after.Length)))"
      try {
        $repo = Get-EnvValue 'GITHUB_REPOSITORY'
        $prs = @(Invoke-GhApi "repos/$repo/commits/$after/pulls" | Where-Object {
            (Get-Prop $_ 'merged_at') -and (Test-Same ([string](Get-Prop (Get-Prop $_ 'base') 'ref')) 'master') -and (Test-Same ([string](Get-Prop $_ 'merge_commit_sha')) $after) })
        if ($prs.Count -eq 1) {
          $title = [string](Get-Prop $prs[0] 'title')
          $ticket = Get-ChangeTicketFromText $title ([string](Get-Prop $prs[0] 'body'))
          $oneLine = (ConvertTo-OneLine $title).Trim()
          if ($oneLine.Length -gt 200) { $oneLine = $oneLine.Substring(0, 200) }
          $why = "Merged pull request #$($prs[0].number): $oneLine"
        } else { $notes += "Found $($prs.Count) merged pull request(s) for this push, so the reason names the commit and the change ticket is none." }
      } catch { $notes += "The merged pull request could not be read ($(ConvertTo-OneLine $_.Exception.Message)), so the reason names the commit and the change ticket is none." }
      if (-not $ticket) { $ticket = 'none' }
      foreach ($r in $rows) { $r.changeRef = $ticket; $r.reason = $why }
    }
  } else { Stop-Check "the event '$evt' is not one this workflow plans for" 2 }

  Set-StepOutput 'matrix' $(if ($rows.Count -gt 0) { ConvertTo-CompactJson @($rows) } else { '[]' })
  $lines = @("Units to plan: $($rows.Count).")
  foreach ($r in $rows) { $lines += "- $($r.unit), change ticket $($r.changeRef)" }
  $lines += @($notes | ForEach-Object { "- $_" })
  Write-Summary $lines
}

# The dry run and the gate of one unit with the options of its row, judged for the reviewers. Writes the reviewed
# plan: verdict.md and the job summary for the people, plan.json and the gate files for the apply.
function Invoke-DeployPlanMode {
  if (-not $EvidenceRoot) { Stop-Check '-EvidenceRoot is required' 2 }
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  $root = $script:RepoRoot
  $units = Read-JsonFile (Join-RepoPath $root 'deploy/units.json')
  $bounds = Read-JsonFile (Join-RepoPath $root 'deploy/boundaries.json')
  $req = Read-RowRequest
  $chk = Test-DeployRequest $req $units $bounds
  if (@($chk.errors).Count -gt 0) { Stop-WithErrors "The request for $($req.unit) does not pass its checks at this commit" $chk.errors }
  $sha = Get-EnvValue 'GITHUB_SHA'
  $tip = Get-MasterTip
  if ($tip -cne $sha) {
    Stop-Check "master is now at $tip and this run started at $sha. A plan belongs to one commit, so nothing is deployed from this run. The newer commit starts its own run if it touches an enabled unit. Otherwise start Run workflow on master for $($req.unit)"
  }
  $opts = Get-DeployOptions $req
  $gateRoot = Join-Path $EvidenceRoot 'gate'
  $exit = Invoke-GateScript (Get-GateArguments $opts $gateRoot '') $req.unit
  $v = New-Verdict $req.unit 'plan' $exit $gateRoot
  $gateFile = @(Get-ChildItem -LiteralPath $gateRoot -Recurse -Filter 'pre-gate.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1)
  $gate = $null
  if ($gateFile.Count -eq 1) { $gate = Read-JsonFile $gateFile[0].FullName }
  $trigger = Get-EnvValue 'TRIGGER' 'Run workflow'
  $applyAsked = ((Get-EnvValue 'APPLY') -eq 'true')
  $hasChanges = ($null -ne $gate -and (Test-HasChanges $gate))
  $approvable = (-not $v.technical -and [bool]$v.approvable)
  $offer = ($approvable -and $applyAsked -and ($trigger -ne 'push' -or $hasChanges))
  $plan = [ordered]@{
    schema = 2; unit = $req.unit; subscription = [string]$chk.unitDef.subscription; scope = Get-UnitScope $chk.unitDef; tier = Get-UnitTier $chk.unitDef
    environment = Get-UnitEnvironment $chk.unitDef; commit = $sha
    planned = [DateTimeOffset]::UtcNow.ToString('o'); trigger = $trigger; startedBy = Get-EnvValue 'STARTED_BY' 'unknown'
    changeRef = $req.changeRef; reason = $req.reason; applyRequested = $applyAsked
    options = [ordered]@{ acknowledgeReview = $opts.acknowledgeReview; allowCreate = @($opts.allowCreate); allowModify = @($opts.allowModify); allowHeld = @($opts.allowHeld) }
    gate = $v.gate; counts = $v.counts; approvable = $approvable; hasChanges = $hasChanges; offerApply = $offer
  }
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'plan.json'), (ConvertTo-Json -InputObject $plan -Depth 8), $script:Utf8NoBom)
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'verdict.json'), (ConvertTo-Json -InputObject $v -Depth 6), $script:Utf8NoBom)
  $md = Format-PlanMarkdown ([pscustomobject]$plan) $v
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'verdict.md'), $md, $script:Utf8NoBom)
  $tail = @()
  if ($v.technical) { Write-Summary @($md); exit 2 }
  if (-not $approvable) {
    $tail += @('', '**Nothing deploys from this plan.** The gate stops on the records above.')
    if ($null -ne $gate) {
      $h = Get-ExceptionHints $gate $req.unit
      if ($h.lines.Count -gt 0) { $tail += @('', 'What the options could accept:') + @($h.lines) }
      if ($h.accepted) { $tail += @('', 'To deploy it with those options, start Run workflow for the same unit. Fill in the ticket and the reason, and check each ID first.', '', '```text', $h.command, '```') }
    }
    Write-Summary (@($md) + $tail)
    exit 1
  }
  if (-not $applyAsked) { $tail += @('', 'This run was started as a plan only (apply is off). Nothing waits for a reviewer.') }
  elseif (-not $offer) { $tail += @('', 'A push publishes this plan and deploys nothing. The plan holds no effective change, so nothing waits for a reviewer. A change is applied with Run workflow, which names the ticket, the reason and the options.') }
  elseif (-not $hasChanges) { $tail += @('', 'No effective change: the plan holds no record a deployment would change. The apply job still waits for the reviewers of this unit''s environment, and a reviewer who did not start the run reads this plan, then selects Review deployments and Approve and deploy.') }
  else { $tail += @('', 'The apply job waits for the reviewers of this unit''s environment. A reviewer who did not start the run reads this plan, then selects Review deployments and Approve and deploy.') }
  Write-Summary (@($md) + $tail)
  exit 0
}

# After the plan jobs. Reads each reviewed plan and lists the units whose apply waits for a reviewer, the production
# units in applyMatrix and the privileged ones in privilegedMatrix.
function Invoke-CollectMode {
  $sha = Get-EnvValue 'GITHUB_SHA'
  $want = @(); $mt = Get-EnvValue 'MATRIX'
  if ($mt) { $tmp = ConvertFrom-Json @MirrorJsonArgs -InputObject $mt; $want = @($tmp) }
  $plans = @()
  if ($Dir -and (Test-Path -LiteralPath $Dir)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter 'plan.json' -File)) { $plans += Read-JsonFile $f.FullName }
  }
  $unitsDoc = Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/units.json')
  $apply = @(); $privileged = @(); $lines = @('## Plans of this run', '', '| Unit | Gate | Counts | What happens next |', '|---|---|---|---|')
  foreach ($w in $want) {
    $p = @($plans | Where-Object { (Test-Same ([string]$_.unit) ([string]$w.unit)) -and (Test-Same ([string]$_.commit) $sha) })
    if ($p.Count -ne 1) { $lines += "| $($w.unit) | none | none | The plan did not finish, so nothing deploys. Read the plan job. |"; continue }
    $x = $p[0]
    $def = Find-UnitDef $unitsDoc ([string]$x.unit)
    $defOk = ($null -ne $def -and $null -ne (Get-UnitTier $def) -and (Test-Same ([string]$x.scope) (Get-UnitScope $def)) -and (Test-Same ([string]$x.tier) (Get-UnitTier $def)))
    if ($x.offerApply -and -not $defOk) { $lines += "| $($x.unit) | $($x.gate) | $($x.counts) | The plan names a scope or a tier that deploy/units.json does not give this unit, so nothing deploys. |"; continue }
    $next = if ($x.offerApply) { 'Waiting for a reviewer in the apply job.' }
            elseif (-not $x.approvable) { 'Not approvable. Nothing deploys.' }
            elseif (-not $x.applyRequested) { 'Plan only.' }
            else { 'Nothing to deploy.' }
    $lines += "| $($x.unit) | $($x.gate) | $($x.counts) | $next |"
    if ($x.offerApply -and ([string]$x.unit) -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\z' -and ([string]$x.scope) -cmatch '^[a-z0-9]+(?:-[a-z0-9]+)*\z') {
      $row = [ordered]@{ unit = [string]$x.unit; scope = [string]$x.scope }
      if ((Get-UnitTier $def) -ceq 'privileged') { $privileged += $row } else { $apply += $row }
    }
  }
  Set-StepOutput 'applyMatrix' $(if ($apply.Count -gt 0) { ConvertTo-CompactJson @($apply) } else { '[]' })
  Set-StepOutput 'privilegedMatrix' $(if ($privileged.Count -gt 0) { ConvertTo-CompactJson @($privileged) } else { '[]' })
  Write-Summary $lines
}

# The one reviewed plan in a folder, with the gate files that sit beside its dry run.
function Get-ReviewedPlan([string]$Folder) {
  $pj = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter 'plan.json' -File -ErrorAction SilentlyContinue)
  $sums = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter 'pre-summary.txt' -File -ErrorAction SilentlyContinue)
  $gates = @(Get-ChildItem -LiteralPath $Folder -Recurse -Filter 'pre-gate.json' -File -ErrorAction SilentlyContinue)
  if ($pj.Count -ne 1 -or $sums.Count -ne 1 -or $gates.Count -ne 1 -or $sums[0].DirectoryName -ne $gates[0].DirectoryName) {
    Stop-Check "the reviewed plan must hold exactly one plan.json, one pre-summary.txt and one pre-gate.json (the last two in the same folder), and it holds $($pj.Count), $($sums.Count) and $($gates.Count)" 2
  }
  return [pscustomobject]@{ plan = Read-JsonFile $pj[0].FullName; summary = $sums[0].FullName; gate = $gates[0].FullName }
}

# Before the apply signs in. Nothing may have moved since the reviewer read the plan.
function Invoke-CheckApplyMode {
  if ((Get-EnvValue 'GITHUB_RUN_ATTEMPT') -ne '1') { Stop-Check 're-runs never deploy. Start the deployment again with Run workflow on master' 2 }
  $sha = Get-EnvValue 'GITHUB_SHA'; $unit = Get-EnvValue 'UNIT'; $tierWanted = Get-EnvValue 'TIER'
  if ($tierWanted -cne 'production' -and $tierWanted -cne 'privileged') { Stop-Check "the job names the tier '$tierWanted', and it must be production or privileged" 2 }
  $head = ((Invoke-Git @('rev-parse', 'HEAD')).Out -join '').Trim()
  if (-not (Test-Same $head $sha)) { Stop-Check "checked out $head, the run is at $sha" 2 }
  $dirty = ((Invoke-Git @('status', '--porcelain')).Out -join "`n").Trim()
  if ($dirty) { Stop-Check "the working tree is not clean: $dirty" 2 }
  $rp = Get-ReviewedPlan $Dir
  $plan = $rp.plan
  $errors = @()
  if (-not (Test-Same ([string]$plan.unit) $unit)) { $errors += "the reviewed plan is of unit '$($plan.unit)', this job deploys '$unit'" }
  if (-not (Test-Same ([string]$plan.commit) $sha)) { $errors += "the reviewed plan is of commit $($plan.commit), this run is at $sha" }
  if (-not [bool]$plan.offerApply) { $errors += 'the reviewed plan did not offer an apply' }
  $unitsNow = Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/units.json')
  $defNow = Find-UnitDef $unitsNow $unit
  if ($null -eq $defNow) { $errors += "unit '$unit' is not in deploy/units.json" }
  else {
    $tierNow = Get-UnitTier $defNow
    if ($null -eq $tierNow) { $errors += "unit '$unit' has a tier in deploy/units.json that is neither absent (production) nor privileged" }
    else {
      if (-not (Test-Same ([string]$plan.tier) $tierWanted)) { $errors += "the reviewed plan is of the tier '$($plan.tier)', and this job deploys the tier $tierWanted" }
      if (-not (Test-Same $tierNow $tierWanted)) { $errors += "deploy/units.json gives unit '$unit' the tier $tierNow, and this job deploys the tier $tierWanted" }
    }
    if (-not (Test-Same ([string]$plan.scope) (Get-UnitScope $defNow))) { $errors += "the reviewed plan names the scope '$($plan.scope)', and deploy/units.json gives unit '$unit' the scope '$(Get-UnitScope $defNow)'" }
  }
  if ($errors.Count -gt 0) { Stop-WithErrors 'The reviewed plan is not the one this job deploys' $errors }
  $tip = Get-MasterTip
  if ($tip -cne $sha) { Stop-Check "master moved to $tip after the plan of commit $sha was reviewed. Nothing is deployed. Start the deployment again with Run workflow on master, so a new plan is reviewed" }
  $errors += @(Test-PlanAge ([string]$plan.planned) ([DateTimeOffset]::UtcNow) (Get-MaxPlanAgeHours))
  $units = Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/units.json')
  $bounds = Read-JsonFile (Join-RepoPath $script:RepoRoot 'deploy/boundaries.json')
  $o = Get-DeployOptions $plan.options
  $req = [pscustomobject]@{ unit = $unit; changeRef = [string]$plan.changeRef; reason = [string]$plan.reason; acknowledgeReview = $o.acknowledgeReview
                            allowCreate = $o.allowCreate; allowModify = $o.allowModify; allowHeld = $o.allowHeld }
  $errors += @((Test-DeployRequest $req $units $bounds).errors)
  $errors += @(Test-PlanMatches (Read-DryRunHeader ([IO.File]::ReadAllLines($rp.summary))) $o $unit $sha)
  $t = Test-Approvable (Read-JsonFile $rp.gate)
  if (-not $t.ok) { $errors += @($t.reasons | ForEach-Object { "the reviewed plan is not approvable: $_" }) }
  if ($errors.Count -gt 0) { Stop-WithErrors 'The reviewed plan can no longer be applied' $errors }
  Write-Summary @("Reviewed plan of $unit at commit $sha checked after the approval. Master is still at that commit, the plan is recent, the unit is still enabled.")
}

# A fresh dry run with the options of the plan shows the same records as the plan, apart from the resources the
# options name.
function Invoke-ComparePlanMode {
  if (-not $EvidenceRoot) { Stop-Check '-EvidenceRoot is required' 2 }
  $unit = Get-EnvValue 'UNIT'
  $rp = Get-ReviewedPlan $Dir
  $o = Get-DeployOptions $rp.plan.options
  # Exit 1 is the expected REVIEW of a dry run with allowModify.
  $exit = Invoke-GateScript (Get-GateArguments $o $EvidenceRoot '') $unit
  if ($exit -ne 0 -and $exit -ne 1) { Stop-Check "the fresh dry run stopped with exit $exit, so nothing was deployed" 2 }
  $now = @(Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -Filter 'pre-gate.json' -File | Sort-Object LastWriteTime | Select-Object -Last 1)
  if ($now.Count -ne 1) { Stop-Check 'the fresh dry run wrote no pre-gate.json, so nothing was deployed' 2 }
  $nowGate = Read-JsonFile $now[0].FullName
  if ([string](Get-Prop $nowGate 'overall') -eq 'fail') { Stop-Check 'the gate fails now (read the compare evidence), so nothing was deployed' }
  $diff = @(Compare-PlanRecords (Read-JsonFile $rp.gate) $nowGate $o)
  if ($diff.Count -gt 0) { Stop-WithErrors 'The preview now differs from the reviewed plan. Nothing was deployed' $diff }
  Write-Summary @("Fresh preview of ${unit}: the same records as the reviewed plan ($(@(Get-PlanRecords $nowGate $o).Count) record(s) compared, the resources the options name left out).")
}

function Invoke-ReportMode {
  $kind = Get-EnvValue 'KIND' 'none'; $planResult = Get-EnvValue 'PLAN_RESULT'; $whatifResult = Get-EnvValue 'WHATIF_RESULT'
  $runUrl = "$(Get-EnvValue 'GITHUB_SERVER_URL')/$(Get-EnvValue 'GITHUB_REPOSITORY')/actions/runs/$(Get-EnvValue 'GITHUB_RUN_ID')"
  # ConvertFrom-Json hands a JSON list back as one object, so the result is assigned before @() spreads it.
  $notes = @(); $nt = Get-EnvValue 'NOTES'; if ($nt) { $tmp = ConvertFrom-Json @MirrorJsonArgs -InputObject $nt; $notes = @($tmp) }
  $rows = @(); $mt = Get-EnvValue 'MATRIX'; if ($mt) { $tmp = ConvertFrom-Json @MirrorJsonArgs -InputObject $mt; $rows = @($tmp) }
  $verdicts = @()
  if ($Dir -and (Test-Path -LiteralPath $Dir)) {
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter 'verdict.json' -File)) { $verdicts += Read-JsonFile $f.FullName }
  }
  $fail = @()
  if ($planResult -ne 'success') { $fail += 'the plan job did not pass (read the plan job log)' }
  else {
    foreach ($row in $rows) {
      $v = @($verdicts | Where-Object { Test-Same ([string]$_.unit) ([string]$row.unit) })
      if ($v.Count -eq 0) { $fail += "no verdict for $($row.unit) (the preview job $whatifResult)"; continue }
      if ($v[0].technical) { $fail += "$($row.unit) could not be previewed" }
    }
  }
  $lines = @($script:CommentMarker, '## Mirror preview', '')
  switch ($kind) {
    'code' { $lines += 'Code pull request. The previews below are for information. A change made on purpose shows as FAIL until a deployment of the unit names it in allowModify, and nothing deploys from a pull request. After the merge, a push to master plans every enabled unit whose files changed, and its apply waits for a reviewer.' }
    default { $lines += 'No unit to preview.' }
  }
  if ($fail.Count -gt 0) { $lines += @('', '**This check fails:**') + @($fail | ForEach-Object { "- $_" }) }
  if ($notes.Count -gt 0) { $lines += @('', '**Notes:**') + @($notes | ForEach-Object { "- $_" }) }
  foreach ($v in $verdicts) { $lines += @('', (Format-VerdictMarkdown $v)) }
  $lines += @('', "Run: $runUrl")
  $body = $lines -join "`n"
  if ($body.Length -gt $script:MaxSummaryChars) { $body = $body.Substring(0, $script:MaxSummaryChars) + "`n... (cut, read the run at $runUrl)" }
  Write-Summary @($body)
  $pr = Get-EnvValue 'PR'
  if ($pr -and ($kind -ne 'none' -or $notes.Count -gt 0 -or $fail.Count -gt 0)) { Set-PullRequestComment $pr $body }
  if ($fail.Count -gt 0) { Stop-WithErrors 'The mirror preview check fails' $fail }
}

function Get-ExitMeaning([string]$Code) {
  switch ($Code) {
    '0' { return 'deployed, and the second check passed' }
    '1' { return 'the gate failed, or the changes differ from the reviewed plan. Nothing was deployed' }
    '2' { return 'set-up, identity or tool error. Nothing was deployed' }
    '3' { return 'the deployment failed or the second check failed. Stop and follow the rollback steps in REFERENCE.md' }
    'error' { return 'the gate step stopped with an error before it returned an exit code. A deployment may have started, so read the step log and check the deployments of the scope before anything else' }
    'started' { return 'the gate step started but ended without an exit code (cancelled or timed out). A deployment may still be running, so check the deployments of the scope before anything else' }
    default { return 'the gate step did not run' }
  }
}

function Invoke-DeploySummaryMode {
  if (-not $EvidenceRoot) { Stop-Check '-EvidenceRoot is required' 2 }
  New-Item -ItemType Directory -Force -Path $EvidenceRoot | Out-Null
  $code = ''
  $exitFile = Get-EnvValue 'GATE_EXIT_FILE'
  if ($exitFile -and (Test-Path -LiteralPath $exitFile)) { $code = ([IO.File]::ReadAllText($exitFile)).Trim() }
  $plan = $null
  if ($Dir -and (Test-Path -LiteralPath $Dir)) {
    $pj = @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter 'plan.json' -File | Select-Object -First 1)
    if ($pj.Count -eq 1) { $plan = Read-JsonFile $pj[0].FullName }
  }
  $record = [ordered]@{
    unit = Get-EnvValue 'UNIT'
    plan = $plan
    commit = Get-EnvValue 'GITHUB_SHA'
    startedBy = Get-EnvValue 'STARTED_BY'
    workflowRun = Get-EnvValue 'GITHUB_RUN_ID'
    runAttempt = Get-EnvValue 'GITHUB_RUN_ATTEMPT'
    gateExit = $code
    gateResult = Get-ExitMeaning $code
    approval = 'Recorded in the run (Review deployments, with the reviewer and the comment) and in the audit log of the organization.'
    written = [DateTimeOffset]::UtcNow.ToString('u')
  }
  [IO.File]::WriteAllText((Join-Path $EvidenceRoot 'pipeline-deployment.json'), (ConvertTo-Json -InputObject $record -Depth 10), $script:Utf8NoBom)
  $lines = @("## Deployment of $(Get-EnvValue 'UNIT')", '')
  if ($null -ne $plan) { $lines += @("Change ticket: $($plan.changeRef). Started by $($plan.startedBy), $($plan.trigger). Commit $($plan.commit).", '') }
  $lines += @("Gate step exit: $(if ($code) { $code } else { 'none' }), $(Get-ExitMeaning $code).", '')
  foreach ($name in @('post-summary.txt', 'pre-summary.txt', 'stop.txt', 'approval.txt')) {
    $f = @(Get-ChildItem -LiteralPath $EvidenceRoot -Recurse -Filter $name -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '[\\/]compare[\\/]' } | Sort-Object LastWriteTime | Select-Object -Last 1)
    if ($f.Count -eq 0) { continue }
    $text = [IO.File]::ReadAllText($f[0].FullName)
    if ($text.Length -gt 20000) { $text = $text.Substring(0, 20000) + "`n... (cut, the whole file is in the evidence artifact)" }
    $lines += @("$name", '', '```text', $text.TrimEnd(), '```', '')
  }
  $lines += 'Download the evidence artifact and attach it to the change ticket.'
  Write-Summary $lines
}

# ---------------------------------------------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------------------------------------------
if (-not $Mode) { return }
try {
  switch ($Mode) {
    'Hygiene' { Invoke-HygieneMode }
    'PipelineScope' { Invoke-PipelineScopeMode }
    'InputCheck' { Invoke-InputCheckMode }
    'Plan' { Invoke-PlanMode }
    'Preview' { Invoke-PreviewMode }
    'Report' { Invoke-ReportMode }
    'Select' { Invoke-SelectMode }
    'DeployPlan' { Invoke-DeployPlanMode }
    'Collect' { Invoke-CollectMode }
    'CheckApply' { Invoke-CheckApplyMode }
    'ComparePlan' { Invoke-ComparePlanMode }
    'DeploySummary' { Invoke-DeploySummaryMode }
  }
} catch {
  Stop-Check "$Mode failed: $($_.Exception.Message)" 2
}
exit 0
