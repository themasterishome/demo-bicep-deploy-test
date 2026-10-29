<#
.SYNOPSIS
  Offline tests of .github/scripts/mirror-pipeline.ps1. No Azure, no GitHub, no network.

.DESCRIPTION
  Calls the helper's functions with small fixtures (tests/fixtures) and with the repository's own
  deploy/units.json, deploy/boundaries.json and workflow files. One part runs scripts/deploy-unit.ps1 -WhatIfJson
  on a saved what-if, so the helper is checked against the summary and gate files the gate really writes. Another
  part runs the modes of the deploy workflow on a temporary repository, with the GitHub answers recorded.
  Plain PowerShell with no test framework. Each check prints PASS or FAIL, and the script ends with exit 0 only when
  every check passed.

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .github\scripts\tests\mirror-pipeline.tests.ps1

.EXAMPLE
  pwsh -NoProfile -File ./.github/scripts/tests/mirror-pipeline.tests.ps1

.NOTES
  Runs on Windows PowerShell 5.1 and on PowerShell 7 on Windows and Linux. The validate workflow runs it in the
  workflow-hygiene job, on the runner image the repository variable MIRROR_RUNNER chooses, and in the portability
  job, on the other image.
#>
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$fixtures = Join-Path $here 'fixtures'
$helper = Join-Path (Split-Path -Parent $here) 'mirror-pipeline.ps1'
$repo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $here))
# Child scripts start in the same PowerShell as the tests (powershell.exe, or pwsh on Windows or Linux). The
# execution policy exists on Windows only.
$childExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
$childArgs = @('-NoProfile')
if ([IO.Path]::DirectorySeparatorChar -eq '\') { $childArgs += @('-ExecutionPolicy', 'Bypass') }

# The helper writes step outputs and summaries only when these are set. The tests set their own. In the
# workflow-hygiene job the tests run inside the step's own process, so the runner's values are kept and put back
# at the end, also when a test stops with an error.
$script:runnerEnv = @{}
foreach ($v in @('GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY', 'GITHUB_REPOSITORY')) { $script:runnerEnv[$v] = [Environment]::GetEnvironmentVariable($v) }
function Restore-RunnerEnv { foreach ($k in $script:runnerEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $script:runnerEnv[$k]) } }
trap { Restore-RunnerEnv; break }
foreach ($v in @('GITHUB_OUTPUT', 'GITHUB_STEP_SUMMARY')) { [Environment]::SetEnvironmentVariable($v, $null) }
. $helper

$script:failures = 0
$script:passes = 0
function Assert-True([bool]$Condition, [string]$Name) {
  if ($Condition) { $script:passes++; Write-Host "PASS  $Name" }
  else { $script:failures++; Write-Host "FAIL  $Name" -ForegroundColor Red }
}
function Assert-Equal($Expected, $Actual, [string]$Name) {
  $ok = ("$Expected" -ceq "$Actual")
  if (-not $ok) { Write-Host "      expected: $Expected`n      actual:   $Actual" -ForegroundColor Yellow }
  Assert-True $ok $Name
}
function Assert-Contains([string[]]$List, [string]$Pattern, [string]$Name) {
  $hit = @(@($List) | Where-Object { $_ -like $Pattern }).Count -gt 0
  if (-not $hit) { Write-Host ("      no entry like '{0}' in:`n        {1}" -f $Pattern, (@($List) -join "`n        ")) -ForegroundColor Yellow }
  Assert-True $hit $Name
}
function Read-Fixture([string]$Name) { return (ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText((Join-Path $fixtures $Name)))) }
function Copy-Object($o) { return (ConvertFrom-Json @MirrorJsonArgs -InputObject (ConvertTo-Json -InputObject $o -Depth 20)) }

$units = ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText((Join-Path $repo 'deploy/units.json')))
$bounds = ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText((Join-Path $repo 'deploy/boundaries.json')))
# The tests judge an enabled pilot unit that has a deploy identity. They start from a copy of the file with every
# deploy identity empty and the pilot unit disabled, whatever the checkout holds. So filling in a client ID or
# enabling the pilot does not change what they prove.
foreach ($p in @($units.allowedPrincipals)) { if ([string]$p.type -ceq 'servicePrincipal' -and [string]$p.use -like '*(environment mirror-production-*') { $p.name = '' } }
(@($units.units) | Where-Object { $_.name -eq 'pilot-empty-rg' }).enabled = $false
$unitsOn = Copy-Object $units
(@($unitsOn.units) | Where-Object { $_.name -eq 'pilot-empty-rg' }).enabled = $true
$pilotSub = [string]@($unitsOn.units | Where-Object { $_.name -eq 'pilot-empty-rg' })[0].subscription
foreach ($p in @($unitsOn.allowedPrincipals)) { if ([string]$p.use -like "*(environment mirror-production-$pilotSub)*") { $p.name = '11111111-1111-1111-1111-111111111111' } }
$pilot = @($units.units | Where-Object { $_.name -eq 'pilot-empty-rg' })[0]
# The tests judge a hold and a review boundary. They start from a copy of boundaries.json with one of each added,
# whatever the checkout holds, and the gate runs below on a copy of the repository that holds this copy.
$bounds.holds = @($bounds.holds) + @(ConvertFrom-Json '{ "type": "Microsoft.Compute/virtualMachines/extensions", "namePattern": "(?i)(OsUpdateExtension|PatchExtension)$", "reason": "A hold for the tests." }')
$bounds.boundaries = @($bounds.boundaries) + @(ConvertFrom-Json '{ "type": "Microsoft.HybridCompute/machines/extensions", "path": "properties.settings.updateConfiguration.startTime", "changeTypes": [ "Modify" ], "onDeploy": "review", "reason": "A review boundary for the tests.", "note": "Read before acknowledging." }')
# The tests of the by-hand rules judge a gateway unit, a tenant unit, a deploy-excluded and a hash-excluded unit,
# which this estate does not have. They take a copy of the file with one of each added.
$unitsHand = Copy-Object $unitsOn
$extraUnits = ConvertFrom-Json '[ { "name": "demo-vpn-gateways", "kind": "subscription", "subscription": "demo", "resourceGroup": null, "template": "infra/subscriptions/demo/network-gateways.bicep", "route": "hand", "enabled": false }, { "name": "tenant-demo-groups", "kind": "tenant", "subscription": null, "resourceGroup": null, "template": "infra/tenant/management-groups/main.bicep", "route": "hand", "enabled": false }, { "name": "rg-demo-network-deploy-excluded", "kind": "resourceGroup", "subscription": "demo", "resourceGroup": "rg-demo-network", "template": "infra/subscriptions/demo/resource-groups/rg-demo-network.deploy-excluded.bicep", "route": "hand", "enabled": false }, { "name": "rg-demo-web-hash-excluded", "kind": "resourceGroup", "subscription": "demo", "resourceGroup": "rg-demo-web", "template": "infra/subscriptions/demo/resource-groups/rg-demo-web.hash-excluded.bicep", "route": "hand", "enabled": false } ]'
$unitsHand.units = @($unitsHand.units) + @($extraUnits | ForEach-Object { $_ })
$subId = [string]$units.subscriptions.($pilot.subscription)
$rgPrefix = "/subscriptions/$subId/resourceGroups/$($pilot.resourceGroup)/providers"
$inScope = "$rgPrefix/Microsoft.Storage/storageAccounts/st1"
$held = "$rgPrefix/Microsoft.Compute/virtualMachines/vm1/extensions/SamplePatchExtension"
function New-Request([hashtable]$Over = @{}) {
  $r = [ordered]@{ unit = 'pilot-empty-rg'; changeRef = 'CHG0012345'; reason = 'Pilot.'; acknowledgeReview = $false
                   allowCreate = [string[]]@(); allowModify = [string[]]@(); allowHeld = [string[]]@() }
  foreach ($k in $Over.Keys) { $r[$k] = $Over[$k] }
  return [pscustomobject]$r
}

Write-Host '--- name status'
$ns = @(ConvertFrom-NameStatus @("A`tdeploy/units.json", "M`tinfra/x.bicep", "R100`told.json`tnew.json"))
Assert-Equal 3 $ns.Count 'three name-status lines'
Assert-Equal 'R' $ns[2].Status 'a rename keeps its first letter'
Assert-Equal 'new.json' $ns[2].Path 'a rename reads as its new path'

Write-Host '--- the request of a deployment'
$e = @((Test-DeployRequest (New-Request) $unitsOn $bounds).errors)
Assert-Equal 0 $e.Count "a good request passes ($($e -join '; '))"
$e = @((Test-DeployRequest (New-Request) $units $bounds).errors)
Assert-Contains $e '*is disabled*' 'a disabled unit is refused'
Assert-Contains $e '*no deploy identity is filled in*' 'a subscription without a deploy identity is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ unit = 'no-such-unit' }) $unitsOn $bounds).errors) '*is not in deploy/units.json*' 'an unknown unit is refused'
$zw = [string][char]0x200B
Assert-Contains @((Test-DeployRequest (New-Request @{ unit = 'pilot-empty-rg' + $zw }) $unitsOn $bounds).errors) 'unit must be a unit name*' 'a unit name with a zero-width space is refused'
Assert-True ($null -eq (Find-UnitDef $unitsOn ('pilot-empty-rg' + $zw))) 'the unit lookup compares exact characters'
Assert-True ($null -ne (Find-UnitDef $unitsOn 'pilot-empty-rg')) 'the unit lookup finds the plain name'
$on2 = Copy-Object $unitsHand; (@($on2.units) | Where-Object { $_.name -eq 'demo-vpn-gateways' }).enabled = $true
Assert-Contains @((Test-DeployRequest (New-Request @{ unit = 'demo-vpn-gateways' }) $on2 $bounds).errors) '*never runs in the pipeline*' 'a by-hand unit is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ unit = 'tenant-demo-groups' }) $unitsHand $bounds).errors) '*never runs in the pipeline*' 'a tenant unit is refused'
$noRoute = Copy-Object $on2; (@($noRoute.units) | Where-Object { $_.name -eq 'rg-demo-network-deploy-excluded' }).PSObject.Properties.Remove('route')
Assert-True ($null -ne (Get-HandRouteReason (@($noRoute.units) | Where-Object { $_.name -eq 'rg-demo-network-deploy-excluded' }))) 'a deploy-excluded unit stays by hand even without its route field'
Assert-Contains @((Test-DeployRequest (New-Request @{ changeRef = 'a b' }) $unitsOn $bounds).errors) 'changeRef must*' 'a change reference with a space is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ reason = ' ' }) $unitsOn $bounds).errors) 'reason must*' 'an empty reason is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ reason = ('x' * 501) }) $unitsOn $bounds).errors) 'reason is longer*' 'a reason over 500 characters is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ acknowledgeReview = 'yes' }) $unitsOn $bounds).errors) 'acknowledgeReview must*' 'acknowledgeReview must be a boolean'
Assert-Equal 0 @((Test-DeployRequest (New-Request @{ allowModify = [string[]]@($inScope) }) $unitsOn $bounds).errors).Count 'one allowModify ID in scope passes (a list of one)'
Assert-Contains @((Test-DeployRequest (New-Request @{ allowModify = [string[]]@("/subscriptions/$subId/resourceGroups/OtherGroup/providers/Microsoft.Storage/storageAccounts/st1") }) $unitsOn $bounds).errors) "*not inside the unit's scope*" 'an ID outside the resource group is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ allowCreate = [string[]]@($inScope, $inScope.ToUpperInvariant()) }) $unitsOn $bounds).errors) '*twice*' 'the same ID twice is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ allowModify = [string[]]@("$inScope/") }) $unitsOn $bounds).errors) '*trailing slash*' 'an ID with a trailing slash is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ allowCreate = [string[]]@("$inScope$zw") }) $unitsOn $bounds).errors) '*control or invisible character*' 'an ID with a zero-width space is refused'
Assert-Contains @((Test-DeployRequest (New-Request @{ allowCreate = 'not-a-list' }) $unitsOn $bounds).errors) 'allowCreate must be a list*' 'an ID list must be a list'
Assert-Equal 0 @((Test-DeployRequest (New-Request @{ allowHeld = [string[]]@($held) }) $unitsOn $bounds).errors).Count 'an allowHeld ID that matches a hold passes'
Assert-Contains @((Test-DeployRequest (New-Request @{ allowHeld = [string[]]@($inScope) }) $unitsOn $bounds).errors) '*matches no hold*' 'an allowHeld ID without a hold is refused'
$on3 = Copy-Object $unitsHand; $hx = @($on3.units) | Where-Object { $_.name -eq 'rg-demo-web-hash-excluded' }; $hx.enabled = $true; $hx.PSObject.Properties.Remove('route')
Assert-Contains @((Test-DeployRequest (New-Request @{ unit = 'rg-demo-web-hash-excluded' }) $on3 $bounds).errors) '*never runs in the pipeline*' 'a hash-excluded unit stays by hand even without its route field'
$on4 = Copy-Object $unitsOn; (@($on4.units) | Where-Object { $_.name -eq 'demo-subscription' }).enabled = $true
Assert-Contains @((Test-DeployRequest (New-Request @{ unit = 'demo-subscription' }) $on4 $bounds).errors) '*never runs in the pipeline*' 'a subscription unit (main.bicep) is refused, it deploys by hand'
$on5 = Copy-Object $on4; (@($on5.units) | Where-Object { $_.name -eq 'demo-subscription' }).PSObject.Properties.Remove('route')
Assert-Contains @((Test-DeployRequest (New-Request @{ unit = 'demo-subscription' }) $on5 $bounds).errors) '*main.bicep holds role assignments*' 'a subscription unit stays by hand even without its route field'
$subMain = @(@($units.units) | Where-Object { Test-SubscriptionMainUnit $_ })
Assert-Equal 1 $subMain.Count 'the 1 subscription unit is found by its main.bicep'
Assert-Equal 0 @($subMain | Where-Object { [string]$_.route -ne 'hand' }).Count 'it is marked "route": "hand" in deploy/units.json'
Assert-True (Test-DeployIdentity $unitsOn $pilotSub) 'a filled-in deploy identity is found by its environment'
Assert-True (-not (Test-DeployIdentity $units $pilotSub)) 'an empty name is no deploy identity'
Assert-True (-not (Test-DeployIdentity $unitsOn 'demo-other')) 'the identity of another subscription folder does not count'
$o = Get-DeployOptions (New-Request @{ acknowledgeReview = $true; allowModify = [string[]]@($inScope) })
Assert-True ($o.acknowledgeReview -and $o.allowModify.Count -eq 1 -and $o.allowCreate.Count -eq 0) 'the options are read from a request'

