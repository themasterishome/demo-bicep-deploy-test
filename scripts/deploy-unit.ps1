<#
.SYNOPSIS
  Gated deployment of one unit (a resource group file or a subscription main).

.DESCRIPTION
  Every run does these checks in this order and stops at the first that fails:

    1. The unit is in deploy/units.json, under its name written with the same characters and case,
       and enabled (that file is the allowlist). A name that differs only in case is refused. An offline
       -WhatIfJson evaluation skips the enabled check, because it calls no Azure and never deploys.
    2. A deploy run has a committed tree (no uncommitted change under infra, deploy, pipelines or scripts,
       or in the bicepconfig.json at the root). A tree git cannot read counts as uncommitted.
    3. The signed-in identity and tenant are right. A person is listed in units.json (allowedPrincipals) and the
       tenant is its tenantId. A service principal is listed there too, or it is the identity of a GitHub Actions job:
       GITHUB_ACTIONS is true and its name equals the client ID in MIRROR_CLIENT_ID, which the workflow takes from
       the AZURE_CLIENT_ID variable of the job's environment.
    4. The Azure CLI runs Bicep 0.48.1 (az bicep version, recorded as Bicep: in pre-summary.txt), the
       unit's files compile, and a resource group file or subscription main declares no
       resource twice (find-duplicate-declarations.ps1). Azure would refuse such a deployment
       with ResourceDeployedMultipleTimes.
    5. A FullResourcePayloads what-if of exactly these files against the live scope. Dry runs and
       drift checks use validation level ProviderNoRbac, so a reader identity can run them. A
       deploy run keeps the default level, which also checks write permission.
    6. The gate. Every record must be NoChange, Ignore, or a Modify whose every leaf delta is
       NoEffect or listed in deploy/boundaries.json. Create is refused unless the
       resource ID is passed in -AllowCreate. A Delete or Unsupported record (a whole resource) and
       anything the gate does not recognize are always refused. What-if has no Replace result. A
       change to a property Azure cannot change in place shows as an ordinary Modify, and Azure
       rejects it only during the deployment (exit 3). Resources matching a hold in boundaries.json are
       refused unless named in -AllowHeld. Boundaries marked "review" need -AcknowledgeReview. A boundary
       without a type, a path, a list of change types and an onDeploy of exactly inert or review stops every
       run before the gate (exit 2).
       Two kinds of record that the preview itself could not judge also need -AcknowledgeReview:
       a Deploy record of a nested deployment (Microsoft.Resources/deployments), where what-if could
       not work out what the module writes and lists nothing inside it, and a Modify record that
       lists no changed property. No rule can pass either, so the gate gives them the verdict
       review. A third kind is a data-access change, a record that changes who can read or manage the
       data inside a resource. Contributor can write such a change, so it is a review record too,
       on top of the record's own verdict and whatever -AllowCreate and -AllowModify allow. A Create
       among them still needs -AllowCreate, and a Modify of a property no boundary lists still needs
       -AllowModify, as any other record does. The gate counts these records as data-access changes:
         - any record other than NoChange, Ignore or NoEffect of a type in $dataGrantTypes below. Those
           types grant access to data through their own settings, such as a Key Vault access policy
           written as a resource of its own (Microsoft.KeyVault/vaults/accessPolicies), which with the
           access policy permission model grants the identities it names access to the vault's keys,
           secrets and certificates.
         - the Create of a Key Vault whose accessPolicies list is not empty.
         - a Modify that changes enableRbacAuthorization of a Key Vault, which decides whether RBAC or
           the vault's access policies grant access to its keys, secrets and certificates.
       The run stops with REVIEW
       (exit 1) until a person has read them and the run passes -AcknowledgeReview. They are listed
       as "Review record:" lines in pre-summary.txt and under reviewRecords in pre-gate.json, each
       with the reason and whether it was acknowledged. A Deploy record of any other type is
       refused outright.
       A delta in the accessPolicies property of a Key Vault itself fails outright. No flag lifts it.
       What-if diagnostics, a non-Succeeded status, potential changes (potentialChanges, a second list
       of predicted changes the gate does not judge) or a resource outside the unit's scope fail it.
       A Modify on a resource named in -AllowModify passes for its unlisted property changes only in
       a deploy run (-DryRun:$false -Approve). A dry run shows each of them as "would be
       allowed with -AllowModify" and stops with the verdict REVIEW, so the reviewer sees what would
       change. This covers every changed property of the named resource, including a setting or
       inline item the change removes (a subnet, a security rule, a route, a peering, a tag), which is
       a (Delete) change line inside the Modify record, allowed like any other. Every changed
       property of a named resource, with its value before and after, is written to pre-gate.json
       and pre-summary.txt.
       A deploy run with -AllowModify also needs -ApprovedChanges, the pre-gate.json of the approved
       dry run. Before anything is deployed it checks that the dry run was a dry run of this unit at
       this commit from a committed tree, with the same -AllowModify list, the same -AllowCreate and
       -AllowHeld lists (exit 2 on any difference), and that the property changes it is about to
       allow (resource, path, change type, value before and after) are exactly the ones the dry run
       showed as "would be allowed with -AllowModify". Every review item it accepts with
       -AcknowledgeReview must be one that dry run showed, accepted or waiting for the switch (exit 1
       otherwise). Anything else, such as a change made in the estate since the dry run, stops it
       (exit 1).
    7. Evidence (compiled template, what-if JSON, gate decisions, summary, and pre-groups.json, the
       live resource groups, in a drift check that compares them) is written to
       -EvidenceRoot/<unit>/<timestamp>-<commit>. Every STOP after that folder is created (from the
       commit check on) also writes stop.txt there with the reason, so a run refused before the gate
       (identity, tenant, an uncommitted tree) leaves that record rather than an empty folder.
       Argument and allowlist errors (an unknown or disabled unit, a tenant-kind unit, missing or
       conflicting flags) stop before the folder exists and write none. An offline -WhatIfJson
       evaluation ends with its summary only.

  Steps 8 to 11 run only on a deploy run whose gate passed, with -DryRun:$false and -Approve
  both given: 8. the -ApprovedChanges comparison described under step 6. 9. the commit,
  the tree and the identity are checked again, and no other deployment may be running at the scope (a
  deployment in any state other than Succeeded, Failed, Canceled or Deleted counts as running).
  10. approval.txt is written (the signed-in account that ran it, the pipeline run, the start time, the -AllowCreate, -AllowModify and -AllowHeld
  lists and the -ApprovedChanges file, kept in the evidence as approved-changes.json), and the
  deployment runs, always Incremental, with a deterministic name (mirror-<unit>-<short commit>).
  11. a second what-if is judged WITHOUT -AllowCreate and -AllowModify. A created or changed
  resource must now be NoChange, or differ only by listed boundaries, and every named resource that
  the first check allowed must still be in the preview. Anything other than a pass is reported as a
  failed deployment (exit 3).

  Changes after the first deployment (a setting changed on purpose, a rollback of such a change,
  undoing drift by deploying the code) go through -AllowModify with the resource IDs that change,
  so they get the same checks and evidence as a mirror deployment. A plain az deployment group
  create stays possible, but it skips every check above.

  With -WhatIfJson it makes no Azure calls at all. It evaluates a saved what-if file against the
  gate and writes the evidence. Useful for testing the gate offline against a saved what-if.

  With -Drift it is the drift check, run by hand or by preflight-drift.ps1. The drift
  workflow has no schedule until IT approves one. It is always a dry run, holds,
  review boundaries and review records (the three kinds above) are reported but expected, and an Ignore
  record that matches none of the expectedIgnore patterns in boundaries.json fails, because it means
  someone created a resource outside Bicep. For a subscription unit whose template is the subscription
  folder's main.bicep, the one that declares its resource groups, it also lists the live resource groups
  (az group list) and fails each one without a record in the preview as NoRecord, because such a group
  is declared nowhere and nothing in it is measured. A list that fails is an error (exit 2). A preview the gate cannot judge (a diagnostic, a status
  other than Succeeded, no changes array) is an error (exit 2), not drift. Units with a measuredWith list in units.json also take a
  what-if of those sibling resource group files (the deploy-excluded ones) and merge the results, so
  the whole resource group is measured. A drift run skips the duplicate check. preflight-validate.ps1,
  which the validate workflow runs, covers it.

  A subscription-scope what-if reports every resource inside a resource group as Ignore when that
  group's contents are deployed by a resourceGroup unit of their own, not through the subscription
  template. So in
  a drift check of a subscription unit, an Ignore record for a resource inside a resource group that
  has its own resourceGroup unit in units.json (same subscription, same group name, any case,
  enabled or not) passes, because that unit's own drift check is the one that measures it. The note reads
  "measured by <unit>" when that unit is enabled, and "covered by <unit>, which is disabled" when it
  is not, so that preflight-drift.ps1 can say how many resources nothing measures yet. Any other
  unexplained Ignore still fails, including a resource in a
  group that has no unit. A resource group record itself fails too, unless the unit names, in
  groupsDeclaredBy, the subscription unit that declares its resource groups (demo-vpn-gateways
  deploys into two groups that demo-subscription declares), then it is reported as "declared by
  <unit>", and that unit's own drift check measures the group.

.PARAMETER Unit
  The unit's name in deploy/units.json, for example rg-demo-network or demo-subscription.
  It is matched character by character, case included.

.PARAMETER DryRun
  On by default. Pass -DryRun:$false to allow a deployment.

.PARAMETER Approve
  Confirms that a reviewer approved this unit at this commit. The evidence records the signed-in
  account that ran it, the pipeline run and the time. In the pipeline the approval is the reviewers' decision in the run,
  and by hand it is the written approval, kept outside the
  script.

.PARAMETER AllowCreate
  Resource IDs that may come back as Create. Anything else Create fails. A Create that is a data-access
  change (above) also needs -AcknowledgeReview. An ID with no Create record in the preview gets a NOTE line
  in pre-summary.txt. An ID in -AllowCreate, -AllowModify or -AllowHeld that holds
  a control or invisible character or a space other than the plain one, or ends with a slash, stops the
  run (exit 2). The IDs are matched without case and otherwise character by character. Not allowed with
  -Drift.

.PARAMETER AllowModify
  Resource IDs whose Modify may carry property changes that boundaries.json does not list, in a deploy
  run only (above). Each must be approved for this unit and commit. It never lifts a Delete or
  Unsupported record (a whole resource), a change to the accessPolicies property of a Key Vault, a hold
  (-AllowHeld), a review boundary or a review record (-AcknowledgeReview), so a data-access change
  (above) still stops the run for review. A property or inline item removed from a named resource (a
  Delete leaf inside its Modify) is allowed like any other change. Read it in pre-summary.txt. Not
  allowed with -Drift.

.PARAMETER ApprovedChanges
  The pre-gate.json of the approved dry run (or its evidence folder). Required on a deploy run with
  -AllowModify, and used only there. The deploy run stops unless it allows exactly the changes that dry
  run showed (above), with the same three lists, and acknowledges no review item it did not show. A
  relative path is read from the current PowerShell location.

.PARAMETER AllowHeld
  Resource IDs exempted from a hold in boundaries.json. An ID that lifts no hold in the preview gets a NOTE
  line in pre-summary.txt.

.PARAMETER AcknowledgeReview
  Passed by the operator after reading every review item of the dry run, with a reviewer's
  acceptance. It accepts the boundaries whose onDeploy is "review" and the review records (a Deploy
  record of a nested deployment, a Modify that lists no changed property, a data-access change). Each
  acknowledged item is noted in pre-gate.json and approval.txt records acknowledgeReview=True. It lifts
  no hold, allows no Create, no unlisted Modify, no Delete or Unsupported record and no change to the
  accessPolicies property of a Key Vault. With -ApprovedChanges, it may accept only the review items the
  approved dry run showed.

.PARAMETER WhatIfJson
  Evaluate saved what-if file(s) instead of calling Azure (forces a dry run). Several files (the
  previews of a resource group file and of its deploy-excluded sibling) are merged per resource ID
  first, as the drift check does. A resource ID that two of them declare (neither shows it as Ignore) fails
  the gate. A relative path is read from the current PowerShell location.

.PARAMETER Drift
  Drift-check semantics (see above), with the live resource groups compared for a unit that declares
  them. Forces a dry run.

.PARAMETER EvidenceRoot
  Where evidence folders go. Default reports/work/deployments (gitignored). The workflows upload the
  folder as a workflow artifact.

.EXAMPLE
  ./scripts/deploy-unit.ps1 -Unit rg-demo-network
  Checks, what-if and gate only. This is the default and changes nothing.

.EXAMPLE
  ./scripts/deploy-unit.ps1 -Unit rg-demo-network -DryRun:$false -Approve
  Deploys after the gate passes. Only after a reviewer approved this unit at this commit.