Write-Host '--- the change ticket of a merged pull request'
Assert-Equal 'CHG0012345' (Get-ChangeTicketFromText 'Add a storage account' "Why.`nChange: CHG0012345`n") 'a Change line in the body is the ticket'
Assert-Equal 'INC77/a' (Get-ChangeTicketFromText 'Ticket: INC77/a' '') 'a Ticket label in the title is the ticket'
Assert-Equal '' (Get-ChangeTicketFromText 'Fix. Ticket: INC77/a' '') 'a label in the middle of a line is no ticket'
Assert-Equal '' (Get-ChangeTicketFromText 'Tidy up' "Change: this removes the old account`nTicket: later") 'a sentence after the label is no ticket'
Assert-Equal '' (Get-ChangeTicketFromText 'Tidy up' 'Change: removes') 'a word with no digit is no ticket'
Assert-Equal 'CHG0012345' (Get-ChangeTicketFromText 'Tidy up' "Why.`r`nChange: CHG0012345`r`n") 'a Windows line ending after the ticket is fine'
Assert-Equal 'CHG1' (Get-ChangeTicketFromText '' 'change ticket: CHG1') 'a short ticket of 4 characters passes'
Assert-Equal '' (Get-ChangeTicketFromText 'Add a storage account' 'No ticket here, the change is small.') 'text without a label names no ticket'
Assert-Equal '' (Get-ChangeTicketFromText 'Change: x' '') 'a ticket under 3 characters is no ticket'

Write-Host '--- boundaries.json changes'
$b0 = ConvertFrom-Json '{ "boundaries": [ { "type": "A/b", "path": "p" } ], "holds": [ { "type": "A/b", "namePattern": "x" }, { "idPattern": "(?i)^/subscriptions/AAAA/x", "reason": "r" } ], "expectedIgnore": [ { "pattern": "(?i)^/subscriptions/BBBB/y", "reason": "r" } ] }'
$b1 = ConvertFrom-Json '{ "boundaries": [ { "type": "A/b", "path": "p2" } ], "holds": [ { "type": "A/b", "namePattern": "x" }, { "idPattern": "(?i)^/subscriptions/AAAA/x", "reason": "r" } ], "expectedIgnore": [ { "pattern": "(?i)^/subscriptions/bbbb/y", "reason": "r" }, { "pattern": "(?i)^/subscriptions/CCCC/z", "reason": "r" } ] }'
$bc = Get-BoundaryChanges $b0 $b1
Assert-Equal 2 @($bc.typeWide).Count 'a changed boundary entry is a whole-type change (old and new)'
Assert-Equal 3 @($bc.scoped).Count 'changed expected Ignore patterns are scoped (two new, one old gone)'
$uu = ConvertFrom-Json '{ "subscriptions": { "s1": "bbbb", "s2": "cccc", "s3": "dddd" }, "units": [ { "name": "u1", "subscription": "s1" }, { "name": "u2", "subscription": "s2" }, { "name": "u3", "subscription": "s3" } ] }'
Assert-Equal 'u1,u2' (@(Get-BoundaryScopeUnits $bc $uu) -join ',') 'the units of the subscriptions a changed pattern names are picked, whatever the case'
Assert-Equal 0 @((Get-BoundaryChanges $b0 $b0).typeWide).Count 'no change, no entry'

Write-Host '--- the plan: age, records, options'
$nowT = [DateTimeOffset]::new(2026, 11, 1, 12, 0, 0, [TimeSpan]::Zero)
Assert-Equal 0 @(Test-PlanAge '2026-11-01T11:00:00.0000000+00:00' $nowT 24).Count 'a plan from an hour ago is recent'
Assert-Contains @(Test-PlanAge '2026-10-30T11:00:00.0000000+00:00' $nowT 24) '*hours old*' 'a plan from two days ago is too old'
Assert-Equal 0 @(Test-PlanAge '2026-10-30T11:00:00.0000000+00:00' $nowT 72).Count 'the limit follows MIRROR_MAX_PLAN_AGE_HOURS'
Assert-Contains @(Test-PlanAge 'not a time' $nowT 24) '*no readable time*' 'a plan without a readable time is refused'
Assert-Contains @(Test-PlanAge '2026-11-02T11:00:00.0000000+00:00' $nowT 24) '*in the future*' 'a plan dated in the future is refused'
Assert-Equal 24 (Get-MaxPlanAgeHours) 'the default plan age is 24 hours'
$gp = Read-Fixture 'gate-pass.json'
Assert-True (-not (Test-HasChanges $gp)) 'a gate of NoChange records has nothing to deploy'
Assert-True (Test-HasChanges ([pscustomobject]@{ counts = [pscustomobject]@{ NoChange = 3; Modify = 1 } })) 'a Modify record is a change'
Assert-True (Test-HasChanges ([pscustomobject]@{ counts = [pscustomobject]@{ Create = 1 } })) 'a Create record is a change'
Assert-True (-not (Test-HasChanges ([pscustomobject]@{ counts = [pscustomobject]@{ Ignore = 4; NoChange = 3 } }))) 'Ignore records are no change'
Assert-True (Test-HasChanges ([pscustomobject]@{ counts = [pscustomobject]@{ Delete = 1 } })) 'a Delete record is a change'
Assert-True (Test-HasChanges ([pscustomobject]@{ counts = [pscustomobject]@{ Deploy = 1 } })) 'a Deploy record is a change'
$gMod = ConvertFrom-Json '{ "counts": { "Modify": 1 }, "decisions": [ { "resourceId": "/s/a", "changeType": "Modify", "verdict": "pass", "notes": [] } ] }'
Assert-True (-not (Test-HasChanges $gMod)) 'a Modify that passes with no option holds only NoEffect and inert properties, so it is no effective change'
$gModOk = ConvertFrom-Json '{ "counts": { "Modify": 1 }, "decisions": [ { "resourceId": "/s/a", "changeType": "Modify", "verdict": "pass", "notes": [], "propertyChanges": [ { "path": "tags", "decision": "no effect (NoEffect)" }, { "path": "p", "decision": "listed boundary" } ] } ] }'
Assert-True (-not (Test-HasChanges $gModOk)) 'a Modify whose properties are NoEffect or in an inert boundary is no effective change'
$gModEff = ConvertFrom-Json '{ "counts": { "Modify": 1 }, "decisions": [ { "resourceId": "/s/a", "changeType": "Modify", "verdict": "pass", "notes": [], "propertyChanges": [ { "path": "p", "decision": "allowed by -AllowModify" } ] } ] }'
Assert-True (Test-HasChanges $gModEff) 'a Modify with a property that is neither NoEffect nor inert is an effective change'
$gModFail = ConvertFrom-Json '{ "counts": { "Modify": 1 }, "decisions": [ { "resourceId": "/s/a", "changeType": "Modify", "verdict": "fail", "notes": [] } ] }'
Assert-True (Test-HasChanges $gModFail) 'a Modify that does not pass is an effective change'
$noOpts = Get-DeployOptions (New-Request)
$gA = ConvertFrom-Json '{ "overall": "pass", "decisions": [ { "resourceId": "/s/a", "changeType": "NoChange", "verdict": "pass" }, { "resourceId": "/s/B", "changeType": "Modify", "verdict": "pass" } ] }'
$gB = ConvertFrom-Json '{ "overall": "pass", "decisions": [ { "resourceId": "/s/a", "changeType": "NoChange", "verdict": "pass" }, { "resourceId": "/s/b", "changeType": "Modify", "verdict": "pass" } ] }'
Assert-Equal 0 @(Compare-PlanRecords $gA $gB $noOpts).Count 'the same records compare equal, whatever the case of the ID'
$gC = ConvertFrom-Json '{ "overall": "pass", "decisions": [ { "resourceId": "/s/a", "changeType": "NoChange", "verdict": "pass" }, { "resourceId": "/s/b", "changeType": "Modify", "verdict": "pass" }, { "resourceId": "/s/c", "changeType": "Create", "verdict": "pass" } ] }'
Assert-Contains @(Compare-PlanRecords $gA $gC $noOpts) 'new since the plan: /s/c | Create | pass' 'a record only the fresh preview shows is found'
Assert-Contains @(Compare-PlanRecords $gC $gA $noOpts) 'gone since the plan: /s/c | Create | pass' 'a record only the plan showed is found'
$gD = ConvertFrom-Json '{ "overall": "pass", "decisions": [ { "resourceId": "/s/a", "changeType": "NoChange", "verdict": "pass" }, { "resourceId": "/s/b", "changeType": "Modify", "verdict": "fail" } ] }'
Assert-Contains @(Compare-PlanRecords $gA $gD $noOpts) '*/s/b | Modify | fail' 'a record whose verdict changed is found'
Assert-Equal 0 @(Compare-PlanRecords $gA $gD (Get-DeployOptions (New-Request @{ allowModify = [string[]]@('/s/B') }))).Count 'the resources the options name are left out of the comparison'
$hints = Get-ExceptionHints (Read-Fixture 'gate-fail.json') 'u1'
Assert-True ($hints.command -like 'gh workflow run mirror-deploy-unit --ref master -f unit=u1 *') 'the hint is a Run workflow command for the unit'
$gH = ConvertFrom-Json '{ "decisions": [ { "resourceId": "/s/n", "changeType": "Create", "verdict": "fail", "notes": [ "Create is not allowed" ] }, { "resourceId": "/s/m", "changeType": "Modify", "verdict": "fail", "notes": [] }, { "resourceId": "/s/h", "changeType": "Modify", "verdict": "fail", "notes": [ "held: Update Manager owns these" ] }, { "resourceId": "/s/r", "changeType": "Deploy", "verdict": "review", "notes": [ "review record: x" ] } ] }'
$hints = Get-ExceptionHints $gH 'u1'
Assert-True ($hints.command -like '* -f acknowledgeReview=true -f allowCreate=/s/n -f allowModify=/s/m -f allowHeld=/s/h') 'each failing record names the option that accepts it'
Assert-True ($hints.accepted) 'a plan whose every stop has an option is marked as acceptable'
$gO = ConvertFrom-Json '{ "decisions": [ { "resourceId": "/s/o", "changeType": "Modify", "verdict": "fail", "notes": [ "outside the unit scope" ] }, { "resourceId": "/s/p", "changeType": "Delete", "verdict": "fail", "notes": [] } ] }'
Assert-True (-not (Get-ExceptionHints $gO 'u1').accepted) 'a plan with a record no option accepts is not marked as acceptable'

Write-Host '--- gate files'
Assert-True (Test-Approvable (Read-Fixture 'gate-pass.json')).ok 'a passed gate is approvable'
$t = Test-Approvable (Read-Fixture 'gate-review-record.json')
Assert-True (-not $t.ok) 'a review record waiting is not approvable'
Assert-Contains @($t.reasons) 'review record waiting*' 'the reason names the review record'
$t = Test-Approvable (Read-Fixture 'gate-fail.json')
Assert-True (-not $t.ok) 'a failed gate is not approvable'
Assert-Contains @($t.reasons) 'problem with the preview*' 'the reason names the problem'

Write-Host '--- deploy-unit.ps1 -WhatIfJson on a saved what-if (offline)'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('mirror-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
  $wi = Join-Path $tmp 'whatif.json'
  $text = [IO.File]::ReadAllText((Join-Path $fixtures 'whatif-review.json')).Replace('__SUB__', $subId).Replace('__RG__', [string]$pilot.resourceGroup)
  [IO.File]::WriteAllText($wi, $text)
  $nsg = "$rgPrefix/Microsoft.Network/networkSecurityGroups/nsg1"
  $gr = Join-Path $tmp 'gate-repo'
  foreach ($d in @('scripts', 'deploy', (Split-Path -Parent ([string]$pilot.template)))) { New-Item -ItemType Directory -Force -Path (Join-Path $gr $d) | Out-Null }
  Copy-Item -LiteralPath (Join-Path $repo 'scripts/deploy-unit.ps1') -Destination (Join-Path $gr 'scripts/deploy-unit.ps1')
  Copy-Item -LiteralPath (Join-Path $repo ([string]$pilot.template)) -Destination (Join-Path $gr ([string]$pilot.template))
  [IO.File]::WriteAllText((Join-Path $gr 'deploy/units.json'), (ConvertTo-Json -InputObject $units -Depth 20))
  [IO.File]::WriteAllText((Join-Path $gr 'deploy/boundaries.json'), (ConvertTo-Json -InputObject $bounds -Depth 20))
  $gateScript = Join-Path $gr 'scripts/deploy-unit.ps1'

  $ev1 = Join-Path $tmp 'ev1'
  & $gateScript -Unit 'pilot-empty-rg' -WhatIfJson $wi -EvidenceRoot $ev1 -AllowModify $inScope -AllowCreate $nsg -AllowHeld $held | Out-Null
  Assert-Equal 1 $LASTEXITCODE 'the dry run stops with REVIEW (exit 1)'
  $sum1 = @(Get-ChildItem -LiteralPath $ev1 -Recurse -Filter 'pre-summary.txt')[0].FullName
  $gate1 = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $sum1) 'pre-gate.json')))
  $h = Read-DryRunHeader ([IO.File]::ReadAllLines($sum1))
  Assert-Equal 'pilot-empty-rg' $h.fields['Unit'] 'the header names the unit'
  Assert-Equal 'REVIEW' $h.fields['Gate'] 'the header names the gate result'
  Assert-Equal $inScope ($h.allowModify -join ',') 'AllowModify is read from the header'
  Assert-Equal $nsg ($h.allowCreate -join ',') 'AllowCreate is read from the header'
  Assert-Equal $held ($h.allowHeld -join ',') 'AllowHeld (two spaces) is read from the header'
  $t = Test-Approvable $gate1
  Assert-True (-not $t.ok) 'a review boundary waiting makes the dry run not approvable'
  Assert-Contains @($t.reasons) 'review boundary waiting*' 'the reason names the review boundary'

  $ev2 = Join-Path $tmp 'ev2'
  & $gateScript -Unit 'pilot-empty-rg' -WhatIfJson $wi -EvidenceRoot $ev2 -AllowModify $inScope -AllowCreate $nsg -AllowHeld $held -AcknowledgeReview | Out-Null
  Assert-Equal 1 $LASTEXITCODE 'with -AcknowledgeReview it still stops with REVIEW for the allowModify change'
  $sum2 = @(Get-ChildItem -LiteralPath $ev2 -Recurse -Filter 'pre-summary.txt')[0].FullName
  $gate2 = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path (Split-Path -Parent $sum2) 'pre-gate.json')))
  $t = Test-Approvable $gate2
  Assert-True $t.ok "a REVIEW whose only reason is allowModify is approvable ($($t.reasons -join '; '))"
  $items = @(Get-AcceptedReviewItems $gate2)
  Assert-Equal 1 $items.Count 'one accepted review item'
  Assert-Contains $items 'boundary | *ext1 | properties.settings.updateConfiguration.startTime' 'the accepted item names the resource and the property'
  Assert-Equal 0 @(Compare-ReviewItems $gate2 $gate2).Count 'the same review items compare equal'
  Assert-Equal 1 @(Compare-ReviewItems (Read-Fixture 'gate-pass.json') $gate2).Count 'a review item the approved dry run did not show is found'


  $o2 = Get-DeployOptions (New-Request @{ acknowledgeReview = $true; allowModify = [string[]]@($inScope); allowCreate = [string[]]@($nsg); allowHeld = [string[]]@($held) })
  $cm = ($h.fields['Commit'] -replace ' .*$', '')
  $e = @(Test-PlanMatches (Read-DryRunHeader ([IO.File]::ReadAllLines($sum2))) $o2 'pilot-empty-rg' $cm)
  Assert-Contains $e "*mode is 'offline evaluation'*" 'an offline evaluation is not a dry run'
  Assert-Equal 0 @($e | Where-Object { $_ -like '*list than the options*' }).Count 'the three ID lists match the options of the run'
  $o3 = Get-DeployOptions (New-Request @{ allowModify = [string[]]@($inScope); allowCreate = [string[]]@($nsg) })
  Assert-Contains @(Test-PlanMatches (Read-DryRunHeader ([IO.File]::ReadAllLines($sum2))) $o3 'pilot-empty-rg' $cm) '*another allowHeld list*' 'a different allowHeld list is found'
  Assert-Contains @(Test-PlanMatches (Read-DryRunHeader ([IO.File]::ReadAllLines($sum2))) $o2 'other-unit' $cm) '*the plan is of unit*' 'a plan of another unit is refused'

  $ga = Get-GateArguments $o2 (Join-Path $tmp 'out') $ev2 -Deploy
  Assert-True ($ga.DryRun -eq $false -and $ga.Approve) 'a deploy run gets -DryRun:$false -Approve'
  Assert-Equal (Split-Path -Parent $sum2) $ga.ApprovedChanges 'with allowModify the deploy run gets the reviewed plan folder'
  Assert-True ($ga.AcknowledgeReview -and $ga.AllowHeld.Count -eq 1 -and $ga.AllowCreate.Count -eq 1) 'the options reach the gate'
  $gd = Get-GateArguments $o2 (Join-Path $tmp 'out') ''
  Assert-True (-not $gd.ContainsKey('DryRun') -and -not $gd.ContainsKey('ApprovedChanges') -and $gd.AllowModify.Count -eq 1) 'the dry run form has no deploy arguments'
  $g0 = Get-GateArguments $noOpts (Join-Path $tmp 'out') '' -Deploy
  Assert-True (-not $g0.ContainsKey('ApprovedChanges') -and -not $g0.ContainsKey('AllowModify')) 'without allowModify there is no -ApprovedChanges'

  $v = New-Verdict 'pilot-empty-rg' 'plan' 1 $ev2
  Assert-True ($v.approvable -and -not $v.technical) 'the verdict of an approvable REVIEW'
  $v = New-Verdict 'pilot-empty-rg' 'plan' 2 (Join-Path $tmp 'nothing')
  Assert-True $v.technical 'no gate result is a technical failure'
  Assert-True ((Format-VerdictMarkdown (New-Verdict 'pilot-empty-rg' 'code' 1 $ev1)) -like '*for information*') 'a code verdict is marked as information'
  $planObj = [pscustomobject][ordered]@{ unit = 'pilot-empty-rg'; subscription = 'demo'; commit = ('a' * 40); trigger = 'push'; startedBy = 'it-user-one'
    changeRef = 'CHG0012345'; reason = "Merged pull request #4: add`na thing"; options = [ordered]@{ acknowledgeReview = $true; allowCreate = @(); allowModify = @($inScope); allowHeld = @() } }
  $md = Format-PlanMarkdown $planObj (New-Verdict 'pilot-empty-rg' 'plan' 1 $ev2)
  Assert-True ($md -like '*## Plan for pilot-empty-rg*Change ticket: CHG0012345*Options in force: acknowledgeReview, allowModify (1)*allowModify: /subscriptions/*' -and $md -notlike '*add' + "`n" + 'a thing*') 'the plan markdown leads with the unit, the ticket and the options in force, on one line each'
  $tpl = Join-Path $tmp 'plan-dir'; New-Item -ItemType Directory -Path $tpl | Out-Null
  Copy-Item -LiteralPath (Split-Path -Parent $sum2) -Destination (Join-Path $tpl 'gate') -Recurse
  [IO.File]::WriteAllText((Join-Path $tpl 'plan.json'), (ConvertTo-Json -InputObject $planObj -Depth 6))
  $rp = Get-ReviewedPlan $tpl
  Assert-True ($rp.plan.unit -eq 'pilot-empty-rg' -and (Test-Path -LiteralPath $rp.gate) -and (Test-Path -LiteralPath $rp.summary)) 'a reviewed plan folder is read with its gate files'
  $ga2 = Get-GateArguments (Get-DeployOptions $rp.plan.options) (Join-Path $tmp 'out') $tpl -Deploy
  Assert-Equal (Split-Path -Parent $rp.gate) $ga2.ApprovedChanges 'the apply holds allowModify to the gate file of the reviewed plan'

  Write-Host '--- step outputs'
  $out = Join-Path $tmp 'output.txt'
  [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $out)
  Set-StepOutput 'one' 'value'
  Set-StepOutput 'two' "line1`nline2"
  [Environment]::SetEnvironmentVariable('GITHUB_OUTPUT', $null)
  $o = [IO.File]::ReadAllText($out)
  Assert-True ($o.StartsWith("one=value`n")) 'a single-line output, without a byte order mark'
  Assert-True ($o -match "two<<(EOF_[0-9a-f]+)`nline1`nline2`n\1`n") 'a multi-line output uses a delimiter'
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- units a code change touches'
$files = Get-UnitFiles $units $repo
$r = Resolve-AffectedUnits @('infra/subscriptions/demo/main.bicep') $units $files
Assert-True (@($r.preview) -contains 'demo-subscription') 'a subscription main.bicep previews its subscription unit'
Assert-True (@($r.preview) -notcontains 'rg-demo-network') 'and not an unrelated resource group unit'
Assert-Contains @($r.notes) '*previewed here for information and deployed by hand*demo-subscription*' 'the note says the subscription units deploy by hand'
Assert-True (@($r.hand) -notcontains 'demo-subscription') 'a subscription unit is previewed, not set aside like the other by-hand units'
$r = Resolve-AffectedUnits @('infra/subscriptions/demo/resource-groups/rg-demo-routing.bicep') $units $files
Assert-Equal 'rg-demo-routing' (@($r.preview) -join ',') 'a resource group file previews its own unit only'
$byHand = Copy-Object $units; @($byHand.units | Where-Object { $_.name -eq 'rg-demo-routing' })[0] | Add-Member -NotePropertyName route -NotePropertyValue 'hand'
$r = Resolve-AffectedUnits @('infra/subscriptions/demo/resource-groups/rg-demo-routing.bicep') $byHand (Get-UnitFiles $byHand $repo)
Assert-True (@($r.hand) -contains 'rg-demo-routing') 'a file of a by-hand unit touches that unit'
Assert-True (@($r.preview) -notcontains 'rg-demo-routing') 'which is never previewed here'
# This estate has no module, so the next tests take a small tree in a temporary folder: a shared module that a
# subscription main.bicep calls, and a module that only a by-hand unit calls.
$mt = Join-Path ([IO.Path]::GetTempPath()) ('mirror-modules-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $mt 'infra/modules/governance') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $mt 'infra/subscriptions/demo/resource-groups') | Out-Null
try {
  [IO.File]::WriteAllText((Join-Path $mt 'infra/modules/governance/shared-policies.bicep'), "targetScope = 'subscription'`n")
  [IO.File]::WriteAllText((Join-Path $mt 'infra/subscriptions/demo/main.bicep'), "targetScope = 'subscription'`nmodule p '../../modules/governance/shared-policies.bicep' = {`n  name: 'p'`n}`n")
  [IO.File]::WriteAllText((Join-Path $mt 'infra/subscriptions/demo/resource-groups/rg-demo-network.bicep'), "output o string = 'x'`n")
  [IO.File]::WriteAllText((Join-Path $mt 'infra/subscriptions/demo/network-gateways.bicep'), "targetScope = 'subscription'`nmodule g './resource-groups/rg-demo-network.vpn-gateways.bicep' = {`n  name: 'g'`n  scope: resourceGroup('rg-demo-network')`n}`n")
  [IO.File]::WriteAllText((Join-Path $mt 'infra/subscriptions/demo/resource-groups/rg-demo-network.vpn-gateways.bicep'), "output o string = 'x'`n")
  $mu = [pscustomobject]@{ units = @(
    [pscustomobject]@{ name = 'demo-subscription'; kind = 'subscription'; subscription = 'demo'; template = 'infra/subscriptions/demo/main.bicep'; route = 'hand'; enabled = $false },
    [pscustomobject]@{ name = 'rg-demo-network'; kind = 'resourceGroup'; subscription = 'demo'; resourceGroup = 'rg-demo-network'; template = 'infra/subscriptions/demo/resource-groups/rg-demo-network.bicep'; enabled = $false },
    [pscustomobject]@{ name = 'demo-vpn-gateways'; kind = 'subscription'; subscription = 'demo'; template = 'infra/subscriptions/demo/network-gateways.bicep'; route = 'hand'; enabled = $false }) }
  $mf = Get-UnitFiles $mu $mt
  $r = Resolve-AffectedUnits @('infra/modules/governance/shared-policies.bicep') $mu $mf
  Assert-True (@($r.preview) -contains 'demo-subscription') 'a shared module previews the subscription unit that calls it'
  Assert-True (@($r.preview) -notcontains 'rg-demo-network') 'and not a resource group unit that does not call it'
  Assert-Contains @($r.notes) '*previewed here for information and deployed by hand*demo-subscription*' 'the note says the subscription unit that calls the module deploys by hand'
  Assert-True (@($r.hand) -notcontains 'demo-subscription') 'a subscription unit reached through a module is previewed, not set aside like the other by-hand units'
  $r = Resolve-AffectedUnits @('infra/subscriptions/demo/resource-groups/rg-demo-network.vpn-gateways.bicep') $mu $mf
  Assert-True (@($r.hand) -contains 'demo-vpn-gateways') 'a module file touches the by-hand unit that calls it'
  Assert-True (@($r.preview) -notcontains 'demo-vpn-gateways' -and @($r.preview) -notcontains 'rg-demo-network') 'which is never previewed here, and no unit that does not call it is touched'
} finally {
  Remove-Item -LiteralPath $mt -Recurse -Force -ErrorAction SilentlyContinue
}
$r = Resolve-AffectedUnits @('deploy/boundaries.json', 'infra/subscriptions/demo/main.bicep') $units $files
Assert-True ($r.sweep -and @($r.preview).Count -eq 0) 'boundaries.json asks for a sweep and previews nothing'
$r = Resolve-AffectedUnits @('infra/tenant/governance.bicep') $units $files
Assert-Contains @($r.notes) '*tenant units*' 'a tenant file is noted as by hand'
$r = Resolve-AffectedUnits @('README.md') $units $files
Assert-Equal 0 @($r.preview).Count 'a document previews nothing'
# This estate has fewer than 13 resource group units, so the test takes a copy with twelve more that share one file.
$manyUnits = Copy-Object $units; $net = @($manyUnits.units | Where-Object { $_.name -eq 'rg-demo-network' })[0]
foreach ($i in 1..12) { $c = Copy-Object $net; $c.name = "rg-demo-network-$i"; $manyUnits.units = @($manyUnits.units) + @($c) }
$many = @(@($manyUnits.units) | Where-Object { $_.kind -eq 'resourceGroup' -and -not (Get-HandRouteReason $_) } | Select-Object -First 13 | ForEach-Object { $_.template })
$r = Resolve-AffectedUnits $many $manyUnits (Get-UnitFiles $manyUnits $repo)
Assert-True (@($r.preview).Count -eq 0 -and (@($r.notes) -join ' ') -like '*more than the 12*') 'more than 12 units ask for a sweep'
$changedUnits = Copy-Object $units; (@($changedUnits.units) | Where-Object { $_.name -eq 'rg-demo-network' }).enabled = $true
Assert-Equal 'rg-demo-network' (@(Get-ChangedUnitEntries $units $changedUnits) -join ',') 'enabling a unit in units.json previews it'
$changedUnits = Copy-Object $units; $zwUnit = (@($changedUnits.units) | Where-Object { $_.name -eq 'rg-demo-network' })[0]; $zwUnit.resourceGroup = [string]$zwUnit.resourceGroup + $zw
Assert-Equal 'rg-demo-network' (@(Get-ChangedUnitEntries $units $changedUnits) -join ',') 'a unit entry that changes only by a zero-width space is a changed entry'

Write-Host '--- what-if arguments'
$wa = Get-WhatIfArguments (@($units.units) | Where-Object { $_.name -eq 'demo-subscription' })[0] $units $repo
Assert-True ($wa -contains '--location' -and $wa -contains [string]$units.deploymentLocation -and $wa -contains 'sub') 'a subscription unit takes the location from units.json'
Assert-True ($wa -contains 'ProviderNoRbac' -and $wa -contains 'FullResourcePayloads') 'the reader validation level and full payloads'
$wa = Get-WhatIfArguments $pilot $units $repo
Assert-True ($wa -contains '--template-file' -and $wa -contains '--resource-group') 'a unit without a parameters file previews its template'

Write-Host '--- workflow rules'
$wf = @{}
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $repo '.github/workflows') -File)) { $wf[$f.Name] = [IO.File]::ReadAllText($f.FullName) }
$e = @(Test-WorkflowHygiene $wf)
Assert-Equal 0 $e.Count "the repository's workflows pass the rules ($($e -join '; '))"
$sha = 'a' * 40
$bad = @{
  'x.yml' = "on:`n  pull_request_target: {}`njobs:`n  a:`n    environment: mirror-production-demo`n    steps:`n      - uses: actions/checkout@v7`n      - uses: someone/tool@$sha`n"
  'mirror-deploy-unit.yml' = "on:`n  workflow_dispatch: {}`n"
  'y.yml' = "on:`n  pull_request:`n    types: [ closed ]`npermissions:`n  id-token: write`n"
}
$e = @(Test-WorkflowHygiene $bad)
Assert-Contains $e 'x.yml: names a mirror-production*' 'a production environment outside the deploy workflow is refused'
Assert-Contains $e 'x.yml: uses the pull_request_target*' 'pull_request_target is refused'
Assert-Contains $e '*actions/checkout@v7 is not pinned*' 'a tag pin is refused'
Assert-Contains $e '*someone/tool is not one of the allowed actions*' 'an action outside the allowed list is refused'
Assert-Contains $e 'mirror-deploy-unit.yml: the deploy workflow must start on push*' 'a deploy workflow without a push trigger is refused'
Assert-Contains $e 'y.yml: requests id-token*' 'id-token on a closed pull request is refused'
$e = @(Test-WorkflowHygiene @{ 'z.yml' = "# environment: mirror-production-demo`n" })
Assert-Equal 0 $e.Count 'a comment line is not a rule break'
$rc = "    steps:`n      - name: Runner check`n        shell: pwsh`n        run: |`n          if (`$env:RUNNER_ENVIRONMENT -cne 'github-hosted' -or `$env:RUNNER_ARCH -cne 'X64' -or `$env:ImageOS -cne 'win25') { exit 1 }`n"
$sw = "    if: $($script:PipelineSwitch)`n"
$okRunner = "jobs:`n  a:`n$sw    runs-on: $($script:RunnerChoices[0])`n$rc      - shell: pwsh`n        run: x`n  b:`n$sw    runs-on: ubuntu-24.04`n$rc      - name: y`n        shell: pwsh`n        run: |`n          y`n  c:`n$sw    runs-on: 'windows-2025'  # pinned`n$rc  d:`n$sw    runs-on: $($script:RunnerChoices[1])`n$rc"
$e = @(Test-WorkflowHygiene @{ 'ok.yml' = $okRunner })
Assert-Equal 0 $e.Count "one of the two images or one of the two MIRROR_RUNNER expressions, the runner check first and pwsh steps pass ($($e -join '; '))"
$badRunner = @{
  'r1.yml' = "jobs:`n  a:`n    runs-on: ubuntu-latest`n$rc"
  'r2.yml' = "jobs:`n  a:`n    runs-on: `${{ vars.MIRROR_RUNNER || 'windows-latest' }}`n$rc"
  'r3.yml' = "jobs:`n  a:`n    runs-on: `${{ vars.MIRROR_RUNNER }}`n$rc"
  'r4.yml' = "jobs:`n  a:`n    runs-on: [ self-hosted, windows ]`n$rc"
  'r5.yml' = "jobs:`n  a:`n    runs-on: `${{ vars.MIRROR_RUNNER || 'windows-2025' }}`n$rc"
  'r6.yml' = "jobs:`n  a:`n    runs-on: windows-2022`n$rc"
  'c1.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - uses: actions/checkout@$('a' * 40)`n      - name: Runner check`n        shell: pwsh`n        run: RUNNER_ENVIRONMENT RUNNER_ARCH ImageOS`n"
  'c2.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - name: Runner check`n        shell: pwsh`n        run: exit 0`n"
  's1.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - shell: powershell`n        run: x`n"
  's2.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - run: x`n"
}
$e = @(Test-WorkflowHygiene $badRunner)
Assert-Contains $e "r1.yml: runs-on 'ubuntu-latest' is not windows-2025*" 'a -latest runner label is refused'
Assert-Contains $e "r2.yml: runs-on * is not windows-2025*" 'MIRROR_RUNNER with a -latest default is refused'
Assert-Contains $e "r3.yml: runs-on * is not windows-2025*" 'MIRROR_RUNNER without a default is refused'
Assert-Contains $e "r4.yml: runs-on * is not windows-2025*" 'a self-hosted label list is refused'
Assert-Contains $e "r5.yml: runs-on * is not windows-2025*" 'MIRROR_RUNNER used as the label itself is refused, because any value would reach runs-on'
Assert-Contains $e "r6.yml: runs-on 'windows-2022' is not windows-2025*" 'another pinned image is refused'
Assert-Contains $e 'c1.yml: the first step of the job a is not the runner check*' 'a runner check that is not the first step is refused'
Assert-Contains $e 'c2.yml: the first step of the job a is not the runner check*' 'a runner check that reads nothing is refused'
Assert-Equal 0 @($e | Where-Object { $_ -like 'r1.yml: the first step*' }).Count 'a job with the runner check first passes that rule'
Assert-Contains $e "s1.yml: a step uses the shell 'powershell'*" 'Windows PowerShell as a step shell is refused'
Assert-Contains $e 's2.yml: 1 run step(s) name no shell*' 'a run step without a shell is refused'