.EXAMPLE
  $id = '/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Storage/storageAccounts/<name>'
  ./scripts/deploy-unit.ps1 -Unit <unit> -AllowModify $id
  ./scripts/deploy-unit.ps1 -Unit <unit> -AllowModify $id -DryRun:$false -Approve `
      -ApprovedChanges reports/work/deployments/<unit>/<timestamp>-<commit>/pre-gate.json
  The first run shows the changes as "would be allowed with -AllowModify" (verdict REVIEW, exit 1).
  The second deploys them after approval, only if its own preview shows exactly the changes of the
  first run's pre-gate.json, and its second check must show the resource NoChange.

.NOTES
  Exit codes: 0 gate passed (and deployment succeeded, when one was requested). 1 gate failed or
  stopped for review (a review boundary, a review record, or a dry run with -AllowModify changes), or a deploy run's
  changes differ from the approved dry run's or it acknowledges a review item that dry run did not show. 2 configuration, identity or tooling error before anything is deployed (a deploy run also stops
  here when it cannot read the commit), an unexpected error before the deployment started, or a drift
  check whose preview the gate could not judge. 3 deployment failed, the post-deployment what-if did not
  pass or could not run, or an unexpected error after the deployment started. Runs unchanged under Windows PowerShell 5.1 and PowerShell 7.5 or later
  (Windows and Linux).
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Unit,
  [bool]$DryRun = $true,
  [switch]$Approve,
  [string[]]$AllowCreate = @(),
  [string[]]$AllowModify = @(),
  [string]$ApprovedChanges,
  [string[]]$AllowHeld = @(),
  [switch]$AcknowledgeReview,
  [string[]]$WhatIfJson,
  [switch]$Drift,
  [string]$EvidenceRoot
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

# Set once the evidence folder exists, so that a stop after that point leaves a record of why.
$evidence = $null
$context = $null

function Fail([int]$code, [string]$msg) {
  Write-Host "STOP: $msg" -ForegroundColor Red
  if ($evidence -and (Test-Path -LiteralPath $evidence)) {
    $rec = @("Stopped:    exit $code", "Reason:     $msg", "Unit:       $Unit")
    if ($null -ne $context) {
      $rec += "Commit:     $($context.commit)$(if ($context.dirty) { ' (working tree has uncommitted changes)' })"
      $rec += "Identity:   $($context.identity)"
      $rec += "Mode:       $($context.mode)"
    }
    $rec += "Time:       $((Get-Date).ToUniversalTime().ToString('u'))"
    try { Set-Content -LiteralPath (Join-Path $evidence 'stop.txt') -Value $rec -Encoding $utf8Bom } catch { }
  }
  exit $code
}
function Info([string]$msg) { Write-Host $msg }

# An error that no check of this script expects (a saved what-if or units.json that is not valid JSON, a file that
# cannot be read) stops the run with exit 2, so it never reads as a gate result, or with exit 3 once the deployment
# has started, because the deployment is then not verified. The message is written on one line and cut at 300
# characters, because Windows PowerShell 5.1 quotes the content of a JSON file it cannot read in the message and
# breaks the text of a child process's error into lines.
$deployStarted = $false
trap {
  $trapCode = if ($deployStarted) { 3 } else { 2 }
  $trapMsg = (([string]$_.Exception.Message -split '\s+') | Where-Object { $_ }) -join ' '
  if ($trapMsg.Length -gt 300) { $trapMsg = $trapMsg.Substring(0, 300) + ' ...' }
  Fail $trapCode "unexpected error$(if ($deployStarted) { ' after the deployment started, so treat it as a failed deployment and roll back as REFERENCE.md describes' }): $trapMsg"
}

$repo = Split-Path -Parent $PSScriptRoot
$unitsPath = [IO.Path]::Combine($repo, 'deploy', 'units.json')
$boundariesPath = [IO.Path]::Combine($repo, 'deploy', 'boundaries.json')
$onWindows = [IO.Path]::DirectorySeparatorChar -eq '\'
# A path given with '\' (for example "$env:RUNNER_TEMP\x") is written with '/' on Linux, where .NET and az take
# '\' as part of a file name.
function ConvertTo-SysSeparator([string]$p) { if (-not $p -or $onWindows) { return $p }; return $p.Replace('\', '/') }
# The evidence folder is written by .NET and by az --outfile as well as by cmdlets, so it is made a full path.
# A relative path then means the same folder to all of them. The same holds for -ApprovedChanges and -WhatIfJson,
# which are read by cmdlets and by .NET. .NET resolves a relative path against the folder the process started in,
# which cd does not change, so each is made a full path from the current PowerShell location.
function Resolve-FullPath([string]$p) { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((ConvertTo-SysSeparator $p)) }
if (-not $EvidenceRoot) { $EvidenceRoot = [IO.Path]::Combine($repo, 'reports', 'work', 'deployments') }
$EvidenceRoot = Resolve-FullPath $EvidenceRoot
if ($ApprovedChanges) { $ApprovedChanges = Resolve-FullPath $ApprovedChanges }
if ($null -ne $WhatIfJson -and @($WhatIfJson).Count -gt 0) {
  if (@($WhatIfJson | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) { Fail 2 '-WhatIfJson holds an empty path' }
  $WhatIfJson = @($WhatIfJson | ForEach-Object { Resolve-FullPath $_ })
}
# Windows PowerShell 5.1 writes UTF8 with a byte order mark. PowerShell 7 writes the same bytes only with utf8BOM.
$utf8Bom = if ($PSVersionTable.PSVersion.Major -ge 6) { 'utf8BOM' } else { 'UTF8' }
# The duplicate check runs in a child process of the PowerShell that runs this script: powershell.exe for
# Windows PowerShell 5.1, pwsh for PowerShell 7 (pwsh.exe on Windows). Where $PSHOME holds no such program
# (PowerShell installed as a dotnet tool), the program running this script is used.
$psExe = if ($PSVersionTable.PSEdition -ne 'Core') { Join-Path $PSHOME 'powershell.exe' } elseif ($onWindows) { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'pwsh' }
if (-not (Test-Path -LiteralPath $psExe -PathType Leaf)) { $psExe = (Get-Process -Id $PID).Path }
# az on Windows (az.cmd starts Python with -I, which ignores PYTHONUTF8 and PYTHONIOENCODING) writes text in
# the ANSI code page of the system, and az on Linux writes UTF-8. So that a value with a character such as a dash
# reads the same on every host, az output is taken byte for byte (Latin-1) on Windows and decoded by
# ConvertFrom-AzLine, as UTF-8 when the bytes are valid UTF-8 and otherwise in the ANSI code page. On Linux it is
# read as UTF-8. Plain ASCII output is the same either way.
$azCapture = if ($onWindows) { [Text.Encoding]::GetEncoding(28591) } else { New-Object System.Text.UTF8Encoding $false }
$azUtf8Strict = New-Object System.Text.UTF8Encoding($false, $true)
$azHighByte = New-Object regex ("[$([char]0x80)-$([char]0xFF)]")
function ConvertFrom-AzLine([string]$s, [bool]$captured) {
  if (-not ($onWindows -and $captured) -or -not $azHighByte.IsMatch($s)) { return $s }
  $b = $azCapture.GetBytes($s)
  try { return $azUtf8Strict.GetString($b) } catch { return [Text.Encoding]::GetEncoding(0).GetString($b) }
}
# A text file read the same way on every host. Get-Content reads a file without a byte order mark in the ANSI
# code page on Windows PowerShell 5.1 and as UTF-8 on PowerShell 7, and saved what-if files come in both forms.
# az > file on Windows writes the ANSI code page, and this script's own evidence and az on Linux write UTF-8. So a
# file with a UTF-8 or UTF-16 mark is read by its mark, a file of valid UTF-8 as UTF-8, and anything else in
# the ANSI code page (Windows-1252 on Linux).
function Read-TextFile([string]$path) {
  $b = [IO.File]::ReadAllBytes($path)
  if ($b.Length -eq 0) { return }
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) { return $azUtf8Strict.GetString($b, 3, $b.Length - 3) }
  if ($b.Length -ge 2 -and $b[0] -eq 0xFF -and $b[1] -eq 0xFE) { return [Text.Encoding]::Unicode.GetString($b, 2, $b.Length - 2) }
  if ($b.Length -ge 2 -and $b[0] -eq 0xFE -and $b[1] -eq 0xFF) { return [Text.Encoding]::BigEndianUnicode.GetString($b, 2, $b.Length - 2) }
  try { return $azUtf8Strict.GetString($b) } catch { if ($onWindows) { return [Text.Encoding]::GetEncoding(0).GetString($b) } else { return [Text.Encoding]::GetEncoding(1252).GetString($b) } }
}
# PowerShell 7 reads a JSON string that looks like a date as a DateTime, and writes it back in another form.
# -DateKind String (PowerShell 7.5 and later) keeps the text as it is, as Windows PowerShell 5.1 always does,
# so a date in a what-if value and in the evidence is the same under both. Numbers are still typed differently
# by the two (Int32, Int64, Decimal and Double under 5.1, Int64, Double and BigInteger under 7), so the -ApprovedChanges
# comparison writes values in a canonical form of its own (ConvertTo-CanonJson, below).
$jsonArgs = @{}
if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $jsonArgs['DateKind'] = 'String' }
elseif ($PSVersionTable.PSVersion.Major -ge 6) { Write-Host "STOP: PowerShell $($PSVersionTable.PSVersion) reads dates in JSON as DateTime values. Use PowerShell 7.5 or later, or Windows PowerShell 5.1" -ForegroundColor Red; exit 2 }
function ConvertFrom-JsonText($text) { if ($null -eq $text) { return }; return ($text | ConvertFrom-Json @jsonArgs) }
$offline = ($null -ne $WhatIfJson -and @($WhatIfJson).Count -gt 0)
if ($offline -or $Drift) {
  if (-not $DryRun -or $Approve) { Write-Host 'STOP: -WhatIfJson and -Drift never deploy. Drop -DryRun:$false and -Approve' -ForegroundColor Red; exit 2 }
  $DryRun = $true
}
# A drift check whose preview the gate could not judge (a diagnostic, a status other than Succeeded, no changes
# array) has measured nothing, so it ends with exit 2, as any other check that could not run.
$driftProblemMsg = 'the drift check could not judge the preview (the Problem lines above), so this is an error, not drift. Nothing was deployed'
# A drift check measures the live state against the code. An approval list has no meaning there.
if ($Drift -and @($AllowModify | Where-Object { $_ }).Count -gt 0) { Write-Host 'STOP: -AllowModify is not allowed with -Drift' -ForegroundColor Red; exit 2 }
if ($Drift -and @($AllowCreate | Where-Object { $_ }).Count -gt 0) { Write-Host 'STOP: -AllowCreate is not allowed with -Drift, because a Create in a drift check is a resource the code declares and Azure lacks' -ForegroundColor Red; exit 2 }
$AllowCreate = @($AllowCreate | Where-Object { $_ } | ForEach-Object { $_.Trim() })
$AllowModify = @($AllowModify | Where-Object { $_ } | ForEach-Object { $_.Trim() })
$AllowHeld = @($AllowHeld | Where-Object { $_ } | ForEach-Object { $_.Trim() })

# Strict mode throws on a missing property. What-if payloads omit fields freely.
function Get-Prop($obj, [string]$name) {
  if ($null -eq $obj) { return $null }
  $p = $obj.PSObject.Properties[$name]
  if ($null -eq $p) { return $null }
  return $p.Value
}

# True when the property exists and holds an array, empty or not.
function Test-ArrayProp($obj, [string]$name) {
  if ($null -eq $obj) { return $false }
  $p = $obj.PSObject.Properties[$name]
  return ($null -ne $p -and $p.Value -is [System.Array])
}

# Runs az and returns stdout as one string. stderr is kept apart because az prints warnings there
# (linter output, upgrade notices) that are not failures. Windows PowerShell turns native stderr into
# error records, which is why the preference is relaxed only for the call itself. The console encoding is
# set for the call only (see $azCapture) and put back afterwards.
function Invoke-Az([string[]]$azArgs, [switch]$AllowFailure) {
  $prev = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $prevEnc = [Console]::OutputEncoding
  $captured = $false
  try { [Console]::OutputEncoding = $azCapture; $captured = $true } catch { }
  try { $all = & az @azArgs 2>&1 }
  finally {
    $ErrorActionPreference = $prev
    if ($captured) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
  }
  $code = $LASTEXITCODE
  $out = @($all | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { ConvertFrom-AzLine "$_" $captured }) -join "`n"
  $err = @($all | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } | ForEach-Object { ConvertFrom-AzLine "$_" $captured }) -join "`n"
  if ($code -ne 0 -and -not $AllowFailure) {
    Fail 2 ("az {0} failed (exit {1}):`n{2}" -f ($azArgs[0..([Math]::Min(2, $azArgs.Count - 1))] -join ' '), $code, $err)
  }
  return [pscustomobject]@{ Code = $code; Out = $out; Err = $err }
}