Write-Host '--- the pipeline switch'
$swJob = "    runs-on: windows-2025`n$rc"
$okSwitch = "jobs:`n  a:`n$sw$swJob  b:`n    needs: a`n    if: $($script:PipelineSwitch) && always()`n$swJob  c:`n    # The job's own comment comes first.`n    needs: a`n    if: `${{ $($script:PipelineSwitch) && (needs.a.outputs.kind == 'x' || needs.a.outputs.kind == 'y') }}`n$swJob"
$e = @(Test-WorkflowHygiene @{ 'ok.yml' = $okSwitch })
Assert-Equal 0 $e.Count "the switch alone, followed by && and a job's own condition, or by a bracketed || condition, passes ($($e -join '; '))"
$badSwitch = @{
  'w1.yml' = "jobs:`n  a:`n$sw$swJob  b:`n$swJob"
  'w2.yml' = "jobs:`n  a:`n    if: always() && $($script:PipelineSwitch)`n$swJob"
  'w3.yml' = "jobs:`n  a:`n    if: $($script:PipelineSwitch) && needs.x.outputs.a == 'y' || always()`n$swJob"
  'w4.yml' = "jobs:`n  a:`n    if: vars.MIRROR_PIPELINE_ENABLED != 'false'`n$swJob"
  'w5.yml' = "jobs:`n  a:`n$swJob      - name: y`n        if: $($script:PipelineSwitch)`n        shell: pwsh`n        run: y`n"
  'w6.yml' = "jobs:`n  a:`n    if: $($script:PipelineSwitch) && (needs.x.outputs.a == 'y') || (always())`n$swJob"
}
$e = @(Test-WorkflowHygiene $badSwitch)
Assert-Contains $e 'w1.yml: the job b does not carry the pipeline switch*' 'a job without the switch is refused'
Assert-Equal 0 @($e | Where-Object { $_ -like 'w1.yml: the job a *' }).Count 'the job beside it that carries the switch passes'
Assert-Contains $e 'w2.yml: the job a does not carry the pipeline switch*' 'the switch after another condition is refused, it comes first'
Assert-Contains $e 'w3.yml: the job a does not carry the pipeline switch*' 'an unbracketed || after the switch is refused, because it would run the job with the switch off'
Assert-Contains $e 'w4.yml: the job a does not carry the pipeline switch*' 'another test of the variable is refused'
Assert-Contains $e 'w5.yml: the job a does not carry the pipeline switch*' 'the switch on a step only is refused, because the job still starts a runner'
Assert-Contains $e 'w6.yml: the job a does not carry the pipeline switch*' 'two bracketed groups joined by || are refused'

Write-Host '--- pipeline units and Microsoft.Authorization resources'
$hits = @(Find-AuthorizationResources (Read-Fixture 'template-authorization.json'))
Assert-Equal 2 $hits.Count "a role assignment and a lock in a module are found, the existing role definition is not ($($hits -join '; '))"
Assert-Contains $hits 'governance > Microsoft.Authorization/roleAssignments*' 'the finding names the module and the type'
Assert-Contains $hits '*Microsoft.Authorization/locks (lock1)*' 'a resource behind a condition still counts'
Assert-Equal 0 @(Find-AuthorizationResources (Read-Fixture 'template-no-authorization.json')).Count 'a template in the older list form without such resources passes'
$one = '{ "resources": [ { "type": "Microsoft.Resources/deployments", "name": "ra-mod", "properties": { "template": { "resources": [ { "type": "Microsoft.Authorization/roleAssignments", "name": "x" } ] } } } ] }' | ConvertFrom-Json
$hits = @(Find-AuthorizationResources $one)
Assert-Equal 1 $hits.Count "a module with a single role assignment, in the list form, is found ($($hits -join '; '))"

Write-Host '--- Bicep inputs from a branch'
$bt = Join-Path ([IO.Path]::GetTempPath()) ('mirror-inputs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $bt 'infra/x') -Force | Out-Null
try {
  [IO.File]::WriteAllText((Join-Path $bt 'infra/x/good.bicep'), "// readEnvironmentVariable('X') in a comment`nparam a string = 'b'`nvar c = loadJsonContent('data.json')`nmodule m 'other.bicep' = {`n  name: 'm'`n}`n")
  [IO.File]::WriteAllText((Join-Path $bt 'infra/x/bad.bicepparam'), "using 'good.bicep'`nparam a = readEnvironmentVariable('ACTIONS_ID_TOKEN_REQUEST_TOKEN')`nparam b = externalInput('sys.envVar', 'ACTIONS_ID_TOKEN_REQUEST_URL')`n")
  [IO.File]::WriteAllText((Join-Path $bt 'infra/x/bad.bicep'), "module r 'br/public:avm/res/x:1.0.0' = {`n  name: 'r'`n}`nvar t = loadTextContent('../../../../Users/runneradmin/.azure/azureProfile.json')`nvar u = loadTextContent(name)`nvar v = loadFileAsBase64('/Windows/win.ini')`nvar w = loadFileAsBase64('C:/Windows/win.ini')`nvar x = loadTextContent('sub\u{2F}\u{2E}\u{2E}/../../../secret.txt')`n/* a block comment */ var y = loadYamlContent('../../../y.yml')`nvar z = loadResourceContent('a.txt')`n")
  $f = @(Find-UnsafeBicepInputs @('infra/x/good.bicep') $bt)
  Assert-Equal 0 $f.Count "a comment and a load of a file inside the repository pass ($($f -join '; '))"
  $f = @(Find-UnsafeBicepInputs @('infra/x/bad.bicepparam') $bt)
  Assert-Contains $f '*bad.bicepparam line 2 reads an environment variable' 'readEnvironmentVariable is refused'
  Assert-Contains $f '*bad.bicepparam line 3 asks the deploying tool for an external input' 'externalInput is refused'
  $f = @(Find-UnsafeBicepInputs @('infra/x/bad.bicep') $bt)
  Assert-Contains $f '*line 1 uses a module from a registry' 'a registry module is refused'
  Assert-Contains $f '*line 4 loads a file outside the repository' 'a load outside the repository is refused'
  Assert-Contains $f '*line 5 loads a file whose path is not plain text' 'a load with a computed path is refused'
  Assert-Contains $f '*line 6 loads a file outside the repository' 'a load of an absolute path is refused'
  Assert-Contains $f '*line 7 loads a file whose path is not plain text' 'a load of a path with a drive letter is refused'
  Assert-Contains $f '*line 8 uses a \u{...} escape*' 'an escape in a path is refused'
  Assert-Contains $f '*line 8 loads a file whose path is not plain text' 'and so is the escaped path itself'
  Assert-Contains $f '*line 9 loads a file outside the repository' 'code after a block comment on the same line is read'
  Assert-Contains $f '*line 10 calls loadResourceContent, a load function this check does not know' 'an unknown load function is refused'
  $routine = @(@($units.units) | Where-Object { -not (Get-HandRouteReason $_) -or (Test-SubscriptionMainUnit $_) })
  $rmap = Get-UnitFiles ([pscustomobject]@{ units = $routine }) $repo
  $f = @(); foreach ($u in $routine) { $f += @(Find-UnsafeBicepInputs @($rmap[[string]$u.name]) $repo) }
  Assert-Equal 0 $f.Count "the units a pull request can preview use none of these inputs ($($f -join '; '))"
  Push-Location $repo; $trackedBicep = @(git ls-files '*.bicep' '*.bicepparam'); Pop-Location
  $f = @(Find-UnsafeBicepInputs $trackedBicep $repo)
  Assert-True ($trackedBicep.Count -gt 5 -and $f.Count -eq 0) "every Bicep file of the repository passes, as the check reads the whole checkout ($($trackedBicep.Count) files, $($f -join '; '))"
  $code = [MirrorPipeline.BicepText]::BlankComments("var a = 'x // y' // z`n/* q`nr */ var b = '`${'}'}' /* s */ var c = 1")
  Assert-Equal "var a = 'x // y'     `n    `n     var b = '`${'}'}'         var c = 1" $code 'comments are blanked the way Bicep reads them, strings and interpolations are kept'
  # The InputCheck mode as the preview job runs it, on a copy of the helper beside one unit whose parameter file
  # reads an environment variable.
  New-Item -ItemType Directory -Path (Join-Path $bt '.github/scripts'), (Join-Path $bt 'deploy') -Force | Out-Null
  Copy-Item -LiteralPath $helper -Destination (Join-Path $bt '.github/scripts/mirror-pipeline.ps1')
  [IO.File]::WriteAllText((Join-Path $bt 'deploy/units.json'), '{ "units": [ { "name": "x", "kind": "resourceGroup", "template": "infra/x/good.bicep", "parameters": "infra/x/bad.bicepparam", "enabled": false } ] }')
  $ev = Join-Path $bt 'evidence'
  $prevVars = @{}; foreach ($k in @('UNIT', 'PREVIEW_MODE', 'MIRROR_TRUSTED_COMMIT', 'MIRROR_CODE_COMMIT')) { $prevVars[$k] = [Environment]::GetEnvironmentVariable($k) }
  [Environment]::SetEnvironmentVariable('UNIT', 'x'); [Environment]::SetEnvironmentVariable('PREVIEW_MODE', 'code')
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $null = & $childExe @childArgs -File (Join-Path $bt '.github/scripts/mirror-pipeline.ps1') -Mode InputCheck -EvidenceRoot $ev 2>&1; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prevEap; foreach ($k in $prevVars.Keys) { [Environment]::SetEnvironmentVariable($k, $prevVars[$k]) } }
  $vm = Join-Path $ev 'verdict.md'
  Assert-True ($code -eq 2 -and (Test-Path -LiteralPath $vm) -and ([IO.File]::ReadAllText($vm) -like '*Could not preview.*not previewed with the reader identity*reads an environment variable*')) "inputcheck: a branch unit that reads an environment variable is refused with a verdict (exit $code)"
  [Environment]::SetEnvironmentVariable('MIRROR_TRUSTED_COMMIT', ('a' * 40)); [Environment]::SetEnvironmentVariable('MIRROR_CODE_COMMIT', ('a' * 40))
  Assert-True (Test-CodeIsTrusted) 'code at the trusted commit is not checked again'
  [Environment]::SetEnvironmentVariable('MIRROR_CODE_COMMIT', ('b' * 40))
  Assert-True (-not (Test-CodeIsTrusted)) 'code from another commit is checked'
  [Environment]::SetEnvironmentVariable('MIRROR_TRUSTED_COMMIT', $null)
  Assert-True (-not (Test-CodeIsTrusted)) 'without a trusted commit the code is checked'
} finally {
  [Environment]::SetEnvironmentVariable('MIRROR_TRUSTED_COMMIT', $null); [Environment]::SetEnvironmentVariable('MIRROR_CODE_COMMIT', $null)
  Remove-Item -LiteralPath $bt -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- Bicep inputs from a branch: ways round a reference-following check'
# Each case is a checkout of its own: a copy of the helper, deploy/units.json and the case's Bicep files, with a
# secret.txt beside the checkout (outside the repository). The check reads the whole checkout, so each case must be
# refused however the file that loads the secret is reached.
$cases = Join-Path ([IO.Path]::GetTempPath()) ('mirror-cases-' + [guid]::NewGuid().ToString('N'))
function Invoke-InputCase([string]$Name, [hashtable]$Files, [string]$UnitsJson, [string]$Unit, [int]$Expect, [string]$Pattern) {
  $d = Join-Path $cases ($Name -replace '[^a-z0-9]', '-')
  $r = Join-Path $d 'repo'
  New-Item -ItemType Directory -Force -Path (Join-Path $r '.github/scripts'), (Join-Path $r 'deploy') | Out-Null
  [IO.File]::WriteAllText((Join-Path $d 'secret.txt'), 'SECRET')
  Copy-Item -LiteralPath $helper -Destination (Join-Path $r '.github/scripts/mirror-pipeline.ps1')
  [IO.File]::WriteAllText((Join-Path $r 'deploy/units.json'), $UnitsJson)
  foreach ($k in $Files.Keys) {
    $p = Join-Path $r (ConvertTo-NativePath $k); New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    [IO.File]::WriteAllText($p, [string]$Files[$k])
  }
  $prev = @{}; foreach ($k in @('UNIT', 'PREVIEW_MODE', 'MIRROR_TRUSTED_COMMIT', 'MIRROR_CODE_COMMIT')) { $prev[$k] = [Environment]::GetEnvironmentVariable($k) }
  [Environment]::SetEnvironmentVariable('UNIT', $(if ($Unit) { $Unit } else { $null })); [Environment]::SetEnvironmentVariable('PREVIEW_MODE', 'code')
  [Environment]::SetEnvironmentVariable('MIRROR_TRUSTED_COMMIT', ('a' * 40)); [Environment]::SetEnvironmentVariable('MIRROR_CODE_COMMIT', ('b' * 40))
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = (& $childExe @childArgs -File (Join-Path $r '.github/scripts/mirror-pipeline.ps1') -Mode InputCheck 2>&1 | ForEach-Object { "$_" }) -join "`n"; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prevEap; foreach ($k in $prev.Keys) { [Environment]::SetEnvironmentVariable($k, $prev[$k]) } }
  Assert-True ($code -eq $Expect -and $out -like $Pattern) "inputcheck: $Name (exit $code, expected $Expect)"
}
$oneUnit = '{ "units": [ { "name": "u", "kind": "resourceGroup", "template": "infra/t.bicep", "enabled": true } ] }'
$child = "var s = loadTextContent('../../../secret.txt')`noutput s string = s`n"
try {
  Invoke-InputCase 'a clean unit passes' @{ 'infra/t.bicep' = "/* a comment */ module m './sub/child.bicep' = {`n  name: 'm'`n}`n"; 'infra/sub/child.bicep' = "output s string = 'x'`n" } $oneUnit 'u' 0 '*None reads an environment variable*'
  Invoke-InputCase 'a module after a block comment' @{ 'infra/t.bicep' = "/* c */ module m './sub/child.bicep' = {`n  name: 'm'`n}`n"; 'infra/sub/child.bicep' = $child } $oneUnit 'u' 2 '*infra/sub/child.bicep line 1 loads a file outside the repository*'
  Invoke-InputCase 'a block comment between the symbol and the path' @{ 'infra/t.bicep' = "module m /* c */ './sub/child.bicep' = {`n  name: 'm'`n}`n"; 'infra/sub/child.bicep' = $child } $oneUnit 'u' 2 '*infra/sub/child.bicep line 1 loads a file outside the repository*'
  Invoke-InputCase 'a module path in a multi-line string' @{ 'infra/t.bicep' = "module m '''./sub/child.bicep''' = {`n  name: 'm'`n}`n"; 'infra/sub/child.bicep' = $child } $oneUnit 'u' 2 '*infra/t.bicep line 1 uses a multi-line string*'
  Invoke-InputCase 'an escaped module path' @{ 'infra/t.bicep' = "module m './sub/chi\u{6C}d.bicep' = {`n  name: 'm'`n}`n"; 'infra/sub/child.bicep' = $child } $oneUnit 'u' 2 '*infra/sub/child.bicep line 1 loads a file outside the repository*'
  Invoke-InputCase 'an escaped load path in the template itself' @{ 'infra/t.bicep' = "var s = loadTextContent('sub\u{2F}\u{2E}\u{2E}/../../../secret.txt')`n" } $oneUnit 'u' 2 '*infra/t.bicep line 1 uses a \u{...} escape*'
  Invoke-InputCase 'a parameters file that extends another' @{ 'infra/t.bicep' = "param p string`n"; 'infra/leaf.bicepparam' = "using './t.bicep'`nextends './base.bicepparam'`n"; 'infra/base.bicepparam' = "using none`nparam p = readEnvironmentVariable('LEAKME', 'none')`n" } '{ "units": [ { "name": "u", "kind": "resourceGroup", "template": "infra/t.bicep", "parameters": "infra/leaf.bicepparam" } ] }' 'u' 2 '*infra/base.bicepparam line 2 reads an environment variable*'
  Invoke-InputCase 'an import written over several lines' @{ 'infra/t.bicep' = "import {`n  leaked`n} from './lib.bicep'`noutput o string = leaked`n"; 'infra/lib.bicep' = "@export()`nvar leaked = loadTextContent('../../secret.txt')`n" } $oneUnit 'u' 2 '*infra/lib.bicep line 2 loads a file outside the repository*'
  Invoke-InputCase 'a disabled measuredWith unit, in the drift check with no UNIT' @{ 'infra/t.bicep' = "output o string = 'x'`n"; 'infra/sib.bicep' = $child.Replace('../../../', '../../') } '{ "units": [ { "name": "routine", "kind": "resourceGroup", "template": "infra/t.bicep", "enabled": true, "measuredWith": [ "routine-deploy-excluded" ] }, { "name": "routine-deploy-excluded", "kind": "resourceGroup", "template": "infra/sib.bicep", "enabled": false, "route": "hand" } ] }' '' 2 '*infra/sib.bicep line 1 loads a file outside the repository*'
  Invoke-InputCase 'a unit name and a measuredWith entry that climb out of the evidence folder' @{ 'infra/t.bicep' = "output o string = 'x'`n" } '{ "units": [ { "name": "u", "kind": "resourceGroup", "template": "infra/t.bicep", "enabled": true, "measuredWith": [ "../../m" ] }, { "name": "x/../../../escaped-2", "kind": "resourceGroup", "template": "infra/t.bicep", "enabled": false } ] }' 'u' 2 "*u: the measuredWith entry '../../m' is not lower-case letters*the unit name 'x/../../../escaped-2' is not lower-case letters*"
  Invoke-InputCase 'a unit name in another case' @{ 'infra/t.bicep' = "output o string = 'x'`n" } '{ "units": [ { "name": "Mixed-Case", "kind": "resourceGroup", "template": "infra/t.bicep", "enabled": true } ] }' 'mixed-case' 2 "*UNIT 'mixed-case' must name exactly one unit*"
  Invoke-InputCase 'a bicepconfig.json in a subfolder and an extension alias' @{ 'infra/t.bicep' = "extension evil`n"; 'infra/bicepconfig.json' = '{ "extensions": { "evil": "br:attackerreg123.azurecr.io/bicep/ext:1.0.0" } }' } $oneUnit 'u' 2 '*infra/bicepconfig.json is a Bicep configuration file below the repository root*declares a Bicep extension*'
} finally {
  Remove-Item -LiteralPath $cases -Recurse -Force -ErrorAction SilentlyContinue
}
$e = @(Test-WorkflowHygiene @{ 'mirror-drift.yml' = "jobs:`n  a:`n    steps:`n      - uses: azure/login@x`n" })
Assert-Contains $e 'mirror-drift.yml: the step "Check the Bicep inputs" must run*' 'a reader job without the input check is refused'