function Get-ResourceType([string]$id) {
  $i = $id.ToLowerInvariant().LastIndexOf('/providers/')
  if ($i -lt 0) {
    if ($id -match '(?i)^/subscriptions/[^/]+/resourceGroups/[^/]+$') { return 'Microsoft.Resources/resourceGroups' }
    return 'unknown'
  }
  $parts = $id.Substring($i + 11).Split('/')
  $t = @($parts[0])
  for ($k = 1; $k -lt $parts.Count; $k += 2) { $t += $parts[$k] }
  return ($t -join '/')
}

function Get-ResourceNameChain([string]$id) {
  $i = $id.ToLowerInvariant().LastIndexOf('/providers/')
  if ($i -lt 0) { return ($id.Split('/')[-1]) }
  $parts = $id.Substring($i + 11).Split('/')
  $n = @()
  for ($k = 2; $k -lt $parts.Count; $k += 2) { $n += $parts[$k] }
  return ($n -join '/')
}

# Flattens what-if deltas to leaves. Each leaf is the path, with array indices written as [*], plus the
# change type.
function Get-DeltaLeaves($nodes, [string]$prefix) {
  $leaves = @()
  foreach ($d in @($nodes)) {
    if ($null -eq $d) { continue }
    $seg = [string](Get-Prop $d 'path')
    if ($prefix -eq '') { $p = $seg }
    elseif ($seg -match '^\d+$') { $p = "$prefix[$seg]" }
    else { $p = "$prefix.$seg" }
    $children = Get-Prop $d 'children'
    if ($null -ne $children -and @($children).Count -gt 0) {
      $leaves += Get-DeltaLeaves $children $p
    } else {
      $leaf = [pscustomobject]@{
        Path = ($p -replace '\[\d+\]', '[*]')
        RawPath = $p
        ChangeType = [string](Get-Prop $d 'propertyChangeType')
        HasBefore = $false; Before = $null; HasAfter = $false; After = $null
      }
      # Assigned, not returned from a function, so an array value keeps its shape.
      $bp = $d.PSObject.Properties['before']; if ($null -ne $bp) { $leaf.HasBefore = $true; $leaf.Before = $bp.Value }
      $ap = $d.PSObject.Properties['after']; if ($null -ne $ap) { $leaf.HasAfter = $true; $leaf.After = $ap.Value }
      $leaves += $leaf
    }
  }
  return $leaves
}

# A property value as compact JSON for the summary. Long values are cut there and kept whole in the gate JSON.
function Format-Value($v, [switch]$Absent) {
  if ($Absent) { return '(absent)' }
  if ($null -eq $v) { return 'null' }
  $j = ConvertTo-Json -InputObject $v -Depth 20 -Compress
  if ($j.Length -gt 300) { $j = $j.Substring(0, 300) + ' ... (cut, the whole value is in the gate JSON)' }
  return $j
}

# One changed property of a resource named in -AllowModify, for the evidence. A leaf added by the
# change has no value before it, and a leaf removed by it has none after.
function New-ChangeRecord($leaf, [string]$decision) {
  $noBefore = (-not $leaf.HasBefore) -or ($leaf.ChangeType -eq 'Create' -and $null -eq $leaf.Before)
  $noAfter = (-not $leaf.HasAfter) -or ($leaf.ChangeType -eq 'Delete' -and $null -eq $leaf.After)
  $note = "change $($leaf.RawPath) ($($leaf.ChangeType)): before $(Format-Value $leaf.Before -Absent:$noBefore), after $(Format-Value $leaf.After -Absent:$noAfter); $decision"
  $rec = [pscustomobject]@{ path = $leaf.RawPath; propertyChangeType = $leaf.ChangeType; before = $leaf.Before; after = $leaf.After; decision = $decision }
  return [pscustomobject]@{ Record = $rec; Note = $note }
}

function Test-PathPattern([string]$pattern, [string]$path) {
  $rx = [regex]::Escape($pattern) -replace '\\\*\\\*', '.*'
  return [regex]::IsMatch($path, '^' + $rx + '($|[.\[])', 'IgnoreCase')
}

function Find-Boundary($boundaries, [string]$type, $leaf) {
  foreach ($b in $boundaries) {
    if ($b.type -ne $type) { continue }   # -ne on strings is case-insensitive
    if (@($b.changeTypes) -notcontains $leaf.ChangeType) { continue }
    if (Test-PathPattern $b.path $leaf.Path) { return $b }
  }
  return $null
}

# A hold names either a full resource ID pattern (idPattern) or a type plus a pattern matched
# against "/<name chain>" (namePattern), so "/SamplePatchExtension$" matches only the extension.
function Find-Hold($holds, [string]$id, [string]$type, [string]$nameChain) {
  foreach ($h in $holds) {
    $idp = Get-Prop $h 'idPattern'
    if ($idp) { if ([regex]::IsMatch($id, $idp)) { return $h } else { continue } }
    if ($h.type -eq $type -and [regex]::IsMatch("/$nameChain", $h.namePattern)) { return $h }
  }
  return $null
}

# Combines what-ifs of files that share a resource group (the routine resource group file and its
# deploy-excluded sibling). Each one reports the other's resources as Ignore, so per resource ID a
# declared record beats an Ignore. Status, errors, diagnostics and potential changes from every input are kept.
# A resource that two of the files declare (neither shows it as Ignore) would be deployed twice, so the merged
# preview keeps the record that is not NoChange and lists the ID under mergeProblems, which fails the gate.
function Merge-WhatIf([object[]]$results) {
  $byId = New-Object System.Collections.Specialized.OrderedDictionary ([StringComparer]::Ordinal)
  $diags = @(); $errors = @(); $potential = @(); $twice = @(); $status = 'Succeeded'
  foreach ($w in $results) {
    $props = Get-Prop $w 'properties'
    $st = Get-Prop $w 'status'; if ($null -eq $st -and $null -ne $props) { $st = Get-Prop $props 'provisioningState' }
    if ($st -ne 'Succeeded') { $status = $st }
    $e = Get-Prop $w 'error'; if ($null -ne $e) { $errors += $e }
    $d = Get-Prop $w 'diagnostics'; if ($null -eq $d -and $null -ne $props) { $d = Get-Prop $props 'diagnostics' }
    $diags += @($d | Where-Object { $null -ne $_ })
    $pc = Get-Prop $w 'potentialChanges'; if ($null -eq $pc -and $null -ne $props) { $pc = Get-Prop $props 'potentialChanges' }
    $potential += @($pc | Where-Object { $null -ne $_ })
    $ch = Get-Prop $w 'changes'; if ($null -eq $ch -and $null -ne $props) { $ch = Get-Prop $props 'changes' }
    foreach ($c in @($ch)) {
      if ($null -eq $c) { continue }
      $k = ([string](Get-Prop $c 'resourceId')).ToLowerInvariant()
      if (-not $byId.Contains($k)) { $byId[$k] = $c; continue }
      $was = [string](Get-Prop $byId[$k] 'changeType'); $now = [string](Get-Prop $c 'changeType')
      if ($now -eq 'Ignore') { continue }
      if ($was -eq 'Ignore') { $byId[$k] = $c; continue }
      $twice += "$(Get-Prop $c 'resourceId') is declared by two of the merged previews ($was and $now), so it would be deployed twice"
      if ($was -eq 'NoChange') { $byId[$k] = $c }
    }
  }
  $merged = [pscustomobject]@{ status = $status; error = $null; diagnostics = $diags; potentialChanges = $potential; mergeProblems = $twice; changes = @($byId.Values) }
  if ($errors.Count -gt 0) { $merged.error = $errors[0] }
  return $merged
}