Write-Host '--- references, parameters files and data-access grants'
$rt = Join-Path ([IO.Path]::GetTempPath()) ('mirror-refs-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path (Join-Path $rt 'infra/sub') | Out-Null
try {
  [IO.File]::WriteAllText((Join-Path $rt 'infra/t.bicep'), "/* c */ module a './sub/a.bicep' = {`n  name: 'a'`n}`nmodule b /* c */ './sub/b.bicep' = {`n  name: 'b'`n}`nimport {`n  x`n} from './sub/c.bicep'`n// module d './sub/d.bicep' = {}`n")
  [IO.File]::WriteAllText((Join-Path $rt 'infra/leaf.bicepparam'), "using './t.bicep'`nextends './base.bicepparam'`n")
  $u = [pscustomobject]@{ units = @([pscustomobject]@{ name = 'u'; template = 'infra/t.bicep'; parameters = 'infra/leaf.bicepparam' }) }
  $set = @((Get-UnitFiles $u $rt)['u'] | Sort-Object)
  Assert-Equal 'infra/base.bicepparam,infra/leaf.bicepparam,infra/sub/a.bicep,infra/sub/b.bicep,infra/sub/c.bicep,infra/t.bicep' ($set -join ',') 'a unit reaches modules after block comments, multi-line imports and extends, not commented-out lines'
  $r = Resolve-AffectedUnits @('infra/sub/bicepconfig.json') $units (Get-UnitFiles $units $repo)
  Assert-True ($r.sweep -and @($r.preview).Count -eq 0) 'a bicepconfig.json in a subfolder asks for a sweep'
  [IO.File]::WriteAllText((Join-Path $rt 'infra/other.bicepparam'), "// using './nothing.bicep'`nusing './sub/a.bicep'`n")
  Assert-Equal ([IO.Path]::GetFullPath((Join-Path $rt 'infra/sub/a.bicep'))) (Get-BicepparamUsing (Join-Path $rt 'infra/other.bicepparam')) 'the using line of a parameters file names the template Azure deploys'
  # Bicep 0.48.1 (bicep build-params) compiles ./sub/a.bicep from each of the next three files. The earlier using
  # line, at the start of its own line, is inside a block comment in the first and the third, and inside a
  # multi-line string in the second, so Bicep does not read it as a statement. In the third, the multi-line string
  # ends with four quotes. Bicep keeps the fourth in the string (s is x'), so the block comment after it is a comment.
  [IO.File]::WriteAllText((Join-Path $rt 'infra/block.bicepparam'), "/*`nusing './nothing.bicep'`n*/`nusing './sub/a.bicep'`nparam p = 'x'`n")
  Assert-Equal ([IO.Path]::GetFullPath((Join-Path $rt 'infra/sub/a.bicep'))) (Get-BicepparamUsing (Join-Path $rt 'infra/block.bicepparam')) 'a using line inside a block comment is not the one Bicep compiles'
  [IO.File]::WriteAllText((Join-Path $rt 'infra/mls.bicepparam'), "var s = '''`nusing './nothing.bicep'`n'''`nusing './sub/a.bicep'`nparam p = 'x'`n")
  Assert-Equal ([IO.Path]::GetFullPath((Join-Path $rt 'infra/sub/a.bicep'))) (Get-BicepparamUsing (Join-Path $rt 'infra/mls.bicepparam')) 'a using line inside a multi-line string is not the one Bicep compiles'
  [IO.File]::WriteAllText((Join-Path $rt 'infra/quote.bicepparam'), "var s = '''x''''`n/*`nusing './nothing.bicep'`n*/`nusing './sub/a.bicep'`nparam p = s`n")
  Assert-Equal ([IO.Path]::GetFullPath((Join-Path $rt 'infra/sub/a.bicep'))) (Get-BicepparamUsing (Join-Path $rt 'infra/quote.bicepparam')) 'a quote right after the end of a multi-line string stays in the string, so a block comment after it is a comment'
  Assert-Equal ("a = '''x`ny'''" + (' ' * 5)) ([MirrorPipeline.BicepText]::BlankComments("a = '''x`ny''' // z")) 'the input check still reads the inside of a multi-line string'
  Assert-Equal ('a =' + (' ' * 5) + "`n" + (' ' * 9)) ([MirrorPipeline.BicepText]::BlankCommentsAndMultiLineStrings("a = '''x`ny''' // z")) 'the using reader blanks a multi-line string and keeps its line breaks'
  Assert-Equal ("a = '''x''''" + (' ' * 7) + ' b') ([MirrorPipeline.BicepText]::BlankComments("a = '''x''''/* c */ b")) 'the input check takes the quotes right after a multi-line string into it and blanks the comment after them'
  Assert-Equal ('a =' + (' ' * 16) + ' b') ([MirrorPipeline.BicepText]::BlankCommentsAndMultiLineStrings("a = '''x''''/* c */ b")) 'the using reader blanks a multi-line string with its extra closing quote and the comment after it'
} finally {
  Remove-Item -LiteralPath $rt -Recurse -Force -ErrorAction SilentlyContinue
}
$g = '{ "resources": { "kv": { "type": "Microsoft.KeyVault/vaults", "name": "kv" }, "ap": { "type": "Microsoft.KeyVault/vaults/accessPolicies", "name": "kv/add" }, "ra": { "type": "Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments", "name": "db/x" }, "ad": { "type": "Microsoft.Sql/servers/administrators", "existing": true, "name": "s/ActiveDirectory" } } }' | ConvertFrom-Json
$hits = @(Find-DataAccessGrants $g)
Assert-Equal 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments (ra),Microsoft.KeyVault/vaults/accessPolicies (ap)' (($hits | Sort-Object) -join ',') 'an access policy child and a Cosmos DB data-plane role assignment are data-access grants, an existing reference is not'
Assert-True (@($script:KnownDataGrants).Count -eq 0) 'no data-access grant is known, so a pipeline unit declaring one is refused'

Write-Host '--- hardening checks'
Assert-Equal 'a | ::warning::b | c | d' (ConvertTo-OneLine ("a`r::warning::b" + [char]0x2028 + "c`r`nd")) 'a lone carriage return or a line separator cannot start a workflow command line'

Write-Host '--- the deploy workflow rules'
$goodDeploy = "on:`n  push:`n    branches: [ master ]`n  workflow_dispatch:`n    inputs: {}`njobs:`n  plan:`n    environment:`n      name: mirror-reader-dispatch`n    permissions:`n      id-token: write`n  apply:`n    needs: collect`n    environment: mirror-production-`${{ matrix.subscription }}`n    permissions:`n      id-token: write`n"
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy } | Where-Object { $_ -notlike '*runner check*' -and $_ -notlike '*pipeline switch*' -and $_ -notlike '*Check the Bicep inputs*' -and $_ -notlike '*run step*' })
Assert-Equal 0 $e.Count "a deploy workflow that starts on a push to master and by Run workflow, with the apply as the only production job, passes ($($e -join '; '))"
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace('  workflow_dispatch:', '  schedule:') })
Assert-Contains $e '*has no schedule or pull_request trigger*' 'a schedule on the deploy workflow is refused'
Assert-Contains $e '*must start on push with branches `[ master `] and on workflow_dispatch*' 'a deploy workflow without Run workflow is refused'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace('branches: [ master ]', 'branches: [ master, dev ]') })
Assert-Contains $e '*must start on push with branches `[ master `]*' 'a push trigger on another branch is refused'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace('workflow_dispatch:', "pull_request:`n  workflow_dispatch:") })
Assert-Contains $e '*has no schedule or pull_request trigger*' 'a pull request trigger on the deploy workflow is refused'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace('mirror-production-${{ matrix.subscription }}', 'mirror-production-demo') })
Assert-Contains $e '*the apply job must have environment: mirror-production-*matrix.subscription*' 'the apply job may not name a fixed production environment'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace('needs: collect', 'needs: plan') })
Assert-Contains $e '*the apply job must need the collect job*' 'the apply job must wait for the collect job'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace('name: mirror-reader-dispatch', 'name: mirror-production-demo') })
Assert-Contains $e '*the job plan names a mirror-production environment, and only the apply job may*' 'the plan job may not name a production environment'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace("    environment:`n      name: mirror-reader-dispatch`n", '') })
Assert-Contains $e '*the job plan requests id-token: write and has no environment*' 'a job that asks for a token without an environment is refused'
$e = @(Test-WorkflowHygiene @{ 'v.yml' = "permissions:`n  contents: read`n  id-token: write`njobs:`n  a:`n    runs-on: windows-2025`n" })
Assert-Contains $e '*requests id-token in its top-level permissions*' 'a token for every job is refused'
$e = @(Test-WorkflowHygiene @{ 'x.yml' = "jobs:`n  apply:`n    environment: mirror-production-demo`n" })
Assert-Contains $e 'x.yml: names a mirror-production*' 'another workflow may not name a production environment'
$e = @(Test-WorkflowHygiene @{ 'mirror-pr.yml' = "jobs:`n  a:`n    steps:`n      - uses: azure/login@x`n      - name: Take the scripts from master`n      - name: Check the Bicep inputs`n        run: mirror-pipeline.ps1 -Mode InputCheck`n" })
Assert-Contains $e 'mirror-pr.yml: the step "Take the scripts from master" must come before the Azure sign-in' 'the reader jobs take master''s scripts before the sign-in'
Assert-Contains $e 'mirror-pr.yml: the step "Check the Bicep inputs" must come before the Azure sign-in' 'and check the Bicep inputs before it'
$e = @(Test-WorkflowHygiene @{ 'mirror-drift.yml' = "jobs:`n  a:`n    steps:`n      - uses: azure/login@x`n" })
Assert-Contains $e 'mirror-drift.yml: the step "Check the Bicep inputs" must run*' 'a reader job without the input check is refused'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace("jobs:`n", "jobs:`n  select:`n    steps:`n      - run: x`n") })
Assert-Contains $e '*the step "Check the Bicep inputs" must come before the Azure sign-in*' 'the deploy workflow checks the Bicep inputs before it signs in'

Write-Host '--- the deploy modes, on a temporary repository with recorded GitHub answers'
$g = Join-Path ([IO.Path]::GetTempPath()) ('mirror-git-' + [guid]::NewGuid().ToString('N'))
# The answers and the runner live beside the repository, not in it, so they are never part of a commit.
$gx = "$g-files"
New-Item -ItemType Directory -Path $g, $gx | Out-Null
$keepRoot = $script:RepoRoot
function Invoke-TestGit { $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  $o = & git -C $g -c user.name=t -c user.email=t@example.invalid -c core.autocrlf=false @args 2>&1 | ForEach-Object { "$_" }
  $c = $LASTEXITCODE; $ErrorActionPreference = $prev
  if ($c -ne 0) { throw "git $($args -join ' '): $o" }
  return (@($o) -join "`n").Trim() }