# Drift of a subscription unit, for an Ignore record that matches no expectedIgnore pattern.
# For a resource inside a resource group the note is "measured by <unit>" when a resourceGroup unit covers that
# group (same subscription ID and group name, case-insensitive) and is enabled. "covered by <unit>,
# which is disabled" when it is not, so the record passes but the drift summary says it is not
# measured yet (preflight-drift.ps1 counts these). For the group record itself it is "declared
# by <unit>" only when this unit's groupsDeclaredBy names a subscription unit of the same
# subscription, and the group has a resourceGroup unit. Anything else returns $null and fails.
function Find-DriftOwner([string]$id) {
  $m = [regex]::Match($id, '^/subscriptions/([^/]+)/resourceGroups/([^/]+)(/providers/.*)?$', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $rgUnit = $null; $rgEnabled = $false
  foreach ($u in @($udoc.units)) {
    if ($u.kind -ne 'resourceGroup') { continue }
    $usub = [string](Get-Prop $udoc.subscriptions $u.subscription)
    if ($usub -eq $m.Groups[1].Value -and [string]$u.resourceGroup -eq $m.Groups[2].Value) { $rgUnit = $u.name; $rgEnabled = [bool]$u.enabled; break }
  }
  if (-not $rgUnit) { return $null }
  if ($m.Groups[3].Success) {
    if ($rgEnabled) { return "measured by $rgUnit" }
    return "covered by $rgUnit, which is disabled, so it is not measured until that unit is enabled"
  }
  $decl = [string](Get-Prop $unitDef 'groupsDeclaredBy')
  if (-not $decl) { return $null }
  $du = @($udoc.units | Where-Object { (Test-SameName ([string]$_.name) $decl) -and $_.kind -eq 'subscription' -and $_.subscription -eq $unitDef.subscription })
  if ($du.Count -eq 0) { return $null }
  return "declared by $decl"
}

# A unit that declares its subscription's resource groups: a subscription unit whose template is the subscription
# folder's main.bicep, the same rule as Test-SubscriptionMainUnit in .github/scripts/mirror-pipeline.ps1. Its drift check
# compares the live resource groups with the preview, because a group created outside the code gives no record.
function Test-DeclaresResourceGroups($u) {
  return ([string](Get-Prop $u 'kind') -eq 'subscription' -and ([string](Get-Prop $u 'template')).Replace('\', '/') -match '^infra/subscriptions/[^/]+/main\.bicep$')
}

# Unit names are matched character by character, case included, everywhere, as the pipeline matches them, so that
# one name always means one unit. PowerShell's -eq and -ceq compare strings by the rules of a language, which
# ignore some characters that do not show on screen, such as a zero-width space on PowerShell 7 and a soft hyphen
# on Windows PowerShell 5.1. So a name with such a character would match a unit it does not spell. An ordinal
# comparison compares the characters themselves.
function Test-SameName([string]$a, [string]$b) { return [string]::Equals($a, $b, [StringComparison]::Ordinal) }

# Resource IDs are matched without case, as Azure matches them, and otherwise character by character for the same
# reason. Each is lowered with the invariant culture and compared ordinally, never with -eq, -contains or a sort.
function Test-SameId([string]$a, [string]$b) { return [string]::Equals($a.ToLowerInvariant(), $b.ToLowerInvariant(), [StringComparison]::Ordinal) }
function New-OrdinalSet([string[]]$items) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
  foreach ($x in @($items)) { if ($null -ne $x) { [void]$set.Add($x) } }
  return , $set
}
function New-IdSet([string[]]$ids) { return , (New-OrdinalSet @(@($ids) | Where-Object { $null -ne $_ } | ForEach-Object { $_.ToLowerInvariant() })) }
# The items once each, in ordinal order, so that two lists compare the same on every host.
function Get-OrdinalSorted([string[]]$items) {
  $set = New-OrdinalSet $items
  $a = [string[]]@($set)
  [Array]::Sort($a, [StringComparer]::Ordinal)
  return , $a
}

# For a name that matches no unit, this returns the units whose name differs from it only in case, each in quotes
# and joined with "or", for the refusal message. It returns an empty string when there is none.
function Get-CaseOnlyMatch([string]$name) {
  return (@($udoc.units | Where-Object { -not (Test-SameName ([string]$_.name) $name) -and [string]::Equals([string]$_.name, $name, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "'$($_.name)'" }) -join ' or ')
}

# For a name that matches no unit, this names each space and each character outside printable ASCII in it, for
# the refusal message, because such a character may not show on screen. It returns an empty string when there is none.
function Get-HiddenCharNote([string]$name) {
  $found = @()
  for ($i = 0; $i -lt $name.Length; $i++) {
    $code = [int]$name[$i]
    if ($code -lt 0x21 -or $code -gt 0x7E) { $found += ('U+{0:X4} at position {1}' -f $code, ($i + 1)) }
  }
  if ($found.Count -eq 0) { return '' }
  return ". The name holds $($found -join ', '), which may not show on screen"
}

# The same note for a resource ID, naming only the characters the ID rule refuses, so a plain space in a resource
# name is not reported as the problem.
function Get-RefusedIdCharNote([string]$id) {
  $found = @()
  for ($i = 0; $i -lt $id.Length; $i++) {
    if ([string]$id[$i] -match '\p{C}|[\p{Z}-[\x20]]|\u00AD') { $found += ('U+{0:X4} at position {1}' -f [int]$id[$i], ($i + 1)) }
  }
  if ($found.Count -eq 0) { return '' }
  return ". The ID holds $($found -join ', '), which may not show on screen"
}

# Returns the built parameters (parametersJson) for the evidence copy, with the value of every parameter that the
# template of the using line (templateJson, built by the same call) declares as secureString or secureObject
# replaced. Both come from az bicep build-params --stdout, so a secure value is never written before it is
# replaced. The copy is never read again. The CLI builds the parameters itself from the .bicepparam file for the
# preview and the deployment.
function Protect-SecureParameters([string]$templateJson, [string]$parametersJson) {
  $t = ConvertFrom-JsonText $templateJson
  $secure = @()
  $tp = if ($null -ne $t) { $t.PSObject.Properties['parameters'] } else { $null }
  if ($null -ne $tp -and $null -ne $tp.Value) {
    foreach ($p in $tp.Value.PSObject.Properties) {
      $ty = [string](Get-Prop $p.Value 'type')
      if ([string]::Equals($ty, 'secureString', [StringComparison]::OrdinalIgnoreCase) -or [string]::Equals($ty, 'secureObject', [StringComparison]::OrdinalIgnoreCase)) { $secure += $p.Name }
    }
  }
  if ($secure.Count -eq 0) { return $parametersJson }
  $doc = ConvertFrom-JsonText $parametersJson
  $dp = $doc.PSObject.Properties['parameters']
  if ($null -eq $dp -or $null -eq $dp.Value) { return $parametersJson }
  $n = 0
  foreach ($name in $secure) {
    $v = $dp.Value.PSObject.Properties[$name]
    if ($null -ne $v -and $null -ne $v.Value -and $null -ne $v.Value.PSObject.Properties['value']) { $v.Value.value = '<secure input, not recorded>'; $n++ }
  }
  if ($n -gt 0) { return ($doc | ConvertTo-Json -Depth 50) }
  return $parametersJson
}

# Resource types that grant access to data through their own settings. Contributor can write them, so the gate
# makes every record of them other than NoChange, Ignore or NoEffect a data-access review record. The same list as
# $script:DataGrantTypes in .github/scripts/mirror-pipeline.ps1, which keeps them out of the pipeline units.
# Matched without case, with '*' as a wildcard.
$dataGrantTypes = @('Microsoft.KeyVault/vaults/accessPolicies', 'Microsoft.DocumentDB/databaseAccounts/*RoleAssignments',
  'Microsoft.DocumentDB/databaseAccounts/*RoleDefinitions', 'Microsoft.DocumentDB/databaseAccounts/*UserDefinitions',
  'Microsoft.Sql/servers/administrators', 'Microsoft.Sql/servers/azureADOnlyAuthentications',
  'Microsoft.Sql/managedInstances/administrators', 'Microsoft.DBforPostgreSQL/flexibleServers/administrators',
  'Microsoft.DBforMySQL/flexibleServers/administrators', 'Microsoft.Synapse/workspaces/administrators',
  'Microsoft.Kusto/clusters/principalAssignments', 'Microsoft.Kusto/clusters/databases/principalAssignments')

# The gate. Returns one decision per record plus totals. Never throws on content.
# Stage 'post' is the second check after a deployment. It is judged without -AllowCreate and
# -AllowModify, so a resource they let through must now be NoChange (or differ only by listed
# boundaries), and every ID in $mustBePresent must have a record.
function Test-WhatIf($whatIf, $unitDef, [string]$subId, $bdoc, [string]$Stage = 'pre', [string[]]$mustBePresent = @(), [string[]]$liveGroups = $null) {
  $boundaries = @($bdoc.boundaries)
  $holds = @($bdoc.holds)
  $expectedIgnore = @($bdoc.expectedIgnore)
  $okDelta = @($bdoc.alwaysAcceptedPropertyChangeTypes)
  $allowCreateSet = New-IdSet @()
  $allowModifySet = New-IdSet @()
  if ($Stage -ne 'post') {
    $allowCreateSet = New-IdSet $AllowCreate
    $allowModifySet = New-IdSet $AllowModify
  }
  $allowHeldSet = New-IdSet $AllowHeld
  $problems = @()
  $decisions = @()
  $reviewRecords = @()

  $status = Get-Prop $whatIf 'status'
  $props = Get-Prop $whatIf 'properties'
  if ($null -eq $status -and $null -ne $props) { $status = Get-Prop $props 'provisioningState' }
  if ($status -ne 'Succeeded') { $problems += "what-if status is '$status', not Succeeded" }
  $err = Get-Prop $whatIf 'error'
  if ($null -ne $err) { $problems += ("what-if error: " + (Get-Prop $err 'code') + ' ' + (Get-Prop $err 'message')) }
  $diags = Get-Prop $whatIf 'diagnostics'
  if ($null -eq $diags -and $null -ne $props) { $diags = Get-Prop $props 'diagnostics' }
  foreach ($dg in @($diags)) {
    if ($null -eq $dg) { continue }
    # Expansion-limit diagnostics mean what-if skipped records, so the result cannot be trusted.
    $problems += ("diagnostic {0} {1}: {2} ({3})" -f (Get-Prop $dg 'level'), (Get-Prop $dg 'code'), (Get-Prop $dg 'message'), (Get-Prop $dg 'target'))
  }
  # A what-if result can carry a second list of predicted changes, potentialChanges, beside changes. The gate judges
  # only the changes array, so a preview that lists any potential change has not been judged in full and fails.
  # A resource that two merged previews declare (Merge-WhatIf) fails it too.
  $potential = Get-Prop $whatIf 'potentialChanges'
  if ($null -eq $potential -and $null -ne $props) { $potential = Get-Prop $props 'potentialChanges' }
  $potentialCount = @($potential | Where-Object { $null -ne $_ }).Count
  if ($potentialCount -gt 0) { $problems += "what-if lists $potentialCount potential change(s) (potentialChanges), which the gate does not judge" }
  foreach ($mp in @(Get-Prop $whatIf 'mergeProblems')) { if ($null -ne $mp) { $problems += $mp } }
  $changes = Get-Prop $whatIf 'changes'
  if ($null -eq $changes -and $null -ne $props) { $changes = Get-Prop $props 'changes' }
  # PowerShell turns an empty array returned from a function into $null, so an empty changes array
  # (the pilot's empty template) is told apart from a missing one by the property itself.
  if ($null -eq $changes) {
    if (-not ((Test-ArrayProp $whatIf 'changes') -or (Test-ArrayProp $props 'changes'))) { $problems += 'what-if returned no changes array' }
    $changes = @()
  }

  $scopePrefix = "/subscriptions/$subId".ToLowerInvariant()
  $rgPrefix = $null
  if ($unitDef.kind -eq 'resourceGroup') { $rgPrefix = "$scopePrefix/resourcegroups/$($unitDef.resourceGroup)".ToLowerInvariant() }

  foreach ($ch in @($changes)) {
    $id = [string](Get-Prop $ch 'resourceId')
    $ct = [string](Get-Prop $ch 'changeType')
    $type = Get-ResourceType $id
    $nameChain = Get-ResourceNameChain $id
    $idl = $id.ToLowerInvariant()
    $verdict = 'pass'
    $notes = @()
    $named = $allowModifySet.Contains($idl)
    $changeRecords = @()
    $reviewWhy = $null
    $dataWhy = $null

    $inScope = $true
    if ($unitDef.kind -ne 'tenant') {
      if (-not ([string]::Equals($idl, $scopePrefix, [StringComparison]::Ordinal) -or $idl.StartsWith("$scopePrefix/", [StringComparison]::Ordinal))) { $inScope = $false }
      if ($rgPrefix -and -not ([string]::Equals($idl, $rgPrefix, [StringComparison]::Ordinal) -or $idl.StartsWith("$rgPrefix/", [StringComparison]::Ordinal))) { $inScope = $false }
    }
    if (-not $inScope -and $ct -ne 'Ignore') { $verdict = 'fail'; $notes += 'outside the unit scope' }

    switch ($ct) {
      'NoChange' { }
      'Ignore' {
        $expected = @($expectedIgnore | Where-Object { [regex]::IsMatch($id, $_.pattern) } | Select-Object -First 1)
        $owner = $null
        if ($expected.Count -eq 0 -and $Drift -and $unitDef.kind -eq 'subscription') { $owner = Find-DriftOwner $id }
        if ($expected.Count -gt 0) { $notes += "expected: $($expected[0].reason)" }
        elseif ($owner) { $notes += $owner }
        elseif ($Drift) { $verdict = 'fail'; $notes += 'live resource not declared in Bicep and not an expected exception' }
        else { $notes += 'live resource not declared, so Incremental mode leaves it alone' }
      }
      'Deploy' {
        if ($type -ne 'Microsoft.Resources/deployments') { $verdict = 'fail'; $notes += 'Deploy record for a resource, and what-if could not tell what changes' }
        else { $reviewWhy = 'Deploy record of a nested deployment: the preview could not work out what this module writes and lists nothing inside it, so none of it was checked' }
      }
      'Create' {
        if ($allowCreateSet.Contains($idl)) { $notes += 'Create allowed by -AllowCreate' }
        elseif ($Stage -eq 'post') { $verdict = 'fail'; $notes += 'still Create in the second check: the deployment did not create it' }
        else { $verdict = 'fail'; $notes += 'Create is not allowed (pass the ID in -AllowCreate only when a reviewer accepts a new resource)' }
      }
      'Modify' {
        $leaves = @(Get-DeltaLeaves (Get-Prop $ch 'delta') '')
        if ($leaves.Count -eq 0) { $reviewWhy = 'Modify that lists no changed property: the preview says the resource differs but not how, so no rule can judge it' }
        foreach ($leaf in $leaves) {
          if ($okDelta -contains $leaf.ChangeType) {
            if ($named) { $changeRecords += New-ChangeRecord $leaf "no effect ($($leaf.ChangeType))" }
            continue
          }
          # A PUT replaces the whole access policy list, so a policy added in the portal since the
          # template was written would be dropped. This is a stop, not a review item, so no flag
          # (-AcknowledgeReview, -AllowModify) lifts it. The fix is RBAC (or migrating the policies)
          # before the vault is deployed.
          if ($type -eq 'Microsoft.KeyVault/vaults' -and (Test-PathPattern 'properties.accessPolicies' $leaf.Path)) {
            $verdict = 'fail'
            $notes += "Key Vault access policy delta $($leaf.RawPath) ($($leaf.ChangeType)): the access policy list is replaced on PUT and must move to RBAC or be migrated first"
            if ($named) { $changeRecords += New-ChangeRecord $leaf 'refused: Key Vault access policies' }
            continue
          }
          # The leaf is judged as any other below. The review record for it is added after the switch.
          if ($type -eq 'Microsoft.KeyVault/vaults' -and (Test-PathPattern 'properties.enableRbacAuthorization' $leaf.Path)) {
            $dataWhy = "This Modify changes enableRbacAuthorization of a Key Vault, which decides whether RBAC or the vault's access policies grant access to its keys, secrets and certificates"
          }
          $b = Find-Boundary $boundaries $type $leaf
          if ($null -eq $b) {
            if (-not $named) {
              $verdict = 'fail'
              $notes += "unclassified delta $($leaf.RawPath) ($($leaf.ChangeType))$(if ($Stage -eq 'post') { ', still there in the second check' })"
            } elseif ($wantDeploy) {
              $changeRecords += New-ChangeRecord $leaf 'allowed by -AllowModify'
            } else {
              # A dry run never passes a change. It shows what the approved deploy run would write.
              if ($verdict -eq 'pass') { $verdict = 'review' }
              $changeRecords += New-ChangeRecord $leaf 'would be allowed with -AllowModify'
            }
          } elseif ($b.onDeploy -eq 'review') {
            if ($AcknowledgeReview -or $Drift) { $notes += "review boundary accepted: $($leaf.RawPath)" }
            else {
              if ($verdict -eq 'pass') { $verdict = 'review' }
              $bn = Get-Prop $b 'note'
              $notes += "review boundary $($leaf.RawPath) ($($leaf.ChangeType)): $bn"
            }
            if ($named) { $changeRecords += New-ChangeRecord $leaf 'review boundary' }
          } elseif ($named) {
            $changeRecords += New-ChangeRecord $leaf 'listed boundary'
          }
        }
      }
      default { $verdict = 'fail'; $notes += "change type $ct is never allowed" }
    }

    # A data-access change is one Contributor can write and that changes who can read or manage the data inside a
    # resource, so a person must read it. With the access policy permission model, a Key Vault access policy,
    # written as a resource of its own or in the list of a new vault, grants the identities it names access to the
    # vault's keys, secrets and certificates. The change becomes a review record on top of the verdict above, so
    # -AllowCreate and -AllowModify never pass it alone, and a Create still needs -AllowCreate.
    if (@('NoChange', 'Ignore', 'NoEffect') -notcontains $ct) {
      if ($type -eq 'Microsoft.KeyVault/vaults/accessPolicies') {
        $dataWhy = "This $ct of a Key Vault access policy changes who can read or manage the vault's keys, secrets and certificates"
      } elseif (@($dataGrantTypes | Where-Object { $type -like $_ }).Count -gt 0) {
        $dataWhy = "This $ct of a $type changes who can read or manage the data of the resource it belongs to"
      } elseif ($type -eq 'Microsoft.KeyVault/vaults' -and $ct -eq 'Create' -and $null -ne (Get-Prop (Get-Prop (Get-Prop $ch 'after') 'properties') 'accessPolicies')) {
        $dataWhy = "This Create of a Key Vault carries access policies, which grant the identities they name access to the vault's keys, secrets and certificates"
      }
    }
    if ($dataWhy) { $reviewWhy = "data-access change. $dataWhy, so check which identities gain or lose which permissions" }

    # A person must read a record the preview could not judge, and a data-access change. It stops the run as a review boundary
    # does, -AcknowledgeReview accepts it, and a drift check reports it without failing.
    if ($reviewWhy) {
      if ($Drift) { $rstate = 'reported by the drift check'; $notes += "review record, reported (not a drift finding): $reviewWhy" }
      elseif ($AcknowledgeReview) { $rstate = 'acknowledged with -AcknowledgeReview'; $notes += "review record acknowledged with -AcknowledgeReview: $reviewWhy" }
      else {
        $rstate = 'waiting for -AcknowledgeReview'
        if ($verdict -eq 'pass') { $verdict = 'review' }
        $notes += "review record: $reviewWhy. Find out what it writes before passing -AcknowledgeReview"
      }
      $reviewRecords += [pscustomobject]@{ resourceId = $id; changeType = $ct; reason = $reviewWhy; status = $rstate }
    }

    if ($ct -ne 'Ignore' -and $ct -ne 'Deploy') {
      $h = Find-Hold $holds $id $type $nameChain
      if ($null -ne $h) {
        if ($allowHeldSet.Contains($idl)) { $notes += 'hold lifted by -AllowHeld' }
        elseif ($Drift) { $notes += 'held for deployment (not a drift finding)' }
        else { $verdict = 'fail'; $notes += "held: $($h.reason)" }
      }
    }
    foreach ($cr in $changeRecords) { $notes += $cr.Note }
    $dec = [pscustomobject]@{ resourceId = $id; type = $type; changeType = $ct; verdict = $verdict; notes = $notes }
    # Only a resource named in -AllowModify carries the list of its changed properties, so the gate
    # JSON of a run without it keeps its shape.
    if ($named -and $ct -eq 'Modify') { $dec | Add-Member -NotePropertyName 'propertyChanges' -NotePropertyValue @($changeRecords | ForEach-Object { $_.Record }) }
    $decisions += $dec
  }

  # Drift of a unit that declares its subscription's resource groups. A subscription preview has one record per group
  # the template declares, with the group's own ID, so a live group with no record is declared nowhere and nothing in
  # it is measured. Each one fails as a record of its own, with the result NoRecord, which what-if never gives.
  if ($null -ne $liveGroups) {
    $seenIds = New-IdSet @($decisions | ForEach-Object { $_.resourceId })
    foreach ($g in @($liveGroups)) {
      if ([string]::IsNullOrWhiteSpace($g)) { continue }
      $gid = "/subscriptions/$subId/resourceGroups/$g"
      if ($seenIds.Contains($gid.ToLowerInvariant())) { continue }
      $decisions += [pscustomobject]@{ resourceId = $gid; type = 'Microsoft.Resources/resourceGroups'; changeType = 'NoRecord'; verdict = 'fail'; notes = @('live resource group with no record in the preview, so the code declares neither it nor anything in it. Declare it with its resources, or remove it under a change ticket') }
    }
  }

  # In the second check, a resource the first check let through must still be in the preview.
  if (@($mustBePresent).Count -gt 0) {
    $seen = New-IdSet @($decisions | ForEach-Object { $_.resourceId })
    foreach ($m in $mustBePresent) {
      if (-not $seen.Contains($m.ToLowerInvariant())) { $problems += "$m was allowed by the first check but has no record in this preview" }
    }
  }

  $count = @{}
  foreach ($d in $decisions) { if ($count.ContainsKey($d.changeType)) { $count[$d.changeType]++ } else { $count[$d.changeType] = 1 } }
  $fails = @($decisions | Where-Object { $_.verdict -eq 'fail' }).Count
  $reviews = @($decisions | Where-Object { $_.verdict -eq 'review' }).Count
  $overall = 'pass'
  if ($reviews -gt 0) { $overall = 'review' }
  if ($fails -gt 0 -or $problems.Count -gt 0) { $overall = 'fail' }
  $result = [pscustomobject]@{ overall = $overall; problems = $problems; counts = $count; failed = $fails; review = $reviews; decisions = $decisions }
  # Only a preview with review records carries the list, so the gate JSON of any other preview keeps its shape.
  if ($reviewRecords.Count -gt 0) { $result | Add-Member -NotePropertyName 'reviewRecords' -NotePropertyValue @($reviewRecords) }
  return $result
}

function Write-Evidence([string]$dir, [string]$label, $gate, [hashtable]$context) {
  # Depth 30 keeps whole property values (propertyChanges) in the JSON.
  $gate | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $dir "$label-gate.json") -Encoding $utf8Bom
  $lines = @()
  $lines += "Unit:       $($context.unit)"
  $lines += "Scope:      $($context.scope)"
  $lines += "Commit:     $($context.commit)$(if ($context.dirty) { ' (working tree has uncommitted changes)' })"
  $lines += "Identity:   $($context.identity)"
  $lines += "Taken:      $($context.time)"
  $lines += "Mode:       $($context.mode)"
  if ($context.ContainsKey('bicep')) { $lines += "Bicep:      $($context.bicep)" }
  # The approval lists, only when given. The second check is judged without -AllowCreate and -AllowModify.
  if ($label -eq 'post') {
    $lines += 'Judged:     second check, without -AllowCreate and -AllowModify'
  } else {
    foreach ($x in $AllowCreate) { $lines += "AllowCreate: $x" }
    foreach ($x in $AllowModify) {
      $hit = @($gate.decisions | Where-Object { $_.changeType -eq 'Modify' -and (Test-SameId $_.resourceId $x) }).Count -gt 0
      $lines += "AllowModify: $x$(if (-not $hit) { '  (no Modify record for it in this preview)' })"
    }
  }
  foreach ($x in $AllowHeld) { $lines += "AllowHeld:  $x" }
  $lines += "Gate:       $($gate.overall.ToUpperInvariant())"
  $lines += "Counts:     " + (($gate.counts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '  ')
  foreach ($p in $gate.problems) { $lines += "Problem:    $p" }
  foreach ($r in @(Get-Prop $gate 'reviewRecords')) {
    if ($null -eq $r) { continue }
    $lines += "Review record: $($r.changeType) $($r.resourceId) ($($r.status))$(if ([string]$r.reason -like 'data-access change*') { ', data-access change' })"
  }
  $lines += ''
  # An -AllowCreate ID with no Create record, or an -AllowHeld ID that lifted no hold, is noted at the top of the body,
  # as the header notes an -AllowModify ID with no Modify record. The header itself keeps one ID per line, as the
  # approval checks read it.
  if ($label -ne 'post') {
    foreach ($x in $AllowCreate) {
      if (@($gate.decisions | Where-Object { $_.changeType -eq 'Create' -and (Test-SameId $_.resourceId $x) }).Count -eq 0) { $lines += "NOTE    -AllowCreate $x has no Create record in this preview" }
    }
  }
  foreach ($x in $AllowHeld) {
    if (@($gate.decisions | Where-Object { (Test-SameId $_.resourceId $x) -and @($_.notes) -contains 'hold lifted by -AllowHeld' }).Count -eq 0) { $lines += "NOTE    -AllowHeld $x lifts no hold in this preview" }
  }
  # A clean NoChange is left out, unless a hold was lifted for it, because the lifted hold belongs in the summary.
  foreach ($d in ($gate.decisions | Where-Object { $_.changeType -ne 'NoChange' -or $_.verdict -ne 'pass' -or @($_.notes) -contains 'hold lifted by -AllowHeld' })) {
    $lines += ("{0,-7} {1,-8} {2}" -f $d.verdict.ToUpperInvariant(), $d.changeType, $d.resourceId)
    foreach ($n in $d.notes) { $lines += "                 $n" }
  }
  $path = Join-Path $dir "$label-summary.txt"
  Set-Content -LiteralPath $path -Value $lines -Encoding $utf8Bom
  return $path
}

# ---------------------------------------------------------------------------------------------
# 1. Allowlist
# ---------------------------------------------------------------------------------------------
# A request names resources by ID, so each ID must be one Azure can return: no control or invisible character (a
# zero-width space or a line break among them), no space other than the plain one, and no slash at its end. It is
# the rule the lists of a deployment request follow (Test-IdList in .github/scripts/mirror-pipeline.ps1). The soft hyphen
# (U+00AD) is named as well, because Windows PowerShell 5.1 counts it as a dash, not as an invisible character.
foreach ($pair in @(@('-AllowCreate', $AllowCreate), @('-AllowModify', $AllowModify), @('-AllowHeld', $AllowHeld))) {
  foreach ($x in @($pair[1])) {
    if ($x -match '\p{C}|[\p{Z}-[\x20]]|\u00AD' -or $x.EndsWith('/')) { Fail 2 "$($pair[0]) entry '$x' holds a control or invisible character or a space other than the plain one, or ends with a slash$(Get-RefusedIdCharNote $x)" }
  }
}
if (-not (Test-Path -LiteralPath $unitsPath)) { Fail 2 "missing $unitsPath" }
if (-not (Test-Path -LiteralPath $boundariesPath)) { Fail 2 "missing $boundariesPath" }
$udoc = ConvertFrom-JsonText (Read-TextFile $unitsPath)
$bdoc = ConvertFrom-JsonText (Read-TextFile $boundariesPath)
# A boundary the gate cannot read the way it was meant would pass changes silently (an onDeploy spelled "reveiw"
# would count as inert), so every boundary needs a type, a path, a list of change types and an onDeploy of exactly
# inert or review.
if (-not (Test-ArrayProp $bdoc 'boundaries')) { Fail 2 'deploy/boundaries.json has no boundaries list' }
$bi = 0
foreach ($b in @($bdoc.boundaries)) {
  $bi++
  $od = [string](Get-Prop $b 'onDeploy')
  $ok = $null -ne $b -and [string](Get-Prop $b 'type') -and [string](Get-Prop $b 'path') -and (Test-ArrayProp $b 'changeTypes') -and
        @(@(Get-Prop $b 'changeTypes') | Where-Object { $_ -is [string] -and $_ }).Count -gt 0 -and
        ([string]::Equals($od, 'inert', [StringComparison]::Ordinal) -or [string]::Equals($od, 'review', [StringComparison]::Ordinal))
  if (-not $ok) { Fail 2 "deploy/boundaries.json, boundary $bi (type '$(Get-Prop $b 'type')', path '$(Get-Prop $b 'path')', onDeploy '$od'). A boundary needs a type, a path, a non-empty changeTypes list and an onDeploy of exactly inert or review" }
}
$unitDef = @($udoc.units | Where-Object { Test-SameName ([string]$_.name) $Unit })
if ($unitDef.Count -eq 0) {
  $near = Get-CaseOnlyMatch $Unit
  if ($near) { Fail 2 "no unit named '$Unit' in deploy/units.json. Did you mean $($near)? Unit names are matched with their exact case." }
}
if ($unitDef.Count -ne 1) { Fail 2 "unit '$Unit' is not in deploy/units.json$(Get-HiddenCharNote $Unit)" }
$unitDef = $unitDef[0]
# An offline evaluation calls no Azure and never deploys, so it may judge a saved what-if of a disabled unit.
if (-not $unitDef.enabled -and -not $offline) { Fail 2 "unit '$Unit' is disabled in units.json: $($unitDef.notes)" }
if ($unitDef.kind -eq 'tenant') { Fail 2 'tenant-scope units are deployed by hand under their own approval, so this script does not run them' }
$unitSub = [string](Get-Prop $unitDef 'subscription')
if (-not $unitSub) { Fail 2 "unit '$Unit' has no subscription in deploy/units.json" }
$subId = Get-Prop $udoc.subscriptions $unitSub
if (-not $subId) { Fail 2 "subscription '$unitSub' is not in the allowlist" }

$template = Join-Path $repo $unitDef.template
$paramFile = $null
if ($unitDef.parameters) { $paramFile = Join-Path $repo $unitDef.parameters }
foreach ($f in @($template, $paramFile)) { if ($f -and -not (Test-Path -LiteralPath $f)) { Fail 2 "missing unit file $f" } }

$wantDeploy = (-not $DryRun) -and $Approve
if ((-not $DryRun) -and -not $wantDeploy) { Fail 2 '-DryRun:$false also needs -Approve' }
# The approval of a change names the resources and the dry run that showed the change, so the deploy
# run can be held to exactly what was approved.
if ($wantDeploy -and $AllowModify.Count -gt 0 -and -not $ApprovedChanges) { Fail 2 '-AllowModify on a deploy run needs -ApprovedChanges (the pre-gate.json of the approved dry run)' }
if ($ApprovedChanges -and -not ($wantDeploy -and $AllowModify.Count -gt 0)) { Fail 2 '-ApprovedChanges is used only by a deploy run with -AllowModify (-DryRun:$false -Approve)' }

# The Azure CLI takes a .bicepparam file only once in --parameters, so overrides cannot be added beside one.
$ov = Get-Prop $unitDef 'parameterOverrides'
if ($null -ne $ov -and @($ov.PSObject.Properties).Count -gt 0 -and $paramFile -and $paramFile -like '*.bicepparam') {
  Fail 2 "unit '$Unit' has parameterOverrides and a .bicepparam parameters file. The Azure CLI accepts a .bicepparam file only once in --parameters, so set those values in the .bicepparam file instead (for example with readEnvironmentVariable)"
}

# ---------------------------------------------------------------------------------------------
# Provenance and evidence folder
# ---------------------------------------------------------------------------------------------
# The commit and the uncommitted changes that decide what is deployed: the unit folders and the bicepconfig.json at
# the root, which changes how every file compiles. When the commit can be read but git status fails (a damaged
# index, for example), the tree counts as uncommitted, because nothing shows it is committed. Without git, or
# outside a working copy, the commit is empty and a deploy run stops on it.
function Get-TreeState {
  $c = ''; $d = ''
  if ($null -eq (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return [pscustomobject]@{ commit = $c; dirtyList = $d } }
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try {
    $out = (& git -C $repo rev-parse HEAD 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -eq 0) { $c = $out }
    $d = (& git -C $repo status --porcelain -- 'infra' 'deploy' 'pipelines' 'scripts' 'bicepconfig.json' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { $d = if ($c) { "git status failed (exit $LASTEXITCODE), so the tree cannot be shown to be committed" } else { '' } }
  } finally { $ErrorActionPreference = $prevEap }
  return [pscustomobject]@{ commit = $c; dirtyList = $d }
}
$tree = Get-TreeState
$commit = $tree.commit
$dirtyList = $tree.dirtyList
if (-not $commit) { $commit = 'unknown' }
$short = if ($commit.Length -ge 7) { $commit.Substring(0, 7) } else { $commit }
$dirty = [bool]$dirtyList
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$evidence = Join-Path $EvidenceRoot (Join-Path $Unit "$stamp-$short")
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
$scopeText = if ($unitDef.kind -eq 'resourceGroup') { "$subId / $($unitDef.resourceGroup)" } else { "subscription $subId" }
$context = @{ unit = $Unit; scope = $scopeText; commit = $commit; dirty = $dirty; identity = 'not checked (offline)'; time = (Get-Date).ToUniversalTime().ToString('u'); mode = 'offline evaluation' }
if (-not $offline) {
  $context.identity = 'not checked yet'
  $context.mode = if ($wantDeploy) { 'deploy (-Approve)' } elseif ($Drift) { 'drift check' } else { 'dry run' }
}

# A deploy run needs a committed tree. This is checked before the identity, the preview and the gate,
# so a refused run does not first show a gate result for code that cannot be deployed. It is checked
# again just before the deployment.
if ($wantDeploy) {
  if ($commit -eq 'unknown') { Fail 2 'cannot read the commit (not a git working copy, no commit yet, or git not on PATH). Put the folder under git and commit before deploying' }
  if ($dirty) { Fail 2 "uncommitted changes under infra, deploy, pipelines or scripts, or in bicepconfig.json. Deploy only from a committed tree:`n$dirtyList" }
}

# The header of the approved dry run (pre-summary.txt beside the pre-gate.json) must name this unit, this
# commit from a committed tree, a dry run and the same -AllowModify, -AllowCreate and -AllowHeld lists. Its
# property changes and review items are compared with this run's after the gate.
$approvedGate = $null
if ($ApprovedChanges) {
  $apGate = $ApprovedChanges
  if (Test-Path -LiteralPath $apGate -PathType Container) { $apGate = Join-Path $apGate 'pre-gate.json' }
  if (-not (Test-Path -LiteralPath $apGate -PathType Leaf)) { Fail 2 "-ApprovedChanges: $apGate not found" }
  $apSum = Join-Path (Split-Path -Parent $apGate) 'pre-summary.txt'
  if (-not (Test-Path -LiteralPath $apSum -PathType Leaf)) { Fail 2 "-ApprovedChanges: no pre-summary.txt beside $apGate, so the dry run's unit and commit cannot be read" }
  Copy-Item -LiteralPath $apGate -Destination (Join-Path $evidence 'approved-changes.json')
  $apHead = @{}
  $apModify = @(); $apCreate = @(); $apHeld = @()
  foreach ($l in @(Get-Content -LiteralPath $apSum -Encoding UTF8)) {
    if ($l -eq '') { break }
    # A resource name may hold spaces. The note after two spaces is not part of the ID, and AllowHeld has two spaces
    # after its colon. The three lists are read as the pipeline's helper reads them (Read-DryRunHeader).
    if ($l -match '^AllowModify: (.+?)(  \(no Modify record for it in this preview\))?$') { $apModify += $Matches[1].ToLowerInvariant(); continue }
    if ($l -match '^AllowCreate: (.+)$') { $apCreate += $Matches[1].ToLowerInvariant(); continue }
    if ($l -match '^AllowHeld:  (.+)$') { $apHeld += $Matches[1].ToLowerInvariant(); continue }
    # The first line of a key counts, so a later line can never replace what the run wrote first.
    if ($l -match '^(\w+):\s+(.*)$' -and -not $apHead.ContainsKey($Matches[1])) { $apHead[$Matches[1]] = $Matches[2].Trim() }
  }
  if (-not (Test-SameName ([string]$apHead['Unit']) $Unit)) { Fail 2 "-ApprovedChanges is the dry run of unit '$($apHead['Unit'])', not '$Unit'" }
  if ([string]$apHead['Mode'] -ne 'dry run') { Fail 2 "-ApprovedChanges was not taken by a dry run (mode '$($apHead['Mode'])'). Approve the pre-gate.json of a dry run of this unit" }
  if ([string]$apHead['Commit'] -like '*uncommitted*') { Fail 2 '-ApprovedChanges was taken from a working tree with uncommitted changes. Take the dry run again from the committed tree' }
  if ([string]$apHead['Commit'] -ne $commit) { Fail 2 "-ApprovedChanges was taken at commit $($apHead['Commit']), not $commit. Take the dry run again at this commit and approve that" }
  if (@('REVIEW', 'PASS') -notcontains [string]$apHead['Gate']) { Fail 2 "-ApprovedChanges ended with gate $($apHead['Gate']), and only a dry run that ended REVIEW or PASS can be approved" }
  # The three lists must be the dry run's, so a deploy run cannot add a resource to create or lift a hold that the
  # approver never saw. Each list is compared once each in ordinal order, case aside, as the IDs are matched.
  foreach ($pair in @(@('-AllowModify', $AllowModify, $apModify), @('-AllowCreate', $AllowCreate, $apCreate), @('-AllowHeld', $AllowHeld, $apHeld))) {
    $nowList = Get-OrdinalSorted @(@($pair[1]) | ForEach-Object { $_.ToLowerInvariant() })
    $wasList = Get-OrdinalSorted @($pair[2])
    if (-not [string]::Equals(($nowList -join "`n"), ($wasList -join "`n"), [StringComparison]::Ordinal)) { Fail 2 "$($pair[0]) differs from the approved dry run's list:`n  dry run: $($wasList -join ', ')`n  now:     $($nowList -join ', ')" }
  }
  $approvedGate = ConvertFrom-JsonText (Read-TextFile $apGate)
}

# ---------------------------------------------------------------------------------------------
# Offline. Evaluate a saved what-if and stop
# ---------------------------------------------------------------------------------------------
if ($offline) {
  $parsed = @()
  $n = 0
  foreach ($wf in $WhatIfJson) {
    if (-not (Test-Path -LiteralPath $wf)) { Fail 2 "missing $wf" }
    $n++
    Copy-Item -LiteralPath $wf -Destination (Join-Path $evidence "pre-whatif-$n.json")
    $parsed += , (ConvertFrom-JsonText (Read-TextFile $wf))
  }
  $wi = if ($parsed.Count -eq 1) { $parsed[0] } else { Merge-WhatIf $parsed }
  $gate = Test-WhatIf $wi $unitDef $subId $bdoc
  $sum = Write-Evidence $evidence 'pre' $gate $context
  Get-Content -LiteralPath $sum | Write-Host
  Info "Evidence: $evidence"
  if ($Drift -and @($gate.problems).Count -gt 0) { Fail 2 $driftProblemMsg }
  if ($gate.overall -eq 'pass') { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------------------------------------
# 2. Identity
# ---------------------------------------------------------------------------------------------
function Assert-Identity {
  # Checked for the unit's own subscription, because the CLI default may be another sign-in.
  $acct = ConvertFrom-JsonText (Invoke-Az @('account', 'show', '--subscription', $subId, '-o', 'json')).Out
  $u = Get-Prop $acct 'user'
  $name = [string](Get-Prop $u 'name'); $type = [string](Get-Prop $u 'type')
  if ((Get-Prop $acct 'tenantId') -ne $udoc.tenantId) { Fail 2 "signed in to tenant $(Get-Prop $acct 'tenantId'), expected $($udoc.tenantId)" }
  # Account names and types are matched without case, character by character (Test-SameName says why).
  $ok = @($udoc.allowedPrincipals | Where-Object { $_.name -and [string]::Equals([string]$_.type, $type, [StringComparison]::OrdinalIgnoreCase) -and
    [string]::Equals([string]$_.name, $name, [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
  # A pipeline job signs in with the client ID of its environment. The workflow passes that ID in MIRROR_CLIENT_ID, a
  # name of its own so no Azure tool picks it up, and it is not typed again in units.json. The GITHUB_ACTIONS check
  # guards against a mistake on a workstation. It is not a security boundary, because Entra and RBAC decide what the
  # identity can do.
  $job = $type -ieq 'servicePrincipal' -and $env:GITHUB_ACTIONS -ceq 'true' -and -not [string]::IsNullOrWhiteSpace($env:MIRROR_CLIENT_ID) -and
    [string]::Equals($env:MIRROR_CLIENT_ID.Trim(), $name, [StringComparison]::OrdinalIgnoreCase)
  if (-not $ok -and -not $job) {
    if ($type -ieq 'servicePrincipal') { Fail 2 "identity '$name' ($type) is neither in allowedPrincipals nor the client ID of this GitHub Actions job (MIRROR_CLIENT_ID)" }
    Fail 2 "identity '$name' ($type) is not in allowedPrincipals"
  }
  return "$name ($type)"
}
$context.identity = Assert-Identity
Info "Identity ok: $($context.identity)"

# ---------------------------------------------------------------------------------------------
# 3. Compile and repository checks
# ---------------------------------------------------------------------------------------------
# The code is compiled and measured with Bicep 0.48.1, and another release can compile the same files to another
# template. The Azure CLI installs the latest release when it finds no Bicep, so the version it runs is checked before
# the first compile and recorded in the summary. The workflows install and check the same version (BICEP_VERSION).
$bicepWant = '0.48.1'
$bv = Invoke-Az @('bicep', 'version') -AllowFailure
$bvLine = @("$($bv.Out)`n$($bv.Err)" -split "`r?`n" | Where-Object { $_ -match 'version' } | Select-Object -First 1)
$bvm = [regex]::Match([string]$bv.Out, 'version ([0-9][0-9A-Za-z.+-]*)( \(\w+\))?')
if ($bv.Code -ne 0 -or -not $bvm.Success -or -not [string]::Equals($bvm.Groups[1].Value, $bicepWant, [StringComparison]::Ordinal)) {
  Fail 2 "az bicep version reports '$(if ($bvLine.Count) { $bvLine[0].Trim() } else { "nothing (exit $($bv.Code))" })', and this code is compiled with Bicep $bicepWant. Install it with az bicep install --version v$bicepWant"
}
$context.bicep = "$($bvm.Groups[1].Value)$($bvm.Groups[2].Value)"
$build = Invoke-Az @('bicep', 'build', '--file', $template, '--outfile', (Join-Path $evidence 'template.json')) -AllowFailure
Set-Content -LiteralPath (Join-Path $evidence 'build.log') -Value $build.Err -Encoding $utf8Bom
if ($build.Code -ne 0) { Fail 2 "template does not compile. See $(Join-Path $evidence 'build.log')" }
if ($paramFile) {
  $bp = Invoke-Az @('bicep', 'build-params', '--file', $paramFile, '--stdout') -AllowFailure
  if ($bp.Code -ne 0) { Fail 2 "parameters do not compile:`n$($bp.Err)" }
  # The built parameter file is evidence only, because the preview and the deployment read the .bicepparam file itself.
  # A secure input (a @secure() parameter read from an environment variable) is built into it in plain text,
  # so it is built to standard output and its value is replaced in memory, before parameters.json is written.
  $built = ConvertFrom-JsonText $bp.Out
  $builtParams = [string](Get-Prop $built 'parametersJson')
  $builtTemplate = [string](Get-Prop $built 'templateJson')
  if (-not $builtParams) { Fail 2 'az bicep build-params --stdout returned no parametersJson' }
  if (-not $builtTemplate) { $builtTemplate = Read-TextFile (Join-Path $evidence 'template.json') }
  [IO.File]::WriteAllText((Join-Path $evidence 'parameters.json'), (Protect-SecureParameters $builtTemplate $builtParams), (New-Object System.Text.UTF8Encoding $false))
}
Info 'Compile ok'

# Resource group files are edited by hand, so a resource can end up declared twice, in the same file or
# in a module it calls. Azure refuses that deployment (ResourceDeployedMultipleTimes). The check finds
# it first. A unit without a parameters file is checked with the template's parameter defaults.
if (-not $Drift -and $unitDef.kind -in @('subscription', 'resourceGroup')) {
  $dupArgs = @('-Template', $template, '-OutJson', (Join-Path $evidence 'duplicates.json'))
  if ($paramFile) { $dupArgs += @('-Parameters', $paramFile) } else { $dupArgs += '-NoParameters' }
  & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'find-duplicate-declarations.ps1') @dupArgs | Out-Null
  # Exit 1 means duplicates were found. Exit 2 means the check itself could not run (compile or tool error).
  if ($LASTEXITCODE -eq 2) { Fail 2 "duplicate check could not run for $Unit (compile or tool error). Run scripts/find-duplicate-declarations.ps1 by hand to see why" }
  if ($LASTEXITCODE -ne 0) { Fail 2 "duplicate declarations in $Unit (ResourceDeployedMultipleTimes). See $(Join-Path $evidence 'duplicates.json')" }
  Info 'No duplicate declarations'
}

# Overrides go through files so cmd.exe quoting (az is a .cmd on Windows) never sees JSON.
$overrideArgs = @()
if ($null -ne $ov) {
  foreach ($p in $ov.PSObject.Properties) {
    $vf = Join-Path $evidence "override-$($p.Name).json"
    $vj = ConvertTo-Json -InputObject @($p.Value) -Depth 10 -Compress
    if ($p.Value -isnot [System.Array]) { $vj = ConvertTo-Json -InputObject $p.Value -Depth 10 -Compress }
    [IO.File]::WriteAllText($vf, $vj, (New-Object System.Text.UTF8Encoding $false))
    $overrideArgs += @('--parameters', "$($p.Name)=@$vf")
  }
}

function Get-ScopeArgs {
  if ($unitDef.kind -eq 'resourceGroup') { return @('group', '--subscription', $subId, '--resource-group', $unitDef.resourceGroup) }
  return @('sub', '--subscription', $subId, '--location', $udoc.deploymentLocation)
}
function Get-SourceArgs([string]$tpl, [string]$prm, [string[]]$extra) {
  if ($prm) { return @('--parameters', $prm) + $extra }
  return @('--template-file', $tpl) + $extra
}
function Get-SafeName([string]$s) { $n = ($s -replace '[^A-Za-z0-9._()-]', '-'); if ($n.Length -gt 64) { $n = $n.Substring(0, 64) }; return $n }

# $failCode is 2 before the deployment and 3 after it, because a second what-if that cannot run leaves a deployment that
# ran but is not verified, which is a failed deployment.
function Get-WhatIf([string]$name, [string]$tpl, [string]$prm, [string[]]$extra, [string]$file, [int]$failCode = 2) {
  $sa = Get-ScopeArgs
  $azArgs = @('deployment', $sa[0], 'what-if') + $sa[1..($sa.Count - 1)] + @('--name', (Get-SafeName "whatif-$name-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())")) +
            (Get-SourceArgs $tpl $prm $extra) + @('--result-format', 'FullResourcePayloads', '--no-pretty-print', '-o', 'json')
  # Dry runs and drift checks run as a reader, so they skip the write-permission part of preflight.
  # A deploy run keeps the default level, which also proves the deploy identity can write every
  # resource in the unit before anything is sent.
  if (-not $wantDeploy) { $azArgs += @('--validation-level', 'ProviderNoRbac') }
  $r = Invoke-Az $azArgs -AllowFailure
  [IO.File]::WriteAllText((Join-Path $evidence "$file.json"), $r.Out, (New-Object System.Text.UTF8Encoding $false))
  if ($r.Err) { Set-Content -LiteralPath (Join-Path $evidence "$file.err") -Value $r.Err -Encoding $utf8Bom }
  if ($r.Code -ne 0 -or -not $r.Out.Trim()) {
    $msg = "what-if failed (exit $($r.Code)). See $(Join-Path $evidence "$file.err")"
    if ($failCode -eq 3) { $msg = "the deployment ran, but the second what-if could not run, so the result is not verified. $msg. Treat it as a failed deployment. Compare live with the code and roll back as REFERENCE.md describes." }
    Fail $failCode $msg
  }
  return (ConvertFrom-JsonText $r.Out)
}

function Invoke-Gate([string]$label, [int]$failCode = 2, [string[]]$mustBePresent = @()) {
  $results = @(, (Get-WhatIf $Unit $template $paramFile $overrideArgs "$label-whatif" $failCode))
  # Drift measures the whole resource group, so it also takes the sibling files that hold this
  # group's deploy-excluded resources. A deployment never does, because those files are not deployed.
  if ($Drift) {
    foreach ($sib in @(Get-Prop $unitDef 'measuredWith')) {
      if (-not $sib) { continue }
      $sd = @($udoc.units | Where-Object { Test-SameName ([string]$_.name) ([string]$sib) })[0]
      if ($null -eq $sd) {
        $near = Get-CaseOnlyMatch $sib
        if ($near) { Fail 2 "measuredWith of unit '$Unit' names '$sib', and there is no unit named '$sib' in deploy/units.json. Did you mean $($near)? Unit names are matched with their exact case." }
        Fail 2 "measuredWith names unknown unit $sib$(Get-HiddenCharNote ([string]$sib))"
      }
      $sp = $null; if ($sd.parameters) { $sp = Join-Path $repo $sd.parameters }
      $results += , (Get-WhatIf $sib (Join-Path $repo $sd.template) $sp @() "$label-whatif-$sib")
    }
  }
  # The live resource groups, for the drift check of a unit that declares them. The list is kept in the evidence as
  # <label>-groups.json. A list that fails is an error (exit 2), because the groups were not compared.
  $liveGroups = $null
  if ($Drift -and (Test-DeclaresResourceGroups $unitDef)) {
    $gl = Invoke-Az @('group', 'list', '--subscription', $subId, '--query', '[].name', '-o', 'json') -AllowFailure
    [IO.File]::WriteAllText((Join-Path $evidence "$label-groups.json"), $gl.Out, (New-Object System.Text.UTF8Encoding $false))
    if ($gl.Code -ne 0) { Fail 2 "az group list failed (exit $($gl.Code)), so the live resource groups were not compared with the preview:`n$($gl.Err)" }
    $liveGroups = [string[]]@(@(ConvertFrom-JsonText $gl.Out) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
  }
  $wi = if ($results.Count -eq 1) { $results[0] } else { Merge-WhatIf $results }
  $gate = Test-WhatIf $wi $unitDef $subId $bdoc $label $mustBePresent $liveGroups
  $sum = Write-Evidence $evidence $label $gate $context
  Get-Content -LiteralPath $sum | Write-Host
  return $gate
}

# ---------------------------------------------------------------------------------------------
# 4-6. What-if, gate, evidence
# ---------------------------------------------------------------------------------------------
if ($unitDef.kind -eq 'resourceGroup') {
  $rgCheck = Invoke-Az @('group', 'show', '--subscription', $subId, '--name', $unitDef.resourceGroup, '-o', 'json') -AllowFailure
  if ($rgCheck.Code -ne 0) { Fail 2 "resource group $($unitDef.resourceGroup) not found, and a mirror deployment never creates one" }
}
$pre = Invoke-Gate 'pre'
Info "Evidence: $evidence"
if ($Drift) {
  if (@($pre.problems).Count -gt 0) { Fail 2 $driftProblemMsg }
  if ($pre.overall -ne 'pass') { Fail 1 'drift found (the FAIL records above), so nothing was deployed' }
  Info 'No drift found. Drift check, so nothing was deployed.'; exit 0
}
if ($pre.overall -eq 'review') {
  $wouldModify = @($pre.decisions | Where-Object { @($_.notes) -like '*; would be allowed with -AllowModify' })
  # Only a boundary still waiting for -AcknowledgeReview. An accepted one has the note 'review boundary accepted: ...'.
  $reviewBoundary = @($pre.decisions | Where-Object { $_.verdict -eq 'review' -and @(@($_.notes) | Where-Object { $_ -like 'review boundary *' -and $_ -notlike 'review boundary accepted:*' }).Count -gt 0 })
  $why = @()
  # Each reason is a sentence of its own.
  if ($wouldModify.Count -gt 0) { $why += "$($wouldModify.Count) resource(s) named in -AllowModify would change as listed above. A dry run never writes them, so rerun with -DryRun:`$false -Approve -ApprovedChanges $(Join-Path $evidence 'pre-gate.json') once the change is approved." }
  if ($reviewBoundary.Count -gt 0) { $why += 'The gate stopped on review boundaries. Read the notes above, then rerun with -AcknowledgeReview if the IT approver accepts them.' }
  $dataAccess = @($pre.decisions | Where-Object { $_.verdict -eq 'review' -and @(@($_.notes) | Where-Object { $_ -like 'review record: data-access change*' }).Count -gt 0 })
  if ($dataAccess.Count -gt 0) { $why += "The gate stopped on $($dataAccess.Count) data-access change(s), records that change who can read or manage the data inside a resource (a Key Vault access policy, for example). Check which identities gain or lose which permissions, then rerun with -AcknowledgeReview if the IT approver accepts them." }
  $reviewRecord = @($pre.decisions | Where-Object { $_.verdict -eq 'review' -and @(@($_.notes) | Where-Object { $_ -like 'review record: *' -and $_ -notlike 'review record: data-access change*' }).Count -gt 0 })
  if ($reviewRecord.Count -gt 0) { $why += "The gate stopped on $($reviewRecord.Count) review record(s) the preview could not judge (a Deploy record of a nested deployment, or a Modify that lists no changed property). Find out what each writes, then rerun with -AcknowledgeReview if the IT approver accepts them." }
  Fail 1 ($why -join ' ')
}
if ($pre.overall -ne 'pass') { Fail 1 'gate failed, so nothing was deployed' }
if (-not $wantDeploy) { Info 'Gate passed. Dry run, so nothing was deployed.'; exit 0 }

# The changes this run is about to allow by -AllowModify must be exactly those the approved dry run showed
# as "would be allowed with -AllowModify", with the same resource, path, change type and value before and after.
# A change made in the estate since the dry run, or one the dry run showed and that is gone, stops the run.
# The values are written in one canonical form, so that a dry run under Windows PowerShell 5.1 and a deploy run
# under PowerShell 7 (or the other way round) compare equal. Strings are escaped the same way, and every number
# is compared as a double-precision value, written as a whole number up to 2^53 and with 17 significant digits
# otherwise (-0 counts as 0). Two numbers that round to the same double-precision value, such as whole numbers
# above 2^53 one apart, therefore compare equal. Windows PowerShell 5.1 reads some numbers of 16 or 17
# significant digits slightly off the exact value, so such a number approved under 5.1 and checked under
# PowerShell 7 stops the run, as a changed value does.
function ConvertTo-CanonString([string]$s) {
  $sb = New-Object System.Text.StringBuilder
  $null = $sb.Append('"')
  foreach ($ch in $s.ToCharArray()) {
    $c = [int]$ch
    if ($c -eq 0x22) { $null = $sb.Append('\"') }
    elseif ($c -eq 0x5C) { $null = $sb.Append('\\') }
    elseif ($c -lt 0x20) { $null = $sb.Append(('\u{0:x4}' -f $c)) }
    else { $null = $sb.Append($ch) }
  }
  $null = $sb.Append('"')
  return $sb.ToString()
}
function ConvertTo-CanonJson($v) {
  $inv = [Globalization.CultureInfo]::InvariantCulture
  if ($null -eq $v) { return 'null' }
  if ($v -is [string]) { return (ConvertTo-CanonString $v) }
  if ($v -is [bool]) { if ($v) { return 'true' } else { return 'false' } }
  if ($v -is [byte] -or $v -is [int16] -or $v -is [int] -or $v -is [long] -or $v -is [decimal] -or $v -is [double] -or $v -is [single] -or $v.GetType().FullName -eq 'System.Numerics.BigInteger') {
    $t = if ($v -is [double] -or $v -is [single]) { ([double]$v).ToString('R', $inv) } else { ([IFormattable]$v).ToString($null, $inv) }
    $d = [double]::Parse($t, [Globalization.NumberStyles]::Float, $inv) + 0.0
    if ([Math]::Floor($d) -eq $d -and [Math]::Abs($d) -le 9007199254740992.0) { return ([long]$d).ToString($inv) }
    return $d.ToString('E16', $inv)
  }
  if ($v -is [Collections.IList]) { return '[' + ((@($v) | ForEach-Object { ConvertTo-CanonJson $_ }) -join ',') + ']' }
  if ($v -is [Management.Automation.PSCustomObject]) { return '{' + ((@($v.PSObject.Properties) | ForEach-Object { (ConvertTo-CanonString $_.Name) + ':' + (ConvertTo-CanonJson $_.Value) }) -join ',') + '}' }
  return (ConvertTo-Json -InputObject $v -Depth 30 -Compress)
}
function Get-ApprovalKeys($gate, [string]$decision) {
  $keys = @()
  foreach ($d in @($gate.decisions)) {
    foreach ($c in @(Get-Prop $d 'propertyChanges')) {
      if ($null -eq $c -or [string](Get-Prop $c 'decision') -ne $decision) { continue }
      $keys += ('{0} | {1} ({2}): before {3}, after {4}' -f ([string]$d.resourceId).ToLowerInvariant(), (Get-Prop $c 'path'), (Get-Prop $c 'propertyChangeType'),
        (ConvertTo-CanonJson (Get-Prop $c 'before')), (ConvertTo-CanonJson (Get-Prop $c 'after')))
    }
  }
  $sorted = [string[]]@($keys)
  [Array]::Sort($sorted, [StringComparer]::Ordinal)
  return , $sorted
}
# The review items of a gate result, as keys. A review boundary is 'boundary | <id> | <path>' and a review record
# 'record | <id> | <change type>', the keys Get-AcceptedReviewItems in .github/scripts/mirror-pipeline.ps1 builds, so
# the pipeline's comparison and this one find the same items. With -AcceptedOnly, only the items the run accepted with
# -AcknowledgeReview. Without it, every item the run showed, accepted or still waiting for the switch.
function Get-ReviewItemKeys($gate, [switch]$AcceptedOnly) {
  $keys = @()
  foreach ($d in @($gate.decisions)) {
    if ($null -eq $d) { continue }
    $rid = ([string](Get-Prop $d 'resourceId')).ToLowerInvariant()
    foreach ($n in @(Get-Prop $d 'notes')) {
      $m = [regex]::Match([string]$n, '^review boundary accepted: (.+)$')
      if ($m.Success) { $keys += "boundary | $rid | $($m.Groups[1].Value)"; continue }
      if ($AcceptedOnly) { continue }
      $m = [regex]::Match([string]$n, '^review boundary (.+?) \(\w+\): ')
      if ($m.Success) { $keys += "boundary | $rid | $($m.Groups[1].Value)" }
    }
  }
  foreach ($r in @(Get-Prop $gate 'reviewRecords')) {
    if ($null -eq $r) { continue }
    if ($AcceptedOnly -and [string](Get-Prop $r 'status') -ne 'acknowledged with -AcknowledgeReview') { continue }
    $keys += ('record | {0} | {1}' -f ([string](Get-Prop $r 'resourceId')).ToLowerInvariant(), [string](Get-Prop $r 'changeType'))
  }
  $sorted = Get-OrdinalSorted $keys
  return , $sorted
}
if ($null -ne $approvedGate) {
  $want = Get-ApprovalKeys $approvedGate 'would be allowed with -AllowModify'
  $have = Get-ApprovalKeys $pre 'allowed by -AllowModify'
  if (-not [string]::Equals(($want -join "`n"), ($have -join "`n"), [StringComparison]::Ordinal)) {
    $wantSet = New-OrdinalSet $want
    $haveSet = New-OrdinalSet $have
    $notShown = @($have | Where-Object { -not $wantSet.Contains($_) })
    $gone = @($want | Where-Object { -not $haveSet.Contains($_) })
    $diff = @("Approved dry run: $ApprovedChanges", "Changes this deploy run would allow: $($have.Count)", "Changes the dry run showed: $($want.Count)", '')
    $diff += 'Not shown by the approved dry run:'
    $diff += @($notShown | ForEach-Object { "  $_" })
    $diff += 'Shown by the approved dry run, not found now:'
    $diff += @($gone | ForEach-Object { "  $_" })
    Set-Content -LiteralPath (Join-Path $evidence 'approved-changes-diff.txt') -Value $diff -Encoding $utf8Bom
    $diff | Write-Host
    Fail 1 "the changes this deploy run would allow differ from the approved dry run ($($notShown.Count) not shown by it, $($gone.Count) shown by it and not found now, listed in $(Join-Path $evidence 'approved-changes-diff.txt')). Nothing was deployed. Take a new dry run and have it approved"
  }
  Info "The changes match the approved dry run ($($have.Count) property change(s))"
  # The review items this run accepts with -AcknowledgeReview must be ones the approved dry run showed, accepted or
  # waiting for the switch. A review item that appeared since the dry run (a new review boundary, a new data-access
  # change) stops the run, as the pipeline's review check does before the gate step (Compare-ReviewItems in
  # .github/scripts/mirror-pipeline.ps1).
  $shown = New-OrdinalSet (Get-ReviewItemKeys $approvedGate)
  $extraReview = @((Get-ReviewItemKeys $pre -AcceptedOnly) | Where-Object { -not $shown.Contains($_) })
  if ($extraReview.Count -gt 0) {
    $diff = @("Approved dry run: $ApprovedChanges", '', 'Review items acknowledged by this deploy run that the approved dry run did not show:') + @($extraReview | ForEach-Object { "  $_" })
    Set-Content -LiteralPath (Join-Path $evidence 'approved-changes-diff.txt') -Value $diff -Encoding $utf8Bom
    $diff | Write-Host
    Fail 1 "this deploy run acknowledges $($extraReview.Count) review item(s) the approved dry run did not show (listed in $(Join-Path $evidence 'approved-changes-diff.txt')). Nothing was deployed. Take a new dry run and have it approved"
  }
  Info "Every acknowledged review item was shown by the approved dry run"
}

# ---------------------------------------------------------------------------------------------
# Deployment (only reached with -DryRun:$false -Approve and a passing gate)
# ---------------------------------------------------------------------------------------------
# The tree was clean before the preview. Check that nothing changed it while the preview ran.
$tree = Get-TreeState
$commitNow = $tree.commit
$dirtyList = $tree.dirtyList
if ($commitNow -ne $commit) { Fail 2 "the commit changed from $commit to $commitNow while the preview ran. Start again" }
if ($dirtyList) { Fail 2 "uncommitted changes under infra, deploy, pipelines or scripts, or in bicepconfig.json, appeared while the preview ran. Deploy only from a committed tree:`n$dirtyList" }
$context.identity = Assert-Identity

# A deployment is still running in every state but the four final ones (Accepted, Running and Deleting among
# them). Each state is compared character by character, case aside.
$stateQuery = '[].{n:name,s:properties.provisioningState}'
if ($unitDef.kind -eq 'resourceGroup') {
  $listed = Invoke-Az @('deployment', 'group', 'list', '--subscription', $subId, '--resource-group', $unitDef.resourceGroup, '--query', $stateQuery, '-o', 'json')
} else {
  $listed = Invoke-Az @('deployment', 'sub', 'list', '--subscription', $subId, '--query', $stateQuery, '-o', 'json')
}
$finalStates = @('Succeeded', 'Failed', 'Canceled', 'Deleted')
$running = @(@(ConvertFrom-JsonText $listed.Out) | Where-Object { $null -ne $_ } | Where-Object {
  $s = [string](Get-Prop $_ 's')
  @($finalStates | Where-Object { [string]::Equals($_, $s, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0
} | ForEach-Object { "$(Get-Prop $_ 'n') ($(Get-Prop $_ 's'))" })
if ($running.Count -gt 0) { Fail 2 "another deployment is running at this scope: $($running -join ', ')" }

$deployName = Get-SafeName "mirror-$Unit-$short"
# The account that ran the deployment and the pipeline run it came from (the run and its Review deployments record
# in GitHub name the reviewers), then the approval lists, with one line per resource ID, or "none". The approver is
# not recorded here.
$runRef = if ($env:GITHUB_RUN_ID) { "github run $($env:GITHUB_RUN_ID)" } elseif ($env:BUILD_BUILDID) { "azure devops build $($env:BUILD_BUILDID)" } else { 'local run' }
$approvalLines = @("deploymentName=$deployName", "commit=$commit", "identity=$($context.identity)", "pipelineRun=$runRef")
foreach ($pair in @(@('allowCreate', $AllowCreate), @('allowModify', $AllowModify), @('allowHeld', $AllowHeld))) {
  $ids = @($pair[1])
  if ($ids.Count -eq 0) { $approvalLines += "$($pair[0])=none" } else { foreach ($x in $ids) { $approvalLines += "$($pair[0])=$x" } }
}
$approvalLines += "acknowledgeReview=$([bool]$AcknowledgeReview)"
$approvalLines += "approvedChanges=$(if ($ApprovedChanges) { $ApprovedChanges } else { 'none' })"
$approvalLines += "started=$((Get-Date).ToUniversalTime().ToString('u'))"
$approvalLines | Set-Content -LiteralPath (Join-Path $evidence 'approval.txt') -Encoding $utf8Bom

$sa = Get-ScopeArgs
$createArgs = @('deployment', $sa[0], 'create') + $sa[1..($sa.Count - 1)] + @('--name', $deployName) + (Get-SourceArgs $template $paramFile $overrideArgs) + @('-o', 'json')
# Resource-group deployments take a mode. Subscription deployments are always incremental.
if ($unitDef.kind -eq 'resourceGroup') { $createArgs += @('--mode', 'Incremental') }
Info "Deploying $Unit as $deployName (Incremental)"
$deployStarted = $true
$dep = Invoke-Az $createArgs -AllowFailure
[IO.File]::WriteAllText((Join-Path $evidence 'deployment.json'), $dep.Out, (New-Object System.Text.UTF8Encoding $false))
if ($dep.Err) { Set-Content -LiteralPath (Join-Path $evidence 'deployment.err') -Value $dep.Err -Encoding $utf8Bom }
if ($dep.Code -ne 0) { Fail 3 "deployment $deployName failed. See $(Join-Path $evidence 'deployment.err'), and roll back as REFERENCE.md describes" }
Add-Content -LiteralPath (Join-Path $evidence 'approval.txt') -Value "deployed=$((Get-Date).ToUniversalTime().ToString('u'))" -Encoding $utf8Bom

# The second check is judged without -AllowCreate and -AllowModify (Test-WhatIf, stage 'post'). What they let
# through must now be NoChange, or differ only by listed boundaries, and must still be in the preview.
$letThrough = @($pre.decisions | Where-Object { @($_.notes) -contains 'Create allowed by -AllowCreate' -or @($_.notes) -like '*; allowed by -AllowModify' } | ForEach-Object { $_.resourceId })
$context.time = (Get-Date).ToUniversalTime().ToString('u')
$post = Invoke-Gate 'post' 3 $letThrough
if ($post.overall -ne 'pass') { Fail 3 'post-deployment what-if did not pass the gate. Read the evidence and roll back as REFERENCE.md describes' }
Info "Deployed $Unit; post-deployment what-if passed. Evidence: $evidence"
exit 0