function Write-TestFile([string]$Rel, [string]$Text) { $p = Join-Path $g (ConvertTo-NativePath $Rel); New-Item -ItemType Directory -Force (Split-Path -Parent $p) | Out-Null; [IO.File]::WriteAllText($p, $Text) }
try {
  Invoke-TestGit init -q -b master | Out-Null
  Write-TestFile '.github/scripts/mirror-pipeline.ps1' ([IO.File]::ReadAllText($helper))
  Write-TestFile 'deploy/units.json' (ConvertTo-Json $unitsOn -Depth 20)
  Write-TestFile 'deploy/boundaries.json' ([IO.File]::ReadAllText((Join-Path $repo 'deploy/boundaries.json')))
  Write-TestFile 'pipelines/pilot/empty-rg.bicep' '// pilot'
  Write-TestFile 'README.md' 'one'
  Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c1 | Out-Null
  $c1 = Invoke-TestGit rev-parse HEAD
  Write-TestFile 'pipelines/pilot/empty-rg.bicep' '// pilot, changed'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c2 | Out-Null
  $c2 = Invoke-TestGit rev-parse HEAD
  Write-TestFile 'README.md' 'two'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c3 | Out-Null
  $c3 = Invoke-TestGit rev-parse HEAD
  Write-TestFile 'deploy/units.json' (ConvertTo-Json $units -Depth 20); Write-TestFile 'pipelines/pilot/empty-rg.bicep' '// pilot, changed again'
  Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c4 | Out-Null
  $c4 = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c2 | Out-Null

  $runner = Join-Path $gx 'run-mode.ps1'
  [IO.File]::WriteAllText($runner, @'
param([string]$Mode, [string]$Dir, [string]$EvidenceRoot)
function global:gh {
  $p = [string]$args[-1]
  $name = if ($p -match '/branches/master') { 'branch' } elseif ($p -match '/commits/[^/]+/pulls') { 'pulls' } else { 'none' }
  $f = Join-Path $env:TEST_ANSWERS "$name.json"
  if (-not (Test-Path $f)) { $global:LASTEXITCODE = 1; return }
  $global:LASTEXITCODE = 0; [IO.File]::ReadAllText($f)
}
$helperArgs = @{ Mode = $Mode }
if ($Dir) { $helperArgs.Dir = $Dir }
if ($EvidenceRoot) { $helperArgs.EvidenceRoot = $EvidenceRoot }
& (Join-Path $env:TEST_REPO '.github/scripts/mirror-pipeline.ps1') @helperArgs
exit $LASTEXITCODE
'@)
  function Invoke-TestMode([string]$Mode, [hashtable]$Vars, [string]$Name, [int]$Expect, [string]$Pattern, [string]$Dir = '', [hashtable]$Answers = @{}, [string]$Evidence = '') {
    $ans = Join-Path $gx ("mode-" + ($Name -replace '[^a-z]', '-')); New-Item -ItemType Directory -Force $ans | Out-Null
    foreach ($k in $Answers.Keys) { [IO.File]::WriteAllText((Join-Path $ans $k), $Answers[$k]) }
    $out = Join-Path $ans 'output.txt'; Set-Content -LiteralPath $out -Value ''
    $all = @{ TEST_REPO = $g; TEST_ANSWERS = $ans; GITHUB_OUTPUT = $out; GITHUB_STEP_SUMMARY = (Join-Path $ans 'summary.md'); GITHUB_REPOSITORY = 'org/repo'; GITHUB_REF = 'refs/heads/master'; GITHUB_ACTOR = 'it-user-one' }
    foreach ($k in $Vars.Keys) { $all[$k] = $Vars[$k] }
    $prevVars = @{}
    foreach ($k in $all.Keys) { $prevVars[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $runArgs = @($childArgs) + @('-File', $runner, '-Mode', $Mode)
      if ($Dir) { $runArgs += @('-Dir', $Dir) }
      if ($Evidence) { $runArgs += @('-EvidenceRoot', $Evidence) }
      $console = & $childExe @runArgs 2>&1 | ForEach-Object { "$_" }
      $code = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $prevEap
      foreach ($k in $all.Keys) { [Environment]::SetEnvironmentVariable($k, $prevVars[$k]) }
    }
    $text = ($console -join "`n") + [IO.File]::ReadAllText($out)
    $sumFile = Join-Path $ans 'summary.md'; if (Test-Path -LiteralPath $sumFile) { $text += [IO.File]::ReadAllText($sumFile) }
    Assert-True ($code -eq $Expect -and $text -like ('*' + [WildcardPattern]::Escape($Pattern) + '*')) "$($Mode.ToLowerInvariant()): $Name (exit $code, expected $Expect)"
  }

  # Select, on a push. The merged pull request answers with its title and body.
  $pulls = "[{`"number`":7,`"title`":`"Add a thing`",`"body`":`"Change: CHG0012345`",`"merged_at`":`"2026-11-01T10:00:00Z`",`"merge_commit_sha`":`"$c2`",`"base`":{`"ref`":`"master`"}}]"
  Invoke-TestMode 'Select' @{ EVENT_NAME = 'push'; BEFORE = $c1; AFTER = $c2 } 'a push that changes the template of an enabled unit plans it' 0 'matrix=[{"unit":"pilot-empty-rg"' -Answers @{ 'pulls.json' = $pulls }
  Invoke-TestMode 'Select' @{ EVENT_NAME = 'push'; BEFORE = $c1; AFTER = $c2 } 'the ticket and the reason come from the merged pull request' 0 '"changeRef":"CHG0012345","reason":"Merged pull request #7: Add a thing"' -Answers @{ 'pulls.json' = $pulls }
  Invoke-TestMode 'Select' @{ EVENT_NAME = 'push'; BEFORE = $c1; AFTER = $c2 } 'a push is started by the pusher and applies after review' 0 '"trigger":"push","apply":"true","startedBy":"it-user-one"' -Answers @{ 'pulls.json' = $pulls }
  Invoke-TestMode 'Select' @{ EVENT_NAME = 'push'; BEFORE = $c1; AFTER = $c2 } 'without a readable pull request the ticket is none' 0 '"changeRef":"none"'
  Invoke-TestMode 'Select' @{ EVENT_NAME = 'push'; BEFORE = $c2; AFTER = $c3 } 'a push that touches no unit plans nothing' 0 'matrix=[]'
  Invoke-TestGit checkout -q --detach $c4 | Out-Null
  Invoke-TestMode 'Select' @{ EVENT_NAME = 'push'; BEFORE = $c3; AFTER = $c4 } 'a unit that is not enabled is not planned' 0 '1 unit(s) this push touches are not enabled'
  Invoke-TestGit checkout -q --detach $c2 | Out-Null
  Invoke-TestMode 'Select' @{ EVENT_NAME = 'push'; BEFORE = $c1; AFTER = $c2; GITHUB_REF = 'refs/heads/dev' } 'a run on another branch is refused' 1 'The deployment runs only on master'
  # Select, by Run workflow.
  $disp = @{ EVENT_NAME = 'workflow_dispatch'; UNIT = 'pilot-empty-rg'; CHANGE_REF = 'CHG0012345'; REASON = 'Pilot.'; APPLY = 'true'; ACK = 'false'; ALLOW_CREATE = ''; ALLOW_MODIFY = ''; ALLOW_HELD = '' }
  Invoke-TestMode 'Select' $disp 'Run workflow plans the unit it names' 0 '"trigger":"Run workflow","apply":"true"'
  $d2 = $disp.Clone(); $d2['ALLOW_MODIFY'] = $inScope; $d2['ACK'] = 'true'
  Invoke-TestMode 'Select' $d2 'the options reach the row as JSON' 0 'allowModify\":[\"/subscriptions/'
  $d3 = $disp.Clone(); $d3['APPLY'] = 'false'
  Invoke-TestMode 'Select' $d3 'apply left off is a plan only' 0 '"apply":"false"'
  $d4 = $disp.Clone(); $d4['UNIT'] = 'no-such-unit'
  Invoke-TestMode 'Select' $d4 'an unknown unit is refused before any sign-in' 1 'is not in deploy/units.json'
  $d5 = $disp.Clone(); $d5['ALLOW_MODIFY'] = "/subscriptions/$subId/resourceGroups/Other/providers/x/y/z"
  Invoke-TestMode 'Select' $d5 'an ID outside the unit is refused' 1 "not inside the unit's scope"
  $d6 = $disp.Clone(); $d6['CHANGE_REF'] = 'a'
  Invoke-TestMode 'Select' $d6 'a change ticket that is too short is refused' 1 'changeRef must be the change ticket number'

  # Plan, the code pull request of mirror-pr. The test merge commit has master's tip as its first parent.
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Write-TestFile 'topic.txt' 'up to date'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m b2 | Out-Null
  $bUp = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Invoke-TestGit merge -q --no-ff -m m2 $bUp | Out-Null
  $mUp = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c1 | Out-Null
  Write-TestFile 'topic.txt' 'behind'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m b1 | Out-Null
  $bOld = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Invoke-TestGit merge -q --no-ff -m m1 $bOld | Out-Null
  $mOld = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c2 | Out-Null
  Invoke-TestGit update-ref refs/remotes/origin/master $c3 | Out-Null
  $pr = @{ BASE_REF = 'master'; HEAD_SHA = $bUp; MERGE_SHA = $mUp; HEAD_REPO = 'org/repo' }
  Invoke-TestMode 'Plan' $pr 'a pull request from a branch of the repository, built on the tip of master, is previewed' 0 'Code pull request:'
  $prFork = $pr.Clone(); $prFork['HEAD_REPO'] = 'someone/repo'
  Invoke-TestMode 'Plan' $prFork 'a pull request from a fork is refused' 1 "comes from the repository 'someone/repo'"
  $prNoRepo = $pr.Clone(); $prNoRepo['HEAD_REPO'] = ''
  Invoke-TestMode 'Plan' $prNoRepo 'a pull request with no head repository is refused' 1 'comes from the repository'
  $prOther = $pr.Clone(); $prOther['BASE_REF'] = 'dev'
  Invoke-TestMode 'Plan' $prOther 'a pull request into another branch is refused' 1 'previews only pull requests into master'
  Invoke-TestGit update-ref refs/remotes/origin/master $c2 | Out-Null
  Invoke-TestMode 'Plan' $pr 'master moved after the test merge was built' 1 "is not the base of this run's merge commit"
  Invoke-TestGit update-ref refs/remotes/origin/master $c3 | Out-Null
  $prBehind = $pr.Clone(); $prBehind['HEAD_SHA'] = $bOld; $prBehind['MERGE_SHA'] = $mOld
  Invoke-TestMode 'Plan' $prBehind 'a branch that does not contain the tip of master is refused' 1 'the branch is behind master'

  # DeployPlan, with a stand-in for the gate script that copies the gate result named in the environment.
  $stubDir = Join-Path $g 'scripts'; New-Item -ItemType Directory -Force $stubDir | Out-Null
  [IO.File]::WriteAllText((Join-Path $stubDir 'deploy-unit.ps1'), @'
param([string]$Unit, [string]$EvidenceRoot)
$d = Join-Path $EvidenceRoot 'r1'; New-Item -ItemType Directory -Force $d | Out-Null
Copy-Item -LiteralPath $env:STUB_GATE -Destination (Join-Path $d 'pre-gate.json')
[IO.File]::WriteAllText((Join-Path $d 'pre-summary.txt'), "Unit:       $Unit`nCommit:     $env:GITHUB_SHA`nMode:       dry run`nGate:       PASS`nCounts:     $env:STUB_COUNTS`n`n")
exit 0
'@)
  $gateNoChange = Join-Path $gx 'gate-nochange.json'; Copy-Item -LiteralPath (Join-Path $fixtures 'gate-pass.json') -Destination $gateNoChange
  $gateChange = Join-Path $gx 'gate-change.json'
  [IO.File]::WriteAllText($gateChange, '{ "overall": "pass", "problems": [], "counts": { "Create": 1 }, "failed": 0, "review": 0, "decisions": [ { "resourceId": "/subscriptions/s/resourceGroups/r/providers/Microsoft.Storage/storageAccounts/a", "type": "Microsoft.Storage/storageAccounts", "changeType": "Create", "verdict": "pass", "notes": [] } ] }')
  $tipNow = @{ 'branch.json' = "{`"commit`":{`"sha`":`"$c2`"}}" }
  $dp = @{ UNIT = 'pilot-empty-rg'; CHANGE_REF = 'CHG0012345'; REASON = 'Pilot, see [x](http://example.invalid) `code`'; GITHUB_SHA = $c2; APPLY = 'true'; STARTED_BY = 'it-user-one'; OPTIONS = '{}' }
  $ev = Join-Path $gx 'dp-push'
  $dpPush = $dp.Clone(); $dpPush['TRIGGER'] = 'push'; $dpPush['STUB_GATE'] = $gateNoChange; $dpPush['STUB_COUNTS'] = 'NoChange=3'
  Invoke-TestMode 'DeployPlan' $dpPush 'a push whose plan holds no effective change deploys nothing and waits for nobody' 0 'A push publishes this plan and deploys nothing' -Answers $tipNow -Evidence $ev
  Assert-True (-not ([bool]((ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $ev 'plan.json')))).offerApply))) 'the plan of a push without an effective change offers no apply'
  Assert-True ([IO.File]::ReadAllText((Join-Path $ev 'verdict.md')).Contains('- Reason: `Pilot, see [x](http://example.invalid) code`'))
  $span = Format-PlanMarkdown ([pscustomobject][ordered]@{ unit = 'u'; subscription = 's'; commit = ('a' * 40); trigger = 'push'; startedBy = 'x'; changeRef = 'CHG1'; reason = 'a `b` [l](http://e.invalid) <img src=x onerror=y>'; options = [ordered]@{ acknowledgeReview = $false; allowCreate = @(); allowModify = @(); allowHeld = @() } }) (New-Verdict 'u' 'plan' 2 '')
  $rl = @($span -split "`n" | Where-Object { $_ -like '- Reason: *' })
  Assert-True ($rl.Count -eq 1 -and $rl[0] -ceq '- Reason: `a b [l](http://e.invalid) <img src=x onerror=y>`' -and ($rl[0].Substring(10).Trim('`')).IndexOf('`') -lt 0) 'a reason with a backtick, a link and an HTML tag is one code span with no backtick inside' 'the reason is written as a code span with its backticks removed'
  $ev = Join-Path $gx 'dp-push-change'
  $dpPush2 = $dpPush.Clone(); $dpPush2['STUB_GATE'] = $gateChange; $dpPush2['STUB_COUNTS'] = 'Create=1'
  Invoke-TestMode 'DeployPlan' $dpPush2 'a push whose plan holds an effective change waits for a reviewer' 0 'The apply job waits for the reviewers' -Answers $tipNow -Evidence $ev
  Assert-True ([bool]((ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $ev 'plan.json')))).offerApply)) 'the plan of a push with an effective change offers the apply'
  $ev = Join-Path $gx 'dp-run'
  $dpRun = $dp.Clone(); $dpRun['TRIGGER'] = 'Run workflow'; $dpRun['STUB_GATE'] = $gateNoChange; $dpRun['STUB_COUNTS'] = 'NoChange=3'
  Invoke-TestMode 'DeployPlan' $dpRun 'Run workflow with apply on and no effective change says so and still waits for a reviewer' 0 'No effective change' -Answers $tipNow -Evidence $ev
  Assert-True ([bool]((ConvertFrom-Json ([IO.File]::ReadAllText((Join-Path $ev 'plan.json')))).offerApply)) 'Run workflow with apply on offers the apply of a passing plan'
  $ev = Join-Path $gx 'dp-run-off'
  $dpOff = $dpRun.Clone(); $dpOff['APPLY'] = 'false'
  Invoke-TestMode 'DeployPlan' $dpOff 'Run workflow with apply off is a plan only' 0 'started as a plan only' -Answers $tipNow -Evidence $ev
  Remove-Item -LiteralPath $stubDir -Recurse -Force

  # CheckApply, in the checkout of the planned commit $c2.
  $pd = Join-Path $gx 'plan-ok'; New-Item -ItemType Directory -Force (Join-Path $pd 'gate/r1') | Out-Null
  $planned = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
  function New-PlanJson([string]$Sha, [string]$Time, [bool]$Offer = $true) {
    return (ConvertTo-Json -Depth 6 ([ordered]@{ schema = 1; unit = 'pilot-empty-rg'; subscription = $pilotSub; commit = $Sha; planned = $Time; trigger = 'push'; startedBy = 'it-user-one'
      changeRef = 'CHG0012345'; reason = 'Pilot.'; applyRequested = $true
      options = [ordered]@{ acknowledgeReview = $false; allowCreate = @(); allowModify = @(); allowHeld = @() }
      gate = 'PASS'; counts = 'Create=1'; approvable = $true; hasChanges = $true; offerApply = $Offer }))
  }
  [IO.File]::WriteAllText((Join-Path $pd 'plan.json'), (New-PlanJson $c2 $planned))
  [IO.File]::WriteAllText((Join-Path $pd 'gate/r1/pre-summary.txt'), "Unit:       pilot-empty-rg`nCommit:     $c2`nTaken:      2026-11-01 10:00:00Z`nMode:       dry run`nGate:       PASS`nCounts:     Create=1`n`nPASS    Create   x`n")
  [IO.File]::WriteAllText((Join-Path $pd 'gate/r1/pre-gate.json'), [IO.File]::ReadAllText((Join-Path $fixtures 'gate-pass.json')))
  $tip = "{`"commit`":{`"sha`":`"$c2`"}}"
  $ca = @{ UNIT = 'pilot-empty-rg'; GITHUB_SHA = $c2; GITHUB_RUN_ATTEMPT = '1' }
  Invoke-TestMode 'CheckApply' $ca 'a plan reviewed at the commit master still holds can be applied' 0 'checked after the approval' $pd -Answers @{ 'branch.json' = $tip }
  Invoke-TestMode 'CheckApply' $ca 'master moved after the plan' 1 'master moved to' $pd -Answers @{ 'branch.json' = "{`"commit`":{`"sha`":`"$c3`"}}" }
  $ca2 = $ca.Clone(); $ca2['GITHUB_RUN_ATTEMPT'] = '2'
  Invoke-TestMode 'CheckApply' $ca2 're-runs never deploy' 2 're-runs never deploy' $pd -Answers @{ 'branch.json' = $tip }
  $ca3 = $ca.Clone(); $ca3['GITHUB_SHA'] = $c3
  Invoke-TestMode 'CheckApply' $ca3 'a checkout that is not the run commit' 2 'checked out' $pd -Answers @{ 'branch.json' = $tip }
  $old = Join-Path $gx 'plan-old'; Copy-Item -LiteralPath $pd -Destination $old -Recurse
  [IO.File]::WriteAllText((Join-Path $old 'plan.json'), (New-PlanJson $c2 ([DateTimeOffset]::UtcNow.AddHours(-30).ToString('o'))))
  Invoke-TestMode 'CheckApply' $ca 'a plan older than the limit' 1 'hours old' $old -Answers @{ 'branch.json' = $tip }
  $caLong = $ca.Clone(); $caLong['MIRROR_MAX_PLAN_AGE_HOURS'] = '48'
  Invoke-TestMode 'CheckApply' $caLong 'the limit follows MIRROR_MAX_PLAN_AGE_HOURS' 0 'checked after the approval' $old -Answers @{ 'branch.json' = $tip }
  $subBad = Join-Path $gx 'plan-othersub'; Copy-Item -LiteralPath $pd -Destination $subBad -Recurse
  $pj = (New-PlanJson $c2 $planned) | ConvertFrom-Json; $pj.subscription = 'demo-other'
  [IO.File]::WriteAllText((Join-Path $subBad 'plan.json'), (ConvertTo-Json -InputObject $pj -Depth 6))
  Invoke-TestMode 'CheckApply' $ca 'a plan that names another subscription folder than units.json' 1 'names the subscription folder' $subBad -Answers @{ 'branch.json' = $tip }
  $nof = Join-Path $gx 'plan-nooffer'; Copy-Item -LiteralPath $pd -Destination $nof -Recurse
  [IO.File]::WriteAllText((Join-Path $nof 'plan.json'), (New-PlanJson $c2 $planned $false))
  Invoke-TestMode 'CheckApply' $ca 'a plan that offered no apply' 1 'did not offer an apply' $nof -Answers @{ 'branch.json' = $tip }
  $wrongSum = Join-Path $gx 'plan-wrongcommit'; Copy-Item -LiteralPath $pd -Destination $wrongSum -Recurse
  [IO.File]::WriteAllText((Join-Path $wrongSum 'gate/r1/pre-summary.txt'), "Unit:       pilot-empty-rg`nCommit:     $c1`nMode:       dry run`nGate:       PASS`n`n")
  Invoke-TestMode 'CheckApply' $ca 'a dry run taken at another commit' 1 'the plan was taken at' $wrongSum -Answers @{ 'branch.json' = $tip }
  $failGate = Join-Path $gx 'plan-failgate'; Copy-Item -LiteralPath $pd -Destination $failGate -Recurse
  [IO.File]::WriteAllText((Join-Path $failGate 'gate/r1/pre-gate.json'), [IO.File]::ReadAllText((Join-Path $fixtures 'gate-fail.json')))
  Invoke-TestMode 'CheckApply' $ca 'a gate file that is not approvable' 1 'is not approvable' $failGate -Answers @{ 'branch.json' = $tip }
  $dirty = Join-Path $g 'stray.txt'; [IO.File]::WriteAllText($dirty, 'x')
  Invoke-TestMode 'CheckApply' $ca 'a working tree that is not clean' 2 'the working tree is not clean' $pd -Answers @{ 'branch.json' = $tip }
  Remove-Item -LiteralPath $dirty -Force
  # The unit is disabled at the checked out commit.
  Invoke-TestGit checkout -q --detach $c4 | Out-Null
  $ca4 = $ca.Clone(); $ca4['GITHUB_SHA'] = $c4
  $pd4 = Join-Path $gx 'plan-c4'; Copy-Item -LiteralPath $pd -Destination $pd4 -Recurse
  [IO.File]::WriteAllText((Join-Path $pd4 'plan.json'), (New-PlanJson $c4 $planned))
  [IO.File]::WriteAllText((Join-Path $pd4 'gate/r1/pre-summary.txt'), "Unit:       pilot-empty-rg`nCommit:     $c4`nMode:       dry run`nGate:       PASS`n`n")
  Invoke-TestMode 'CheckApply' $ca4 'a unit disabled since the plan' 1 'is disabled in deploy/units.json' $pd4 -Answers @{ 'branch.json' = "{`"commit`":{`"sha`":`"$c4`"}}" }
  Invoke-TestGit checkout -q --detach $c2 | Out-Null

  # Collect.
  $cd = Join-Path $gx 'plans'
  foreach ($n in @('a', 'b')) { New-Item -ItemType Directory -Force (Join-Path $cd "reviewed-plan-$n") | Out-Null }
  $defA = @($unitsOn.units)[0]; $defB = @($unitsOn.units)[1]
  $pa = (New-PlanJson $c2 $planned) | ConvertFrom-Json; $pa.unit = [string]$defA.name; $pa.subscription = [string]$defA.subscription
  $pb = (New-PlanJson $c2 $planned $false) | ConvertFrom-Json; $pb.unit = [string]$defB.name; $pb.subscription = [string]$defB.subscription; $pb.approvable = $false
  [IO.File]::WriteAllText((Join-Path $cd 'reviewed-plan-a/plan.json'), (ConvertTo-Json -InputObject $pa -Depth 6))
  [IO.File]::WriteAllText((Join-Path $cd 'reviewed-plan-b/plan.json'), (ConvertTo-Json -InputObject $pb -Depth 6))
  $matrix = ConvertTo-Json -Compress @([ordered]@{ unit = [string]$defA.name }, [ordered]@{ unit = [string]$defB.name }, [ordered]@{ unit = 'unit-c' })
  Invoke-TestMode 'Collect' @{ GITHUB_SHA = $c2; MATRIX = $matrix } 'only the plan that offered an apply waits for a reviewer' 0 ('applyMatrix=[{"unit":"' + $defA.name + '","subscription":"' + $defA.subscription + '"}]') $cd
  Invoke-TestMode 'Collect' @{ GITHUB_SHA = $c2; MATRIX = $matrix } 'a plan that did not finish is named' 0 '| unit-c | none | none | The plan did not finish' $cd
  Invoke-TestMode 'Collect' @{ GITHUB_SHA = $c2; MATRIX = $matrix } 'a plan that is not approvable says so' 0 ('| ' + $defB.name + ' | PASS | Create=1 | Not approvable') $cd
  Invoke-TestMode 'Collect' @{ GITHUB_SHA = $c3; MATRIX = $matrix } 'a plan of another commit applies nothing' 0 'applyMatrix=[]' $cd
  $pa.subscription = 'demo-other'; [IO.File]::WriteAllText((Join-Path $cd 'reviewed-plan-a/plan.json'), (ConvertTo-Json -InputObject $pa -Depth 6))
  Invoke-TestMode 'Collect' @{ GITHUB_SHA = $c2; MATRIX = $matrix } 'a plan that names another subscription folder than units.json waits for nobody' 0 'applyMatrix=[]' $cd
} finally {
  $script:RepoRoot = $keepRoot
  Remove-Item -LiteralPath $g, $gx -Recurse -Force -ErrorAction SilentlyContinue
}

Restore-RunnerEnv
Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 }
exit 0
