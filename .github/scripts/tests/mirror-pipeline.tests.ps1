<#
.SYNOPSIS
  Offline tests of .github/scripts/mirror-pipeline.ps1. No Azure, no GitHub, no network.

.DESCRIPTION
  Calls the helper's functions with small fixtures (tests/fixtures) and with the repository's own
  deploy/units.json and workflow files. The stack fixtures are results of the Azure CLI's stack commands, cut down
  to the fields the helper reads. One part runs the modes of the workflows on a temporary repository, with a
  stand-in for the Azure CLI that answers from files, and another the drift report with the GitHub answers recorded.
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
# The tests judge an enabled pilot unit. They start from a copy of the file with the pilot unit disabled, whatever the
# checkout holds. So enabling the pilot does not change what they prove.
# The demo's other units are enabled in its file. The tests start from a copy with every unit disabled, as in the
# project, so they judge the same cases.
foreach ($x in @($units.units)) { $x.enabled = $false }
# The tests that count the deployed units start from a file with none marked, so the pull request that marks the first unit deployed does not stop them.
foreach ($u in @($units.units)) { $u.PSObject.Properties.Remove('deployed') }
$unitsOn = Copy-Object $units
(@($unitsOn.units) | Where-Object { $_.name -eq 'pilot-empty-rg' }).enabled = $true
$pilot = @($units.units | Where-Object { $_.name -eq 'pilot-empty-rg' })[0]
$subId = [string]$units.subscriptions.($pilot.subscription)
$zw = [string][char]0x200B

Write-Host '--- name status'
$ns = @(ConvertFrom-NameStatus @("A`tdeploy/units.json", "M`tinfra/x.bicep", "R100`told.json`tnew.json"))
Assert-Equal 3 $ns.Count 'three name-status lines'
Assert-Equal 'R' $ns[2].Status 'a rename keeps its first letter'
Assert-Equal 'new.json' $ns[2].Path 'a rename reads as its new path'

Write-Host '--- units a code change touches'
$files = Get-UnitFiles $units $repo
$r = Resolve-AffectedUnits @('infra/subscriptions/demo/main.bicep') $units $files
Assert-True (@($r.preview) -contains 'demo-subscription') 'a subscription main.bicep previews its subscription unit'
Assert-True (@($r.preview) -notcontains 'rg-demo-network') 'and not an unrelated resource group unit'
$r = Resolve-AffectedUnits @('infra/subscriptions/demo/resource-groups/rg-demo-routing.bicep') $units $files
Assert-Equal 'rg-demo-routing' (@($r.preview) -join ',') 'a resource group file previews its own unit only'
# This estate has no module, so the next tests take a small tree in a temporary folder: a shared module that a
# subscription main.bicep calls, and a module that only a gateway unit calls.
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
    [pscustomobject]@{ name = 'demo-subscription'; kind = 'subscription'; subscription = 'demo'; template = 'infra/subscriptions/demo/main.bicep'; enabled = $false },
    [pscustomobject]@{ name = 'rg-demo-network'; kind = 'resourceGroup'; subscription = 'demo'; resourceGroup = 'rg-demo-network'; template = 'infra/subscriptions/demo/resource-groups/rg-demo-network.bicep'; enabled = $false },
    [pscustomobject]@{ name = 'demo-vpn-gateways'; kind = 'subscription'; subscription = 'demo'; template = 'infra/subscriptions/demo/network-gateways.bicep'; enabled = $false }) }
  $mf = Get-UnitFiles $mu $mt
  $r = Resolve-AffectedUnits @('infra/modules/governance/shared-policies.bicep') $mu $mf
  Assert-True (@($r.preview) -contains 'demo-subscription') 'a shared module previews the subscription units that call it'
  Assert-True (@($r.preview) -notcontains 'rg-demo-network') 'and not an unrelated resource group unit'
  $r = Resolve-AffectedUnits @('infra/subscriptions/demo/resource-groups/rg-demo-network.vpn-gateways.bicep') $mu $mf
  Assert-True (@($r.preview) -contains 'demo-vpn-gateways') 'a gateway file previews the gateway unit like any other'
} finally {
  Remove-Item -LiteralPath $mt -Recurse -Force -ErrorAction SilentlyContinue
}
$r = Resolve-AffectedUnits @('bicepconfig.json', 'infra/subscriptions/demo/main.bicep') $units $files
Assert-True ($r.all -and @($r.preview) -contains 'demo-subscription') 'bicepconfig.json adds no unit to the preview, and the other units the pull request changes are still previewed'
Assert-Contains @($r.notes) '*bicepconfig.json changed. Every unit is compiled with it*preflight job*' 'and the note names the check that covers it'
$r = Resolve-AffectedUnits @('deploy/boundaries.json', 'scripts/deploy-unit.ps1') $units $files
Assert-True (-not $r.all -and @($r.preview).Count -eq 0) 'a file the pipeline does not deploy from previews nothing'
$r = Resolve-AffectedUnits @('infra/tenant/governance.bicep') $units $files
Assert-True (@($r.preview) -contains 'demo-tenant-governance' -and @($r.preview) -notcontains 'demo-tenant-management-group') 'a tenant file previews the tenant unit that uses it'
$r = Resolve-AffectedUnits @('README.md') $units $files
Assert-Equal 0 @($r.preview).Count 'a document previews nothing'
# The demo has fewer than 13 resource group units, so the test takes a copy with thirteen more that share one file.
$manyUnits = Copy-Object $units
$proto = @($manyUnits.units | Where-Object { $_.name -eq 'rg-demo-routing' })[0]
$manyUnits.units = @($manyUnits.units) + @(1..13 | ForEach-Object { $c = Copy-Object $proto; $c.name = "rg-demo-many-$_"; $c })
$r = Resolve-AffectedUnits @([string]$proto.template) $manyUnits (Get-UnitFiles $manyUnits $repo)
Assert-True (@($r.preview).Count -ge 13) 'a change to more than 12 units previews every unit it touches'
$changedUnits = Copy-Object $units; $flipUnit = (@($changedUnits.units) | Where-Object { $_.name -eq 'rg-demo-routing' })[0]; $flipUnit.enabled = -not [bool]$flipUnit.enabled
Assert-Equal 'rg-demo-routing' (@(Get-ChangedUnitEntries $units $changedUnits) -join ',') 'switching a unit on or off in units.json previews it'
$changedUnits = Copy-Object $units; $zwUnit = (@($changedUnits.units) | Where-Object { $_.name -eq 'rg-demo-routing' })[0]; $zwUnit.resourceGroup = [string]$zwUnit.resourceGroup + $zw
Assert-Equal 'rg-demo-routing' (@(Get-ChangedUnitEntries $units $changedUnits) -join ',') 'a unit entry that changes only by a zero-width space is a changed entry'

Write-Host '--- the rows of the units'
function Get-TestUnit([string]$Name, $Doc = $units) { return (@($Doc.units) | Where-Object { $_.name -eq $Name })[0] }
function Get-ThrowText([scriptblock]$Block) { try { & $Block | Out-Null; return '' } catch { return [string]$_.Exception.Message } }
$allRows = @($units.units | ForEach-Object { Get-UnitRow $_ $units })
Assert-Equal @($units.units).Count $allRows.Count 'every unit of deploy/units.json gives a row'
Assert-Equal @($units.units | Where-Object { $_.kind -eq 'resourceGroup' }).Count @($allRows | Where-Object { $_.stackScope -ceq 'resourceGroup' }).Count 'a resource group unit is a resource group stack'
Assert-Equal @($units.units | Where-Object { $_.kind -eq 'subscription' }).Count @($allRows | Where-Object { $_.stackScope -ceq 'subscription' }).Count 'a subscription unit is a subscription stack'
Assert-Equal @($units.units | Where-Object { $_.kind -eq 'tenant' }).Count @($allRows | Where-Object { $_.stackScope -ceq 'managementGroup' }).Count 'a tenant-kind unit is a management group stack'
Assert-Equal $allRows.Count @($allRows | ForEach-Object { $_.stack } | Sort-Object -Unique).Count 'every stack name is different'
Assert-Equal @($units.units | Where-Object { $null -ne $_.PSObject.Properties['stackDeletes'] -and $_.stackDeletes -eq $true }).Count @($allRows | Where-Object { $_.unmanage -cne 'detach' }).Count 'a unit deletes what leaves its template only when its entry has stackDeletes true'
Assert-Equal 0 @($allRows | Where-Object { $_.stack -cne "mirror-$($_.unit)" -or $_.stack.Length -gt 90 }).Count 'a stack is named mirror-<unit>, within the 90 characters Azure allows'
$row = Get-UnitRow $pilot $units
Assert-Equal "pilot-empty-rg|production|$($pilot.subscription)|resourceGroup|$subId|$($pilot.resourceGroup)||detach" "$($row.unit)|$($row.tier)|$($row.scope)|$($row.stackScope)|$($row.subscriptionId)|$($row.resourceGroup)|$($row.managementGroup)|$($row.unmanage)" 'the row of a resource group unit'
Assert-Equal 'pipelines/pilot/empty-rg.bicep|' "$($row.template)|$($row.parameters)" 'a unit without a parameters file has an empty parameters value'
$row = Get-UnitRow (Get-TestUnit 'demo-privileged') $units
Assert-Equal 'privileged|demo|subscription|' "$($row.tier)|$($row.scope)|$($row.stackScope)|$($row.resourceGroup)" 'the row of a privileged subscription unit'
$row = Get-UnitRow (Get-TestUnit 'demo-tenant-management-group') $units
Assert-Equal "privileged|tenant|managementGroup||$($units.tenantId)" "$($row.tier)|$($row.scope)|$($row.stackScope)|$($row.subscriptionId)|$($row.managementGroup)" 'the management groups unit is a management group stack at the Tenant Root Group'
Assert-Equal 'mg-demo' (Get-UnitRow (Get-TestUnit 'demo-tenant-governance') $units).managementGroup 'a tenant unit takes its management group from units.json'
$delUnits = Copy-Object $units
(Get-TestUnit 'rg-demo-routing' $delUnits) | Add-Member -Force -NotePropertyName stackDeletes -NotePropertyValue $true
Assert-Equal 'delete' (Get-UnitRow (Get-TestUnit 'rg-demo-routing' $delUnits) $delUnits).unmanage 'stackDeletes true deletes what leaves the template'
Assert-Equal 'detach' (Get-UnitRow (Get-TestUnit 'rg-demo-network' $delUnits) $delUnits).unmanage 'and only for the unit that has it'
(Get-TestUnit 'rg-demo-routing' $delUnits).stackDeletes = 'true'
Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit 'rg-demo-routing' $delUnits) $delUnits }) -like '*stackDeletes must be true or false*') 'stackDeletes as text is refused'
$badUnits = Copy-Object $units; (Get-TestUnit 'rg-demo-routing' $badUnits).kind = 'tenants'
Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit 'rg-demo-routing' $badUnits) $badUnits }) -like "*the kind 'tenants' is not*") 'an unknown kind is refused'
$badUnits = Copy-Object $units; (Get-TestUnit 'demo-privileged' $badUnits).tier = 'Privileged'
Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit 'demo-privileged' $badUnits) $badUnits }) -like '*the tier must be privileged or left out*') 'a misspelled tier is refused and never read as production'
$badUnits = Copy-Object $units; (Get-TestUnit 'rg-demo-routing' $badUnits).parameters = '../outside.bicepparam'
Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit 'rg-demo-routing' $badUnits) $badUnits }) -like '*is not a path inside the repository*') 'a file outside the repository is refused'
$badUnits = Copy-Object $units; (Get-TestUnit 'rg-demo-routing' $badUnits).subscription = 'no-such-subscription'
Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit 'rg-demo-routing' $badUnits) $badUnits }) -like '*has no ID in the subscriptions list*') 'a subscription that is not in the list is refused'
$badUnits = Copy-Object $units; (Get-TestUnit 'rg-demo-routing' $badUnits).resourceGroup = 'rg one; az group delete'
Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit 'rg-demo-routing' $badUnits) $badUnits }) -like '*is not a resource group name*') 'a resource group name with other characters is refused'
$badUnits = Copy-Object $units; (Get-TestUnit 'rg-demo-routing' $badUnits).name = 'RG-DEMO'
Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit 'RG-DEMO' $badUnits) $badUnits }) -like '*is not lower-case letters, digits and single hyphens*') 'a unit name with capitals is refused'
foreach ($n in @('demo-tenant-management-group', 'demo-tenant-governance')) {
  $badUnits = Copy-Object $units; (Get-TestUnit $n $badUnits) | Add-Member -Force -NotePropertyName stackDeletes -NotePropertyValue $true
  Assert-True ((Get-ThrowText { Get-UnitRow (Get-TestUnit $n $badUnits) $badUnits }) -like '*stackDeletes stays off for the units of the scope*') "stackDeletes is refused for $n, a unit of the tenant"
  (Get-TestUnit $n $badUnits).stackDeletes = $false
  Assert-Equal 'detach' (Get-UnitRow (Get-TestUnit $n $badUnits) $badUnits).unmanage "and stackDeletes false passes for $n"
}

Write-Host '--- the rules of deploy/units.json'
$e = @(Test-UnitRules $units)
Assert-Equal 0 $e.Count "every unit of the repository keeps the unit rules ($($e -join '; '))"
$excluded = @($units.units | Where-Object { Test-DeployExcludedUnit $_ })
Assert-Equal @($units.units | Where-Object { $_.name -like '*-deploy-excluded' }).Count $excluded.Count 'the units of the deploy-excluded files are found by their template'
Assert-True ($excluded.Count -ge 1 -and -not (Test-DeployExcludedUnit $pilot)) 'and a routine unit is not one of them'
foreach ($f in @('enabled', 'deployed', 'stackDeletes')) {
  $badUnits = Copy-Object $units; $x = Get-TestUnit $excluded[0].name $badUnits
  if ($null -eq $x.PSObject.Properties[$f]) { $x | Add-Member -Force -NotePropertyName $f -NotePropertyValue $true } else { $x.$f = $true }
  Assert-Contains @(Test-UnitRules $badUnits) "*$($excluded[0].name): $f is true, and the unit of a deploy-excluded file is never deployed*" "a deploy-excluded unit with $f true breaks the unit rules"
}
$badUnits = Copy-Object $units; (Get-TestUnit 'demo-privileged' $badUnits).tier = 'Privileged'
Assert-Contains @(Test-UnitRules $badUnits) '*demo-privileged: the tier must be privileged or left out*' 'a misspelled tier breaks the unit rules'
$badUnits = Copy-Object $units; (Get-TestUnit 'rg-demo-routing' $badUnits).enabled = 'true'
Assert-Contains @(Test-UnitRules $badUnits) '*rg-demo-routing: enabled must be true or false*' 'enabled as text breaks the unit rules'
$badUnits = Copy-Object $units; (Get-TestUnit 'demo-tenant-management-group' $badUnits) | Add-Member -Force -NotePropertyName stackDeletes -NotePropertyValue $true
Assert-Contains @(Test-UnitRules $badUnits) '*demo-tenant-management-group: stackDeletes stays off*' 'stackDeletes on a tenant unit breaks the unit rules'
$badUnits = Copy-Object $units; (Get-TestUnit 'rg-demo-routing' $badUnits).name = 'RG-DEMO-NETWORK'
Assert-Contains @(Test-UnitRules $badUnits) "*the unit name 'RG-DEMO-NETWORK' is used more than once*" 'two units whose names differ only in case break the unit rules'

Write-Host '--- the stack commands of the Azure CLI'
$rgRow = Get-UnitRow $pilot $units
$subRow = Get-UnitRow (Get-TestUnit 'demo-subscription') $units
$mgRow = Get-UnitRow (Get-TestUnit 'demo-tenant-governance') $units
Assert-Equal "/subscriptions/$subId/resourceGroups/$($pilot.resourceGroup)/providers/Microsoft.Resources/deploymentStacks/mirror-pilot-empty-rg" (Get-StackId $rgRow) 'the ID of a resource group stack'
Assert-Equal "/subscriptions/$($subRow.subscriptionId)/providers/Microsoft.Resources/deploymentStacks/mirror-demo-subscription" (Get-StackId $subRow) 'the ID of a subscription stack'
Assert-Equal '/providers/Microsoft.Management/managementGroups/mg-demo/providers/Microsoft.Resources/deploymentStacks/mirror-demo-tenant-governance' (Get-StackId $mgRow) 'the ID of a management group stack'
$sa = @(Get-StackArguments $rgRow $repo 'validate')
Assert-Equal 'stack group validate --name mirror-pilot-empty-rg' ($sa[0..4] -join ' ') 'a resource group unit is validated as a resource group stack'
Assert-True ($sa -contains '--resource-group' -and $sa -contains $pilot.resourceGroup -and $sa -contains '--subscription' -and $sa -contains $subId -and $sa -notcontains '--location') 'with its subscription and resource group, and no location'
Assert-True ($sa -contains '--template-file' -and $sa -notcontains '--parameters') 'a unit without a parameters file gives its template'
Assert-Equal 'detachAll|none|ProviderNoRbac|none' "$($sa[[array]::IndexOf($sa, '--action-on-unmanage') + 1])|$($sa[[array]::IndexOf($sa, '--deny-settings-mode') + 1])|$($sa[[array]::IndexOf($sa, '--validation-level') + 1])|$($sa[[array]::IndexOf($sa, '-o') + 1])" 'detach, no deny settings and the validation level a reader can run'
$sa = @(Get-StackArguments $subRow $repo 'whatif' 'mirror-demo-subscription-1')
Assert-Equal 'stack-whatif sub create --name mirror-demo-subscription-1 --stack-id' ($sa[0..5] -join ' ') 'a subscription unit is previewed as a subscription stack'
Assert-Equal "$(Get-StackId $subRow)|PT1H|$($units.deploymentLocation)|json" "$($sa[[array]::IndexOf($sa, '--stack-id') + 1])|$($sa[[array]::IndexOf($sa, '--retention-interval') + 1])|$($sa[[array]::IndexOf($sa, '--location') + 1])|$($sa[[array]::IndexOf($sa, '-o') + 1])" 'the preview names the stack, is kept one hour, takes the location from units.json and returns JSON'
Assert-True ($sa -contains '--no-pretty-print' -and $sa -contains '--parameters' -and $sa -notcontains '--template-file' -and $sa -notcontains '--resource-group') 'a unit with a parameters file gives that file only'
Assert-True ($sa[[array]::IndexOf($sa, '--parameters') + 1] -like '*demo*parameters.bicepparam') 'the parameters file is the one of the unit'
$delRow = Copy-Object $subRow; $delRow.unmanage = 'delete'
Assert-True (@(Get-StackArguments $delRow $repo 'whatif' 'x') -contains 'deleteResources' -and @(Get-StackArguments $delRow $repo 'whatif' 'x') -notcontains 'deleteAll') 'a unit that deletes previews deleteResources, never deleteAll'
$sa = @(Get-StackArguments $mgRow $repo 'show' 'mirror-x-1')
Assert-Equal 'stack-whatif mg show --name mirror-x-1 --management-group-id mg-demo --with-property-changes true --no-color' ($sa -join ' ') 'the text of a management group preview is read back with its property changes'
$sa = @(Get-StackArguments $mgRow $repo 'validate')
Assert-True ($sa[1] -ceq 'mg' -and $sa -contains '--location' -and $sa -notcontains '--subscription') 'a tenant unit is validated at its management group, with a location and no subscription'
Assert-Equal "stack group show --name mirror-pilot-empty-rg --subscription $subId --resource-group $($pilot.resourceGroup) -o json" (@(Get-StackArguments $rgRow $repo 'stack') -join ' ') 'the stack itself is read with az stack group show'
Assert-True ((Get-ThrowText { Get-StackArguments $rgRow $repo 'create' }) -like "*unknown stack command 'create'*") 'the helper builds no command that writes a stack'

Write-Host '--- what a stack preview says'
$v = Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-clean.json') 'u'
Assert-Equal 'clean|3|0|False|0' "$($v.result)|$($v.resources)|$($v.changed)|$($v.firstRun)|$($v.adopted)" 'a preview where every resource is noChange is clean'
Assert-Equal 3 $v.counts['noChange'] 'the change types are counted as Azure names them'
$v = Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-drift.json') 'u'
Assert-Equal 'DRIFT|1|False' "$($v.result)|$($v.changed)|$($v.firstRun)" 'a resource changed by hand makes the unit differ'
Assert-True (@($v.findings).Count -eq 1 -and $v.findings[0] -like 'modify /subscriptions/*/virtualNetworks/vnet-example') 'the finding is the change type and the resource ID'
$v = Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-first-run.json') 'u'
Assert-Equal 'DRIFT|True|0|3' "$($v.result)|$($v.firstRun)|$($v.adopted)|$($v.counts['create'])" 'a stack that does not exist yet is a first run, and new resources are creates'
$v = Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-adoption.json') 'u'
Assert-Equal 'True|3|2|1' "$($v.firstRun)|$($v.adopted)|$($v.counts['noChange'])|$($v.counts['modify'])" 'resources that exist come under the stack on its first run, whatever their change type'
$v = Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-delete.json') 'u'
Assert-True (@($v.findings | Where-Object { $_ -like 'delete /subscriptions/*' }).Count -eq 1 -and $v.counts['delete'] -eq 1) 'a resource that left the template of a unit that deletes shows as delete'
$v = Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-detach.json') 'u'
Assert-True (@($v.findings | Where-Object { $_ -like 'detach /subscriptions/*' }).Count -eq 1 -and -not $v.counts.Contains('delete')) 'and as detach for every other unit'
$failedDoc = Read-Fixture 'stack-whatif-clean.json'; $failedDoc.properties.provisioningState = 'failed'
Assert-Equal 'ERROR' (Get-StackWhatIfVerdict $failedDoc 'u').result 'a preview Azure did not finish is an error, also when it lists no change'
$failedDoc = Read-Fixture 'stack-whatif-clean.json'; $failedDoc.properties.error = [pscustomobject]@{ code = 'x' }
Assert-Equal 'ERROR' (Get-StackWhatIfVerdict $failedDoc 'u').result 'and so is a preview with an error'
Assert-Equal 'ERROR' (Get-StackWhatIfVerdict ([pscustomobject]@{ name = 'x' }) 'u').result 'and a result with no properties'
$tick = [string][char]96
$diagDoc = Read-Fixture 'stack-whatif-clean.json'
$diagDoc.properties.diagnostics = @([pscustomobject]@{ level = 'warning'; code = 'NestedDeploymentShortCircuited'; message = "A nested deployment got short-circuited`nand all its resources got skipped."; target = '/subscriptions/x/resourceGroups/rg-example/providers/Microsoft.Resources/deployments/m1' })
$v = Get-StackWhatIfVerdict $diagDoc 'u'
Assert-Equal 'clean|1|1' "$($v.result)|$($v.diagnostics)|$(@($v.diagnosticMessages).Count)" 'a diagnostic of Azure is counted and kept beside the result'
Assert-True ($v.diagnosticMessages[0] -like 'warning NestedDeploymentShortCircuited: A nested deployment got short-circuited | and all its resources got skipped. /subscriptions/x/*' -and -not $v.diagnosticMessages[0].Contains("`n")) 'as one line with its level, code, message and target'
$sum = (Format-StackWhatIfSummary $subRow $v 't') -join "`n"
Assert-True ($sum -like '*Azure added 1 diagnostic message(s) to the preview.*could not evaluate a part of the stack*' -and $sum.Contains("- ${tick}warning NestedDeploymentShortCircuited")) 'the summary lists each diagnostic and says the preview is not a full check'
$diagDoc.properties.diagnostics = @(1..25 | ForEach-Object { [pscustomobject]@{ level = 'info'; code = "c$_"; message = 'm'; target = $null } })
$v = Get-StackWhatIfVerdict $diagDoc 'u'
Assert-True ($v.diagnostics -eq 25 -and @($v.diagnosticMessages).Count -eq ($script:MaxDiagnostics + 1) -and $v.diagnosticMessages[-1] -like 'and 5 more*') 'a long list of diagnostics is cut, and the count stays whole'
Assert-Equal 0 @((Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-clean.json') 'u').diagnosticMessages).Count 'a preview without diagnostics has no message'
$manyDoc = Read-Fixture 'stack-whatif-drift.json'
$one = @($manyDoc.properties.changes.resourceChanges | Where-Object { $_.changeType -ceq 'modify' })[0]
$manyDoc.properties.changes.resourceChanges = @(1..45 | ForEach-Object { $c = Copy-Object $one; $c.id = "$($one.id)-$('{0:d2}' -f $_)"; $c })
$v = Get-StackWhatIfVerdict $manyDoc 'u'
Assert-Equal "45|$($script:MaxFindingsPerUnit + 1)" "$($v.changed)|$(@($v.findings).Count)" 'a long list of findings is cut for the issue, and the count stays whole'
Assert-True ($v.findings[-1] -like 'and 5 more*' -and $v.findings[0] -like '*-01') 'the cut list is sorted and says how many more there are'
$tick = [string][char]96
$block = ConvertTo-CodeBlock ("a`r`n$($tick * 3)`r`nb")
Assert-True ($block.StartsWith(($tick * 4) + "text`n") -and $block.EndsWith("`n" + ($tick * 4)) -and -not $block.Contains("`r")) 'text with three backticks gets a fence of four, so it cannot end the block'
$keepMax = $script:MaxSummaryChars; $script:MaxSummaryChars = 10
$block = ConvertTo-CodeBlock ('x' * 50)
$script:MaxSummaryChars = $keepMax
Assert-True ($block -like '*xxxxxxxxxx*The text is cut here*' -and $block -notlike '*xxxxxxxxxxx*') 'a text longer than the limit is cut, with a line that says so'
$sum = (Format-StackWhatIfSummary $rgRow (Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-adoption.json') 'pilot-empty-rg') 'the text') -join "`n"
Assert-True ($sum.Contains("Stack preview of ${tick}pilot-empty-rg${tick}") -and $sum.Contains('mirror-pilot-empty-rg') -and $sum.Contains("the resource group $tick$($pilot.resourceGroup)$tick")) 'the summary names the unit, the stack and its scope'
Assert-True ($sum -like '*The stack does not exist yet*3 resource(s) that exist come under*' -and $sum.Contains("| ${tick}modify${tick} | 1 |") -and $sum.Contains("| ${tick}noChange${tick} | 2 |")) 'it says a first run, and counts each change type'
Assert-True ($sum -like '*is detached by the deployment*' -and $sum -like '*<details>*the text*</details>*') 'it says what happens to a resource that left the template, and holds the text of the preview'
$sum = (Format-StackWhatIfSummary $delRow (Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-delete.json') 'demo-subscription') '') -join "`n"
Assert-True ($sum.Contains('is **deleted** by the deployment') -and $sum -like '*could not be read back*' -and $sum.Contains("- ${tick}delete /subscriptions/")) 'a unit that deletes says so, and without the text the changed resources are listed'
$sum = (Format-StackWhatIfSummary $subRow (Get-StackWhatIfVerdict (Read-Fixture 'stack-whatif-clean.json') 'demo-subscription') 't') -join "`n"
Assert-True ($sum -like '*Every one of the 3 resource(s) is noChange*' -and $sum -notlike '*does not exist yet*') 'a clean preview of an existing stack says every resource is noChange'

Write-Host '--- workflow rules'
$wf = @{}
foreach ($f in @(Get-ChildItem -LiteralPath (Join-Path $repo '.github/workflows') -File)) { $wf[$f.Name] = [IO.File]::ReadAllText($f.FullName) }
$e = @(Test-WorkflowHygiene $wf)
Assert-Equal 0 $e.Count "the repository's workflows pass the rules ($($e -join '; '))"
$sha = 'a' * 40
$bad = @{
  'x.yml' = "on:`n  pull_request_target: {}`njobs:`n  a:`n    environment: mirror-production-fdm-grc`n    steps:`n      - uses: actions/checkout@v7`n      - uses: someone/tool@$sha`n"
  'mirror-deploy-unit.yml' = "on:`n  push:`n    branches: [ master ]`n"
  'y.yml' = "on:`n  pull_request:`n    types: [ closed ]`npermissions:`n  id-token: write`n"
}
$e = @(Test-WorkflowHygiene $bad)
Assert-Contains $e 'x.yml: names a mirror-production*' 'a production environment outside the deploy workflow is refused'
Assert-Contains $e 'x.yml: uses the pull_request_target*' 'pull_request_target is refused'
Assert-Contains $e '*actions/checkout@v7 is not pinned*' 'a tag pin is refused'
Assert-Contains $e '*someone/tool is not one of the allowed actions*' 'an action outside the allowed list is refused'
Assert-Contains $e 'mirror-deploy-unit.yml: the deploy workflow starts only with Run workflow*' 'a deploy workflow with a push trigger is refused'
Assert-Contains $e 'y.yml: requests id-token*' 'id-token on a closed pull request is refused'
$e = @(Test-WorkflowHygiene @{ 'z.yml' = "# environment: mirror-production-fdm-grc`n" })
Assert-Equal 0 $e.Count 'a comment line is not a rule break'
$rc = "    steps:`n      - uses: actions/checkout@$sha`n      - name: Runner check`n        uses: ./.github/actions/runner-check`n"
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
  'c1.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - name: Runner check`n        uses: ./.github/actions/runner-check`n      - uses: actions/checkout@$('a' * 40)`n"
  'c2.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - uses: actions/checkout@$('a' * 40)`n      - name: Runner check`n        shell: pwsh`n        run: exit 0`n"
  'c3.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - uses: actions/checkout@$('a' * 40)`n      - uses: ./.github/actions/other`n"
  'c4.yml' = "jobs:`n  a:`n    runs-on: windows-2025`n    steps:`n      - uses: actions/checkout@$('a' * 40)`n      - name: Runner check`n        uses: ./.github/actions/runner-check`n      - uses: ./.github/actions/setup-bicep`n"
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
Assert-Contains $e 'c1.yml: the first step of the job a is not the checkout*' 'a runner check before the checkout is refused'
Assert-Contains $e 'c2.yml: the first step of the job a is not the checkout*' 'an inline runner check in place of the local action is refused'
Assert-Contains $e 'c3.yml: uses the local action ./.github/actions/other*' 'a local action outside the allowed two is refused'
Assert-Equal 0 @($e | Where-Object { $_ -like 'c4.yml: uses the local action*' }).Count 'the Bicep setup action is an allowed local action'
Assert-Equal 0 @($e | Where-Object { $_ -like 'r1.yml: the first step*' }).Count 'a job with the checkout first and the runner check second passes that rule'
Assert-Contains $e "s1.yml: a step uses the shell 'powershell'*" 'Windows PowerShell as a step shell is refused'
Assert-Contains $e 's2.yml: 1 run step(s) name no shell*' 'a run step without a shell is refused'

Write-Host '--- the local actions'
$ac = @{}
foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $repo '.github/actions') -Directory -Force)) { $ac[$d.Name] = [IO.File]::ReadAllText((Join-Path $d.FullName 'action.yml')) }
Assert-Equal 2 $ac.Count 'the repository has the two local actions'
$e = @(Test-ActionHygiene $ac)
Assert-Equal 0 $e.Count "the repository's local actions pass the rules ($($e -join '; '))"
$e = @(Test-ActionHygiene @{ 'runner-check' = $ac['runner-check'].Replace('RUNNER_ARCH', 'RUNNER_X') })
Assert-Contains $e '*runner-check/action.yml: must keep RUNNER_ARCH*' 'a runner check that stops reading the architecture is refused'
$e = @(Test-ActionHygiene @{ 'setup-bicep' = $ac['setup-bicep'].Replace('Get-FileHash', 'Get-Item') })
Assert-Contains $e '*setup-bicep/action.yml: must keep Get-FileHash*' 'a Bicep setup that stops checking the hash is refused'
$e = @(Test-ActionHygiene @{ 'setup-bicep' = $ac['setup-bicep'].Replace('shell: pwsh', 'shell: bash') })
Assert-Contains $e "*a step uses the shell 'bash'*" 'a local action with another shell is refused'
$e = @(Test-ActionHygiene @{ 'runner-check' = $ac['runner-check'] + "    - uses: actions/checkout@$sha`n" })
Assert-Contains $e '*uses another action*' 'a local action that uses another action is refused'
$e = @(Test-ActionHygiene @{ 'runner-check' = $ac['runner-check'].Replace('Write-Host "GitHub-hosted', 'Write-Host "${{ github.actor }} GitHub-hosted') })
Assert-Contains $e '*uses an expression*' 'a local action with an expression is refused'
$e = @(Test-ActionHygiene @{ 'runner-check' = $ac['runner-check'].Replace('using: composite', 'using: node20') })
Assert-Contains $e '*must be a composite action*' 'a local action that is not composite is refused'
$e = @(Test-ActionHygiene @{ 'other' = $ac['runner-check'] })
Assert-Contains $e '*is not one of the local actions*' 'a third local action is refused'

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
  $routine = @($units.units)
  $rmap = Get-UnitFiles ([pscustomobject]@{ units = $routine }) $repo
  $f = @(); foreach ($u in $routine) { $f += @(Find-UnsafeBicepInputs @($rmap[[string]$u.name]) $repo) }
  Assert-Equal 0 $f.Count "the units a pull request can preview use none of these inputs ($($f -join '; '))"
  Push-Location $repo; $trackedBicep = @(git ls-files '*.bicep' '*.bicepparam'); Pop-Location
  $f = @(Find-UnsafeBicepInputs $trackedBicep $repo)
  Assert-True ($trackedBicep.Count -gt 10 -and $f.Count -eq 0) "every Bicep file of the repository passes, as the check reads the whole checkout ($($trackedBicep.Count) files, $($f -join '; '))"
  $code = [MirrorPipeline.BicepText]::BlankComments("var a = 'x // y' // z`n/* q`nr */ var b = '`${'}'}' /* s */ var c = 1")
  Assert-Equal "var a = 'x // y'     `n    `n     var b = '`${'}'}'         var c = 1" $code 'comments are blanked the way Bicep reads them, strings and interpolations are kept'
  # The InputCheck mode as the preview job runs it, on a copy of the helper beside one unit whose parameter file
  # reads an environment variable.
  New-Item -ItemType Directory -Path (Join-Path $bt '.github/scripts'), (Join-Path $bt 'deploy') -Force | Out-Null
  Copy-Item -LiteralPath $helper -Destination (Join-Path $bt '.github/scripts/mirror-pipeline.ps1')
  [IO.File]::WriteAllText((Join-Path $bt 'deploy/units.json'), '{ "units": [ { "name": "x", "kind": "resourceGroup", "template": "infra/x/good.bicep", "parameters": "infra/x/bad.bicepparam", "enabled": false } ] }')
  $prevVars = @{}; foreach ($k in @('UNIT', 'MIRROR_TRUSTED_COMMIT', 'MIRROR_CODE_COMMIT')) { $prevVars[$k] = [Environment]::GetEnvironmentVariable($k) }
  [Environment]::SetEnvironmentVariable('UNIT', 'x')
  $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $said = (& $childExe @childArgs -File (Join-Path $bt '.github/scripts/mirror-pipeline.ps1') -Mode InputCheck 2>&1 | ForEach-Object { "$_" }) -join "`n"; $code = $LASTEXITCODE }
  finally { $ErrorActionPreference = $prevEap; foreach ($k in $prevVars.Keys) { [Environment]::SetEnvironmentVariable($k, $prevVars[$k]) } }
  Assert-True ($code -eq 2 -and $said -like '*Bicep from a branch uses inputs that are not run with the reader identity*' -and $said -like '*environment variable*') "inputcheck: a branch unit that reads an environment variable is refused before the sign-in (exit $code)"
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
  $prev = @{}; foreach ($k in @('UNIT', 'MIRROR_TRUSTED_COMMIT', 'MIRROR_CODE_COMMIT')) { $prev[$k] = [Environment]::GetEnvironmentVariable($k) }
  [Environment]::SetEnvironmentVariable('UNIT', $(if ($Unit) { $Unit } else { $null }))
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
  Invoke-InputCase 'a disabled measuredWith unit, in the drift check with no UNIT' @{ 'infra/t.bicep' = "output o string = 'x'`n"; 'infra/sib.bicep' = $child.Replace('../../../', '../../') } '{ "units": [ { "name": "routine", "kind": "resourceGroup", "template": "infra/t.bicep", "enabled": true, "measuredWith": [ "routine-deploy-excluded" ] }, { "name": "routine-deploy-excluded", "kind": "resourceGroup", "template": "infra/sib.bicep", "enabled": false } ] }' '' 2 '*infra/sib.bicep line 1 loads a file outside the repository*'
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
  Assert-True ($r.all -and @($r.preview).Count -eq 0) 'a bicepconfig.json in a subfolder previews no single unit either'
  Assert-Equal ("a = '''x`ny'''" + (' ' * 5)) ([MirrorPipeline.BicepText]::BlankComments("a = '''x`ny''' // z")) 'the input check still reads the inside of a multi-line string'
  Assert-Equal ("a = '''x''''" + (' ' * 7) + ' b') ([MirrorPipeline.BicepText]::BlankComments("a = '''x''''/* c */ b")) 'the input check takes the quotes right after a multi-line string into it and blanks the comment after them'
} finally {
  Remove-Item -LiteralPath $rt -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host '--- hardening checks'
Assert-Equal 'a | ::warning::b | c | d' (ConvertTo-OneLine ("a`r::warning::b" + [char]0x2028 + "c`r`nd")) 'a lone carriage return or a line separator cannot start a workflow command line'

Write-Host '--- the deploy workflow rules'
$applyEnv = 'mirror-${{ matrix.tier }}-${{ matrix.scope }}'
$applyIf = "    if: $($script:PipelineSwitch) && inputs.apply && needs.plan.result == 'success' && github.run_attempt == '1'`n"
$applyStep = "    steps:`n      - name: Check the plan is still current`n        env:`n          RUN_COMMIT: `${{ github.sha }}`n          PLANNED: `${{ needs.plan.outputs.planned }}`n        run: gh api repos/x/git/ref/heads/master`n      - uses: ./.github/actions/setup-bicep`n      - name: Give the deployment action the checked Bicep`n        run: x`n      - uses: azure/login@$sha`n      - uses: azure/bicep-deploy@$sha`n        with:`n          type: deploymentStack`n          operation: create`n          action-on-unmanage-resources: `${{ matrix.unmanage }}`n          action-on-unmanage-resourcegroups: detach`n          action-on-unmanage-managementgroup: detach`n          action-on-unmanage-managementgroups: detach`n          deny-settings-mode: none`n      - name: Check the deployment action used the checked Bicep`n        run: x`n"
$goodDeploy = "on:`n  workflow_dispatch:`n    inputs: {}`njobs:`n  units:`n    permissions:`n      contents: read`n  plan:`n    needs: units`n    environment:`n      name: mirror-reader-dispatch`n    permissions:`n      id-token: write`n  apply:`n    needs: [ units, plan ]`n$applyIf    environment: $applyEnv`n    permissions:`n      id-token: write`n$applyStep"
function Test-DeployRules([string]$Text) { return @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $Text } | Where-Object { $_ -notlike '*runner check*' -and $_ -notlike '*pipeline switch*' -and $_ -notlike '*Check the Bicep inputs*' -and $_ -notlike '*run step*' }) }
$e = @(Test-DeployRules $goodDeploy)
Assert-Equal 0 $e.Count "a deploy workflow that starts only with Run workflow, with the apply as its only production and privileged job, passes ($($e -join '; '))"
$e = @(Test-DeployRules $goodDeploy.Replace('  workflow_dispatch:', '  schedule:'))
Assert-Contains $e '*has no push, schedule or pull_request trigger*' 'a schedule on the deploy workflow is refused'
Assert-Contains $e '*must start on workflow_dispatch and on nothing else*' 'a deploy workflow without Run workflow is refused'
$e = @(Test-DeployRules $goodDeploy.Replace("on:`n  workflow_dispatch:", "on:`n  push:`n    branches: [ master ]`n  workflow_dispatch:"))
Assert-Contains $e '*has no push, schedule or pull_request trigger*' 'a push trigger on the deploy workflow is refused'
$e = @(Test-DeployRules $goodDeploy.Replace("  workflow_dispatch:`n    inputs: {}", "  workflow_dispatch:`n    inputs: {}`n  release:`n    types: [ published ]"))
Assert-Contains $e '*must start on workflow_dispatch and on nothing else, and it also names release*' 'any trigger beside workflow_dispatch on the deploy workflow is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('workflow_dispatch:', "pull_request:`n  workflow_dispatch:"))
Assert-Contains $e '*has no push, schedule or pull_request trigger*' 'a pull request trigger on the deploy workflow is refused'
$e = @(Test-DeployRules $goodDeploy.Replace($applyEnv, 'mirror-production-fdm-grc'))
Assert-Contains $e '*the apply job must have environment: mirror-*matrix.tier*matrix.scope*' 'the apply job may not name a fixed production environment'
$e = @(Test-DeployRules $goodDeploy.Replace($applyEnv, 'mirror-privileged-${{ matrix.scope }}'))
Assert-Contains $e '*the apply job must have environment: mirror-*matrix.tier*matrix.scope*' 'the apply job takes its tier from the matrix, never from the file'
$e = @(Test-DeployRules $goodDeploy.Replace('needs: [ units, plan ]', 'needs: units'))
Assert-Contains $e '*the apply job must need the plan job*' 'the apply job must wait for the plan job'
$e = @(Test-DeployRules $goodDeploy.Replace(" && github.run_attempt == '1'", ''))
Assert-Contains $e '*the apply job must run only on the first attempt of a run*' 'an apply that a re-run could start is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('      - name: Check the plan is still current', '      - name: Another step'))
Assert-Contains $e '*the apply job must check that the plan is still current before the Azure sign-in*' 'an apply without the check of the plan is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('      - name: Give the deployment action the checked Bicep', '      - name: Another step'))
Assert-Contains $e '*the apply job must give azure/bicep-deploy the hash-checked Bicep*' 'an apply that lets the action download its own Bicep is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('      - name: Check the deployment action used the checked Bicep', '      - name: Another step'))
Assert-Contains $e '*the apply job must give azure/bicep-deploy the hash-checked Bicep*' 'an apply without the check after the deployment is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('git/ref/heads/master', 'git/ref/heads/main'))
Assert-Contains $e '*the apply job must check that the plan is still current*' 'a check that does not read the tip of master is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('needs.plan.outputs.planned', 'github.run_id'))
Assert-Contains $e '*the apply job must check that the plan is still current*' 'a check that does not read the time of the plan is refused'
$e = @(Test-DeployRules $goodDeploy.Replace("      - uses: azure/login@$sha`n      - uses: azure/bicep-deploy@$sha`n", "      - uses: azure/bicep-deploy@$sha`n").Replace("    steps:`n      - name: Check the plan", "    steps:`n      - uses: azure/login@$sha`n      - name: Check the plan"))
Assert-Contains $e '*the apply job must check that the plan is still current before the Azure sign-in*' 'a check of the plan after the sign-in is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('deny-settings-mode: none', 'deny-settings-mode: denyDelete'))
Assert-Contains $e '*with deny-settings-mode: none*' 'deny settings on the apply are refused'
$e = @(Test-DeployRules $goodDeploy.Replace('operation: create', 'operation: delete'))
Assert-Contains $e '*the apply job must create the stack with azure/bicep-deploy*' 'an apply that deletes the stack is refused'
$e = @(Test-DeployRules $goodDeploy.Replace('action-on-unmanage-resourcegroups: detach', 'action-on-unmanage-resourcegroups: delete'))
Assert-Contains $e '*the apply job must keep action-on-unmanage-resourcegroups: detach*' 'an apply that deletes resource groups is refused'
$e = @(Test-DeployRules $goodDeploy.Replace("          action-on-unmanage-managementgroups: detach`n", ''))
Assert-Contains $e '*the apply job must keep action-on-unmanage-managementgroups: detach*' 'the management group input must stay under both of its names'
$e = @(Test-DeployRules $goodDeploy.Replace('action-on-unmanage-managementgroup: detach', 'action-on-unmanage-managementgroup: ${{ matrix.unmanage }}'))
Assert-Contains $e '*the apply job must keep action-on-unmanage-managementgroup: detach*' 'a management group never takes the action of the resources'
$e = @(Test-DeployRules $goodDeploy.Replace('action-on-unmanage-resources: ${{ matrix.unmanage }}', 'action-on-unmanage-resources: delete'))
Assert-Contains $e '*the apply job must take action-on-unmanage-resources from the unit''s row*' 'an apply that deletes in every unit, whatever its row says, is refused'
Assert-Equal 0 @(Test-DeployRules $goodDeploy | Where-Object { $_ -like '*action-on-unmanage-resources*' }).Count 'the row form of the resources action passes'
$e = @(Test-DeployRules $goodDeploy.Replace('name: mirror-reader-dispatch', 'name: mirror-privileged-tenant'))
Assert-Contains $e '*the job plan names a mirror-production or mirror-privileged environment*' 'the plan job may not name a privileged environment'
$e = @(Test-DeployRules $goodDeploy.Replace('name: mirror-reader-dispatch', 'name: mirror-production-fdm-grc'))
Assert-Contains $e '*the job plan names a mirror-production or mirror-privileged environment*' 'the plan job may not name a production environment'
$e = @(Test-DeployRules $goodDeploy.Replace('name: mirror-reader-dispatch', "name: $applyEnv"))
Assert-Contains $e '*the job plan names a mirror-production or mirror-privileged environment or builds an environment name from an expression*' 'the plan job may not build its environment from the matrix'
$e = @(Test-DeployRules $goodDeploy.Replace("  plan:`n    needs: units`n", "  plan:`n    needs: units`n    steps:`n      - uses: azure/bicep-deploy@$sha`n"))
Assert-Contains $e '*the job plan uses azure/bicep-deploy, and only the apply job may*' 'the plan job may not use the action that writes to Azure'
$e = @(Test-DeployRules $goodDeploy.Replace('  apply:', '  deploy:'))
Assert-Contains $e '*the deploy workflow has no apply job*' 'a deploy workflow without the apply job is refused'
$e = @(Test-WorkflowHygiene @{ 'x.yml' = "jobs:`n  a:`n    steps:`n      - uses: azure/bicep-deploy@$sha`n" })
Assert-Contains $e 'x.yml: uses azure/bicep-deploy, and only the apply job of mirror-deploy-unit.yml may' 'another workflow may not use the action that writes to Azure'
$e = @(Test-WorkflowHygiene @{ 'x.yml' = "jobs:`n  a:`n    environment: mirror-privileged-x`n" })
Assert-Contains $e 'x.yml: names a mirror-production or mirror-privileged*' 'another workflow may not name a privileged environment'
$e = @(Test-WorkflowHygiene @{ 'x.yml' = "jobs:`n  a:`n    environment: $applyEnv`n" })
Assert-Contains $e 'x.yml: builds an environment name from an expression*' 'another workflow may not build an environment name from the matrix'
$e = @(Test-DeployRules $goodDeploy.Replace("    environment:`n      name: mirror-reader-dispatch`n", ''))
Assert-Contains $e '*the job plan requests id-token: write and has no environment*' 'a job that asks for a token without an environment is refused'
$e = @(Test-WorkflowHygiene @{ 'v.yml' = "permissions:`n  contents: read`n  id-token: write`njobs:`n  a:`n    runs-on: windows-2025`n" })
Assert-Contains $e '*requests id-token in its top-level permissions*' 'a token for every job is refused'
$e = @(Test-WorkflowHygiene @{ 'x.yml' = "jobs:`n  apply:`n    environment: mirror-production-fdm-grc`n" })
Assert-Contains $e 'x.yml: names a mirror-production*' 'another workflow may not name a production environment'
$e = @(Test-WorkflowHygiene @{ 'mirror-pr.yml' = "jobs:`n  a:`n    steps:`n      - uses: azure/login@x`n      - name: Take the scripts from master`n      - name: Check the Bicep inputs`n        run: mirror-pipeline.ps1 -Mode InputCheck`n" })
Assert-Contains $e 'mirror-pr.yml: the step "Take the scripts from master" must come before the Azure sign-in' 'the reader jobs take master''s scripts before the sign-in'
Assert-Contains $e 'mirror-pr.yml: the step "Check the Bicep inputs" must come before the Azure sign-in' 'and check the Bicep inputs before it'
$e = @(Test-WorkflowHygiene @{ 'mirror-drift.yml' = "jobs:`n  a:`n    steps:`n      - uses: azure/login@x`n" })
Assert-Contains $e 'mirror-drift.yml: the step "Check the Bicep inputs" must run*' 'a reader job without the input check is refused'
$e = @(Test-WorkflowHygiene @{ 'mirror-deploy-unit.yml' = $goodDeploy.Replace("jobs:`n", "jobs:`n  first:`n    steps:`n      - run: x`n") })
Assert-Contains $e '*the step "Check the Bicep inputs" must come before the Azure sign-in*' 'the deploy workflow checks the Bicep inputs before it signs in'

Write-Host '--- the paths that make the portability job run the full preflight'
$cc = @(Find-CaseCollisions @('deploy/UNITS.json', 'infra/new.bicep') @('deploy/units.json', 'infra/a.bicep', 'deploy/UNITS.json', 'infra/new.bicep'))
Assert-Equal 1 $cc.Count 'an added name that differs only in case from another path is found'
Assert-Equal 'deploy/UNITS.json (deploy/UNITS.json and deploy/units.json)' $cc[0] 'and it names both paths'
Assert-Equal 0 @(Find-CaseCollisions @('infra/new.bicep') @('infra/a.bicep', 'infra/new.bicep')).Count 'an added name that is unique is not a collision'
Assert-Equal 0 @(Find-CaseCollisions @() @('infra/a.bicep')).Count 'no added path is no collision'
Assert-Equal 'Infra/b.bicep (Infra and infra)' (@(Find-CaseCollisions @('Infra/b.bicep') @('infra/a.bicep', 'Infra/b.bicep'))[0]) 'a folder that differs only in case is a collision too'
foreach ($p in @('scripts/preflight-validate.ps1', 'scripts/sub/x.sh', '.github/scripts/mirror-pipeline.ps1', '.github/scripts/tests/a.ps1', '.github/actions/setup-bicep/action.yml', 'bicepconfig.json', '.gitattributes', '.gitignore', '.github/workflows/mirror-validate.yml', 'scripts\x.ps1')) {
  Assert-True (Test-PortabilitySensitivePath $p) "sensitive: $p"
}
foreach ($p in @('infra/a.bicep', 'deploy/units.json', '.github/workflows/mirror-pr.yml', 'README.md', 'SCRIPTS/x.ps1', 'Scripts/x.ps1', 'infra/bicepconfig.json', 'pipelines/scripts/x.ps1', '.github/scriptsx/a.ps1', 'bicepconfig.json.bak', 'infra/.gitattributes', '.gitattributes.bak')) {
  Assert-True (-not (Test-PortabilitySensitivePath $p)) "not sensitive: $p"
}

Write-Host '--- the modes, on a temporary repository with recorded answers of the Azure CLI'
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
  Write-TestFile 'pipelines/pilot/empty-rg.bicep' '// pilot'
  Write-TestFile 'README.md' 'one'
  Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c1 | Out-Null
  $c1 = Invoke-TestGit rev-parse HEAD
  Write-TestFile 'pipelines/pilot/empty-rg.bicep' '// pilot, changed'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c2 | Out-Null
  $c2 = Invoke-TestGit rev-parse HEAD
  Write-TestFile 'README.md' 'two'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c3 | Out-Null
  $c3 = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c2 | Out-Null

  # The runner stands in for the Azure CLI. It records every call and answers from the files of the test case:
  # az-<command>.txt is printed with exit 0, az-<command>.fail is printed with exit 1, and no file is exit 0 with
  # no output. The commands are validate, whatif, show (the text of a preview) and stack (the stack itself).
  $runner = Join-Path $gx 'run-mode.ps1'
  [IO.File]::WriteAllText($runner, @'
param([string]$Mode, [string]$Dir)
function global:az {
  $a = @($args)
  Add-Content -LiteralPath (Join-Path $env:TEST_ANSWERS 'az-calls.txt') -Value ($a -join ' ')
  $kind = if ($a[0] -ceq 'stack' -and $a[2] -ceq 'validate') { 'validate' } elseif ($a[0] -ceq 'stack-whatif' -and $a[2] -ceq 'create') { 'whatif' }
          elseif ($a[0] -ceq 'stack-whatif' -and $a[2] -ceq 'show') { 'show' } elseif ($a[0] -ceq 'stack' -and $a[2] -ceq 'show') { 'stack' } else { 'other' }
  $bad = Join-Path $env:TEST_ANSWERS "az-$kind.fail"
  if (Test-Path -LiteralPath $bad) { $global:LASTEXITCODE = 1; return [IO.File]::ReadAllText($bad) }
  $global:LASTEXITCODE = 0
  $ok = Join-Path $env:TEST_ANSWERS "az-$kind.txt"
  if (Test-Path -LiteralPath $ok) { return [IO.File]::ReadAllText($ok) }
}
$helperArgs = @{ Mode = $Mode }
if ($Dir) { $helperArgs.Dir = $Dir }
& (Join-Path $env:TEST_REPO '.github/scripts/mirror-pipeline.ps1') @helperArgs
exit $LASTEXITCODE
'@)
  function Get-ModeFolder([string]$Name) { return (Join-Path $gx ("mode-" + ($Name -replace '[^a-z]', '-'))) }
  function Invoke-TestMode([string]$Mode, [hashtable]$Vars, [string]$Name, [int]$Expect, [string[]]$Pattern, [string]$Dir = '', [hashtable]$Answers = @{}) {
    $ans = Get-ModeFolder $Name; New-Item -ItemType Directory -Force $ans | Out-Null
    foreach ($k in $Answers.Keys) { [IO.File]::WriteAllText((Join-Path $ans $k), $Answers[$k]) }
    $out = Join-Path $ans 'output.txt'; Set-Content -LiteralPath $out -Value ''
    $all = @{ TEST_REPO = $g; TEST_ANSWERS = $ans; GITHUB_OUTPUT = $out; GITHUB_STEP_SUMMARY = (Join-Path $ans 'summary.md'); GITHUB_REPOSITORY = 'org/repo'; GITHUB_REF = 'refs/heads/master'; GITHUB_ACTOR = 'it-user-one'
              UNIT = ''; SELECT = ''; FAIL_ON_CHANGES = ''; OUTCOME = '' }
    foreach ($k in $Vars.Keys) { $all[$k] = $Vars[$k] }
    $prevVars = @{}
    foreach ($k in $all.Keys) { $prevVars[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try {
      $runArgs = @($childArgs) + @('-File', $runner, '-Mode', $Mode)
      if ($Dir) { $runArgs += @('-Dir', $Dir) }
      $console = & $childExe @runArgs 2>&1 | ForEach-Object { "$_" }
      $code = $LASTEXITCODE
    } finally {
      $ErrorActionPreference = $prevEap
      foreach ($k in $all.Keys) { [Environment]::SetEnvironmentVariable($k, $prevVars[$k]) }
    }
    $text = ($console -join "`n") + [IO.File]::ReadAllText($out)
    $sumFile = Join-Path $ans 'summary.md'; if (Test-Path -LiteralPath $sumFile) { $text += [IO.File]::ReadAllText($sumFile) }
    $ok = ($code -eq $Expect)
    foreach ($p in $Pattern) { if ($text.IndexOf($p, [StringComparison]::OrdinalIgnoreCase) -lt 0) { $ok = $false; Write-Host "      missing: $p" -ForegroundColor Yellow } }
    if (-not $ok) { Write-Host "      exit $code`n      $($text -replace "`n", "`n      ")" -ForegroundColor Yellow }
    Assert-True $ok "$($Mode.ToLowerInvariant()): $Name (exit $code, expected $Expect)"
  }

  # PortabilityScope. Two more commits on top of c2 (detached, so the later tests are unaffected): one touches a script and one touches Bicep only.
  Invoke-TestGit checkout -q --detach $c2 | Out-Null
  Write-TestFile 'scripts/preflight-validate.ps1' '# changed'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c5 | Out-Null
  $c5 = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c2 | Out-Null
  Write-TestFile 'infra/a.bicep' '// bicep'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c6 | Out-Null
  $c6 = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c5 | Out-Null
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = $c2 } 'a push that changes a script runs the full preflight' 0 'full=true'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = $c2 } 'and names the path' 0 'the change touches scripts/preflight-validate.ps1'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'pull_request' } 'a pull request that changes a script runs the full preflight' 0 'full=true'
  Invoke-TestGit checkout -q --detach $c6 | Out-Null
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = $c2 } 'a push that changes Bicep only skips the full preflight' 0 'full=false'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = $c2 } 'and says why' 0 'no full preflight, because the 1 changed file(s) touch no script'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'pull_request' } 'a pull request that changes Bicep only skips the full preflight' 0 'full=false'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'workflow_dispatch'; BEFORE = '0000000000000000000000000000000000000000' } 'Run workflow always runs the full preflight' 0 'full=true'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'workflow_dispatch' } 'and names the event' 0 'the event is workflow_dispatch'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'schedule' } 'any other event runs the full preflight' 0 'full=true'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = '0000000000000000000000000000000000000000' } 'a push with no earlier commit runs the full preflight' 0 'full=true'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = '' } 'a push with no BEFORE runs the full preflight' 0 'full=true'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = ('a' * 40) } 'a push whose earlier commit is not in the checkout runs the full preflight' 0 'full=true'
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'push'; BEFORE = ('a' * 40) } 'and says the commit is missing' 0 'is not in the checkout'
  Invoke-TestGit checkout -q --detach $c1 | Out-Null
  Invoke-TestMode 'PortabilityScope' @{ EVENT_NAME = 'pull_request' } 'a pull request whose HEAD has no parent runs the full preflight' 0 'full=true'
  Invoke-TestGit checkout -q --detach $c2 | Out-Null

  # Units, for Run workflow of mirror-deploy-unit. The pilot unit is enabled at this commit and no other unit is.
  $one = @{ SELECT = 'unit'; UNIT = 'pilot-empty-rg'; CHANGE_REF = 'CHG0012345'; REASON = 'Pilot.'; STARTED_BY = 'it-user-one' }
  $rowJson = 'matrix=[{"unit":"pilot-empty-rg","tier":"production","scope":"' + $pilot.subscription + '","stack":"mirror-pilot-empty-rg","stackScope":"resourceGroup","subscriptionId":"' + $subId + '","resourceGroup":"' + $pilot.resourceGroup + '","managementGroup":"","location":"' + $units.deploymentLocation + '","template":"pipelines/pilot/empty-rg.bicep","parameters":"","unmanage":"detach"}]'
  Invoke-TestMode 'Units' $one 'Run workflow gets the row of the unit it names, and the summary keeps the change ticket and the reason' 0 @($rowJson, ('Change ticket ' + $tick + 'CHG0012345' + $tick + '. Reason: ' + $tick + 'Pilot.' + $tick))
  $o2 = $one.Clone(); $o2['REASON'] = "x`n# heading [l](http://x)"
  Invoke-TestMode 'Units' $o2 'a reason with a line break stays one line in a code span' 0 ('Reason: ' + $tick + 'x | # heading [l](http://x)' + $tick)
  $o3 = $one.Clone(); $o3['UNIT'] = 'no-such-unit'
  Invoke-TestMode 'Units' $o3 'an unknown unit is refused before any sign-in' 1 "the unit 'no-such-unit' is not exactly one unit"
  $o4 = $one.Clone(); $o4['UNIT'] = 'Pilot-Empty-RG'
  Invoke-TestMode 'Units' $o4 'a unit name in another case is refused' 1 'is not exactly one unit'
  $o5 = $one.Clone(); $o5['UNIT'] = 'rg-demo-routing'
  Invoke-TestMode 'Units' $o5 'a unit that is not enabled is refused' 1 'the unit rg-demo-routing is not enabled'
  $o6 = $one.Clone(); $o6['UNIT'] = 'rg-demo-identities-deploy-excluded'
  Invoke-TestMode 'Units' $o6 'the unit of a deploy-excluded file is refused for a deployment' 1 'is the unit of a deploy-excluded file, and such a unit is never deployed'
  Invoke-TestMode 'Units' @{ SELECT = 'everything' } 'an unknown selection is refused' 2 "SELECT 'everything' is not unit, deployed or pullRequest"
  # Units, for the drift check. No unit is marked deployed in the repository's file.
  Invoke-TestMode 'Units' @{ SELECT = 'deployed' } 'with no deployed unit the drift check has an empty matrix and says so' 0 @('matrix=[]', 'No unit in deploy/units.json is marked "deployed": true')
  $depUnits = Copy-Object $unitsOn
  (@($depUnits.units) | Where-Object { $_.name -eq 'pilot-empty-rg' })[0] | Add-Member -Force -NotePropertyName deployed -NotePropertyValue $true
  (@($depUnits.units) | Where-Object { $_.name -eq 'rg-demo-routing' })[0] | Add-Member -Force -NotePropertyName deployed -NotePropertyValue 'true'
  (@($depUnits.units) | Where-Object { $_.name -eq 'rg-demo-network' })[0] | Add-Member -Force -NotePropertyName deployed -NotePropertyValue $false
  $exUnit = (@($depUnits.units) | Where-Object { $_.name -eq 'rg-demo-identities-deploy-excluded' })[0]
  $exUnit.enabled = $true; $exUnit | Add-Member -Force -NotePropertyName deployed -NotePropertyValue $true
  Write-TestFile 'deploy/units.json' (ConvertTo-Json $depUnits -Depth 20); Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m c7 | Out-Null
  Invoke-TestMode 'Units' @{ SELECT = 'deployed' } 'only a unit with deployed true, as a true and not as text, is checked for drift, and never the unit of a deploy-excluded file' 0 'Units: `pilot-empty-rg`.'
  $o7 = $one.Clone(); $o7['UNIT'] = 'rg-demo-identities-deploy-excluded'
  Invoke-TestMode 'Units' $o7 'the unit of a deploy-excluded file is refused for a deployment also when a change enabled it' 1 'is the unit of a deploy-excluded file, and such a unit is never deployed'
  Invoke-TestGit checkout -q --detach $c2 | Out-Null
  # Units, for a pull request of mirror-pr. The test merge commit has master's tip as its first parent.
  Invoke-TestGit checkout -q --detach $c1 | Out-Null
  Write-TestFile 'pipelines/pilot/empty-rg.bicep' '// pilot, from a branch'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m b1 | Out-Null
  $bCode = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Invoke-TestGit merge -q --no-ff -X theirs -m m1 $bCode | Out-Null
  $mCode = Invoke-TestGit rev-parse HEAD
  $pr = @{ SELECT = 'pullRequest'; BASE_REF = 'master'; HEAD_REPO = 'org/repo'; MERGE_SHA = $mCode }
  Invoke-TestMode 'Units' $pr 'a pull request that changes the file of a unit previews that unit, and counts the changed files against the tip of master' 0 @('matrix=[{"unit":"pilot-empty-rg"', '1 changed file(s), 1 unit(s) to preview.')
  $prFork = $pr.Clone(); $prFork['HEAD_REPO'] = 'someone/repo'
  Invoke-TestMode 'Units' $prFork 'a pull request from a fork is refused' 1 "comes from the repository 'someone/repo'"
  $prNoRepo = $pr.Clone(); $prNoRepo['HEAD_REPO'] = ''
  Invoke-TestMode 'Units' $prNoRepo 'a pull request with no head repository is refused' 1 'comes from the repository'
  $prOther = $pr.Clone(); $prOther['BASE_REF'] = 'dev'
  Invoke-TestMode 'Units' $prOther 'a pull request into another branch is refused' 1 'previews only pull requests into master'
  $prNoParent = $pr.Clone(); $prNoParent['MERGE_SHA'] = ('a' * 40)
  Invoke-TestMode 'Units' $prNoParent 'a merge commit that is not in the checkout is a set-up error' 2 'has no first parent in the checkout'
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Write-TestFile 'topic.txt' 'a document'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m b2 | Out-Null
  $bDoc = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Invoke-TestGit merge -q --no-ff -m m2 $bDoc | Out-Null
  $prDoc = $pr.Clone(); $prDoc['MERGE_SHA'] = (Invoke-TestGit rev-parse HEAD)
  Invoke-TestMode 'Units' $prDoc 'a pull request that changes no unit has an empty matrix' 0 'matrix=[]'
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  $delUnits = Copy-Object $unitsOn
  (@($delUnits.units) | Where-Object { $_.name -eq 'pilot-empty-rg' })[0] | Add-Member -Force -NotePropertyName stackDeletes -NotePropertyValue $true
  Write-TestFile 'deploy/units.json' (ConvertTo-Json $delUnits -Depth 20); Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m b3 | Out-Null
  $bUnits = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Invoke-TestGit merge -q --no-ff -m m3 $bUnits | Out-Null
  $prUnits = $pr.Clone(); $prUnits['MERGE_SHA'] = (Invoke-TestGit rev-parse HEAD)
  Invoke-TestMode 'Units' $prUnits 'a pull request that switches stackDeletes on previews the unit with delete' 0 '"unmanage":"delete"'
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Write-TestFile 'bicepconfig.json' '{}'; Invoke-TestGit add -A | Out-Null; Invoke-TestGit commit -q -m b4 | Out-Null
  $bCfg = Invoke-TestGit rev-parse HEAD
  Invoke-TestGit checkout -q --detach $c3 | Out-Null
  Invoke-TestGit merge -q --no-ff -m m4 $bCfg | Out-Null
  $prCfg = $pr.Clone(); $prCfg['MERGE_SHA'] = (Invoke-TestGit rev-parse HEAD)
  Invoke-TestMode 'Units' $prCfg 'a pull request that changes bicepconfig.json previews no single unit and says why' 0 'Every unit is compiled with it'
  Invoke-TestGit checkout -q --detach $c2 | Out-Null

  # StackWhatIf, with the recorded answers of the Azure CLI.
  $wi = @{ UNIT = 'pilot-empty-rg' }
  $driftJson = [IO.File]::ReadAllText((Join-Path $fixtures 'stack-whatif-drift.json'))
  $cleanJson = [IO.File]::ReadAllText((Join-Path $fixtures 'stack-whatif-clean.json'))
  $prettyText = "Changes to Managed Resources:`n`n  ~ /subscriptions/x/virtualNetworks/vnet-example`n    ~ tags.state: `"changed-by-hand`" => `"declared`"`n"
  $name = 'a preview with a change is the plan and does not fail'
  $od = Join-Path (Get-ModeFolder $name) 'out'
  Invoke-TestMode 'StackWhatIf' $wi $name 0 'result=DRIFT' $od -Answers @{ 'az-whatif.txt' = $driftJson; 'az-show.txt' = $prettyText }
  $taken = [regex]::Match([IO.File]::ReadAllText((Join-Path (Get-ModeFolder $name) 'output.txt')), '(?m)^taken=([0-9]{9,11})\s*$')
  Assert-True ($taken.Success -and [Math]::Abs([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$taken.Groups[1].Value) -lt 3600) 'the step output taken is the time of the preview in seconds, which the apply job reads as the age of the plan'
  $calls = @([IO.File]::ReadAllLines((Join-Path (Get-ModeFolder $name) 'az-calls.txt')))
  Assert-Equal 'stack group validate|stack-whatif group create|stack-whatif group show' (($calls | ForEach-Object { ($_ -split ' ')[0..2] -join ' ' }) -join '|') 'the stack is validated, previewed and read back, in that order, and nothing else is called'
  Assert-True ($calls[1] -like "*--stack-id /subscriptions/$subId/resourceGroups/$($pilot.resourceGroup)/providers/Microsoft.Resources/deploymentStacks/mirror-pilot-empty-rg *--retention-interval PT1H*--validation-level ProviderNoRbac*") 'the preview names the stack of the unit and runs at the reader validation level'
  Assert-True (($calls[2] -split ' ')[4] -ceq ($calls[1] -split ' ')[4] -and ($calls[1] -split ' ')[4] -cmatch '^mirror-pilot-empty-rg-[0-9]+(-[0-9]+)?$') 'the text is read from the preview that was just made'
  $saved = ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText((Join-Path $od 'whatif-result.json')))
  Assert-Equal 'pilot-empty-rg|DRIFT|1' "$($saved.unit)|$($saved.result)|$(@($saved.findings).Count)" 'the result file names the unit, the result and its findings'
  Assert-True ((Test-Path -LiteralPath (Join-Path $od 'whatif.json')) -and [IO.File]::ReadAllText((Join-Path $od 'whatif.txt')).Contains('changed-by-hand')) 'the JSON and the text of the preview are kept for the artifact'
  Assert-True ([IO.File]::ReadAllText((Join-Path (Get-ModeFolder $name) 'summary.md')).Contains('changed-by-hand')) 'the job summary holds the text of the preview'
  $wiFail = @{ UNIT = 'pilot-empty-rg'; FAIL_ON_CHANGES = 'true'; GITHUB_RUN_ID = '123456'; GITHUB_RUN_ATTEMPT = '2' }
  $name = 'the drift check fails on a preview with a change'
  Invoke-TestMode 'StackWhatIf' $wiFail $name 1 'differs from its code in 1 resource(s)' (Join-Path (Get-ModeFolder $name) 'out') -Answers @{ 'az-whatif.txt' = $driftJson; 'az-show.txt' = $prettyText }
  Assert-True (@([IO.File]::ReadAllLines((Join-Path (Get-ModeFolder $name) 'az-calls.txt')))[1] -like 'stack-whatif group create --name mirror-pilot-empty-rg-123456-2 *') 'in a workflow run the preview is named after the stack, the run and its attempt'
  $name = 'the drift check passes a clean preview'
  Invoke-TestMode 'StackWhatIf' $wiFail $name 0 'result=clean' (Join-Path (Get-ModeFolder $name) 'out') -Answers @{ 'az-whatif.txt' = $cleanJson; 'az-show.txt' = 'no change' }
  $diagJson = $cleanJson.Replace('"diagnostics": []', '"diagnostics": [ { "level": "warning", "code": "NestedDeploymentShortCircuited", "message": "A nested deployment got short-circuited.", "target": "/subscriptions/x/m1" } ]')
  Assert-True ($diagJson -cne $cleanJson) 'the clean fixture has an empty diagnostics list to fill'
  $name = 'the drift check counts a clean preview with a diagnostic as not checked'
  $od = Join-Path (Get-ModeFolder $name) 'out'
  Invoke-TestMode 'StackWhatIf' $wiFail $name 2 @('result=ERROR', 'so it is not a full check of the unit', 'the unit still counts as not checked') $od -Answers @{ 'az-whatif.txt' = $diagJson; 'az-show.txt' = 'no change' }
  $saved = ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText((Join-Path $od 'whatif-result.json')))
  Assert-True ($saved.result -ceq 'ERROR' -and @($saved.findings).Count -eq 2 -and $saved.findings[0] -like 'the preview is not a full check*' -and $saved.findings[1] -like 'warning NestedDeploymentShortCircuited*') 'and the result file carries the diagnostic for the drift issue'
  $name = 'a plan with a diagnostic still passes and lists it'
  Invoke-TestMode 'StackWhatIf' $wi $name 0 @('result=clean', 'Azure added 1 diagnostic message(s) to the preview') (Join-Path (Get-ModeFolder $name) 'out') -Answers @{ 'az-whatif.txt' = $diagJson; 'az-show.txt' = 'no change' }
  $name = 'a stack that is not valid stops before the preview'
  $od = Join-Path (Get-ModeFolder $name) 'out'
  Invoke-TestMode 'StackWhatIf' $wi $name 2 'The validation of the stack failed' $od -Answers @{ 'az-validate.fail' = 'InvalidTemplate: the template is not valid'; 'az-whatif.txt' = $cleanJson }
  Assert-Equal 1 @([IO.File]::ReadAllLines((Join-Path (Get-ModeFolder $name) 'az-calls.txt'))).Count 'no preview is taken of a stack that is not valid'
  Assert-Equal 'ERROR' (ConvertFrom-Json @MirrorJsonArgs -InputObject ([IO.File]::ReadAllText((Join-Path $od 'whatif-result.json')))).result 'and the result file says the unit was not checked'
  Assert-True ([IO.File]::ReadAllText((Join-Path (Get-ModeFolder $name) 'summary.md')).Contains('InvalidTemplate: the template is not valid')) 'the summary holds what the Azure CLI said'
  $name = 'a preview that Azure refuses is a failure'
  Invoke-TestMode 'StackWhatIf' $wiFail $name 2 'The preview of the stack failed' (Join-Path (Get-ModeFolder $name) 'out') -Answers @{ 'az-whatif.fail' = 'AuthorizationFailed' }
  $name = 'a preview with no output is a failure'
  Invoke-TestMode 'StackWhatIf' $wi $name 2 'The preview of the stack failed' (Join-Path (Get-ModeFolder $name) 'out')
  $name = 'a preview that is not JSON is a failure'
  Invoke-TestMode 'StackWhatIf' $wi $name 2 'Reading the preview of the stack failed' (Join-Path (Get-ModeFolder $name) 'out') -Answers @{ 'az-whatif.txt' = 'not json' }
  $name = 'a preview Azure did not finish is a failure'
  Invoke-TestMode 'StackWhatIf' $wi $name 2 'Azure did not finish the preview' (Join-Path (Get-ModeFolder $name) 'out') -Answers @{ 'az-whatif.txt' = $cleanJson.Replace('"provisioningState": "succeeded"', '"provisioningState": "failed"') }
  $name = 'a preview whose text cannot be read back still passes and lists the resources'
  Invoke-TestMode 'StackWhatIf' $wi $name 0 'could not be read back, so the resources are listed without their properties' (Join-Path (Get-ModeFolder $name) 'out') -Answers @{ 'az-whatif.txt' = $driftJson; 'az-show.fail' = 'AuthorizationFailed' }
  Invoke-TestMode 'StackWhatIf' $wi 'a call with no folder for the result is a set-up error' 2 '-Dir is required'
  $wiBad = @{ UNIT = 'no-such-unit' }
  $name = 'an unknown unit is refused before any call'
  Invoke-TestMode 'StackWhatIf' $wiBad $name 1 'is not exactly one unit' (Join-Path (Get-ModeFolder $name) 'out')
  Assert-True (-not (Test-Path -LiteralPath (Join-Path (Get-ModeFolder $name) 'az-calls.txt'))) 'the Azure CLI is not called for an unknown unit'

  # StackSummary, after the apply.
  $stackJson = [IO.File]::ReadAllText((Join-Path $fixtures 'stack-show.json'))
  $ss = @{ UNIT = 'pilot-empty-rg'; OUTCOME = 'success' }
  Invoke-TestMode 'StackSummary' $ss 'the summary of a deployment counts what the stack manages and deleted, and says what it does with what leaves its template' 0 @('| Managed resources | 1 |', '| Deleted in this deployment | 1 |', ('resources ' + $tick + 'delete' + $tick + ', resource groups ' + $tick + 'detach' + $tick + ', management groups ' + $tick + 'detach' + $tick), ('ended with ' + $tick + 'success' + $tick)) -Answers @{ 'az-stack.txt' = $stackJson }
  Invoke-TestMode 'StackSummary' $ss 'after a deployment of a unit that is not marked deployed the summary says to mark it' 0 'is not marked deployed yet' -Answers @{ 'az-stack.txt' = $stackJson }
  $ssHalf = @{ UNIT = 'pilot-empty-rg'; OUTCOME = 'failure' }
  $name = 'a failed deployment does not ask for the deployed mark'
  Invoke-TestMode 'StackSummary' $ssHalf $name 0 '| Managed resources | 1 |' -Answers @{ 'az-stack.txt' = $stackJson }
  Assert-True (-not [IO.File]::ReadAllText((Join-Path (Get-ModeFolder $name) 'summary.md')).Contains('is not marked deployed yet')) 'and its summary does not hold the sentence'
  $ssFail = @{ UNIT = 'pilot-empty-rg'; OUTCOME = 'failure' }
  Invoke-TestMode 'StackSummary' $ssFail 'a stack that cannot be read is said so with the outcome of the deployment step, and the step still ends' 0 @('The stack could not be read afterwards', ('ended with ' + $tick + 'failure' + $tick)) -Answers @{ 'az-stack.fail' = 'DeploymentStackNotFound' }
} finally {
  $script:RepoRoot = $keepRoot
  Remove-Item -LiteralPath $g, $gx -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '--- the drift report, with recorded GitHub answers'
# The pure parts first.
$dRows = @([pscustomobject]@{ unit = 'u1'; result = 'clean'; findings = @() }, [pscustomobject]@{ unit = 'u2'; result = 'DRIFT'; findings = @('modify /x') })
Assert-Equal 'drift' (Get-DriftState $dRows 'failure') 'a unit with drift makes the run a drift run'
Assert-Equal 'error' (Get-DriftState @([pscustomobject]@{ unit = 'u1'; result = 'ERROR'; findings = @('sign-in failed') }) 'failure') 'a unit that could not be checked makes the run an error run'
Assert-Equal 'error' (Get-DriftState $null 'failure') 'no result is an error run'
Assert-Equal 'error' (Get-DriftState @([pscustomobject]@{ unit = 'u1'; result = 'clean'; findings = @() }) 'failure') 'clean results of jobs that failed for another reason are an error run'
Assert-Equal 'clean' (Get-DriftState @([pscustomobject]@{ unit = 'u1'; result = 'clean'; findings = @() }) 'success') 'clean units of jobs that succeeded are a clean run'
$dLines = @(Format-DriftFindings $dRows)
Assert-Equal 2 $dLines.Count 'only the unit with drift is listed, with its finding'
Assert-True ($dLines[1].Contains([char]96 + 'modify /x' + [char]96)) 'a finding is a code span'
$bt = @(Format-DriftFindings @([pscustomobject]@{ unit = 'u'; result = 'DRIFT'; findings = @('a ' + [char]96 + 'b' + [char]96 + ' [c](http://x)') }))[1]
Assert-Equal 2 ([regex]::Matches($bt, [string][char]96).Count) 'a backtick in a finding cannot end its code span'
$b1 = Format-DriftIssueBody $dRows 'drift' 'https://run/1' 'failure'
$b2 = Format-DriftIssueBody $dRows 'drift' 'https://run/2' 'failure'
Assert-Equal $b1.fingerprint $b2.fingerprint 'the same findings in another run give the same fingerprint'
Assert-True ($b1.body -like '*<!-- mirror-drift findings *') 'the issue text ends with the marker'
Assert-True ($b2.body -like '*https://run/2*') 'the issue text names the run'
$b3 = Format-DriftIssueBody @([pscustomobject]@{ unit = 'u2'; result = 'DRIFT'; findings = @('modify /y') }) 'drift' 'https://run/3' 'failure'
Assert-True ($b3.fingerprint -cne $b1.fingerprint) 'other findings give another fingerprint'
$o1 = Format-DriftIssueBody @([pscustomobject]@{ unit = 'b'; result = 'DRIFT'; findings = @('detach /g2', 'detach /g1') }, [pscustomobject]@{ unit = 'a'; result = 'DRIFT'; findings = @('x') }) 'drift' 'r1' 'failure'
$o2 = Format-DriftIssueBody @([pscustomobject]@{ unit = 'a'; result = 'DRIFT'; findings = @('x') }, [pscustomobject]@{ unit = 'b'; result = 'DRIFT'; findings = @('detach /g1', 'detach /g2') }) 'drift' 'r2' 'failure'
Assert-Equal $o1.fingerprint $o2.fingerprint 'the same findings in another order give the same fingerprint'
Assert-True ((Format-DriftIssueBody $null 'error' 'https://run/4' 'failure').body -like '*ended before they wrote a result*') 'with no result the issue says the jobs ended early'
Assert-True ($b1.body -like '*Units checked: 2. Clean: 1. Drift: 1. Not checked: 0.*') 'the issue text counts the units'
# The results of the drift jobs, as the report job downloads them: one folder for each artifact.
$rr = Join-Path ([IO.Path]::GetTempPath()) ('mirror-rows-' + [guid]::NewGuid().ToString('N'))
try {
  foreach ($row in $dRows) {
    New-Item -ItemType Directory -Force -Path (Join-Path $rr "drift-$($row.unit)") | Out-Null
    [IO.File]::WriteAllText((Join-Path $rr "drift-$($row.unit)/whatif-result.json"), (ConvertTo-Json -InputObject $row -Depth 5))
  }
  New-Item -ItemType Directory -Force -Path (Join-Path $rr 'drift-u4') | Out-Null
  [IO.File]::WriteAllText((Join-Path $rr 'drift-u4/whatif-result.json'), 'not json')
  $read = @(Read-DriftRows $rr '[{"unit":"u1"},{"unit":"u2"},{"unit":"u3"},{"unit":"u4"}]')
  Assert-Equal 'u1=clean,u2=DRIFT,u3=ERROR,u4=ERROR' ((@($read | ForEach-Object { "$($_.unit)=$($_.result)" }) | Sort-Object) -join ',') 'a unit of the matrix with no result, or with one that cannot be read, is a unit that was not checked'
  Assert-Equal 2 @(Read-DriftRows $rr '').Count 'with no matrix the rows are the results that were written'
  Assert-Equal 0 @(Read-DriftRows (Join-Path $rr 'none') '').Count 'a folder that does not exist gives no rows'
} finally {
  Remove-Item -LiteralPath $rr -Recurse -Force -ErrorAction SilentlyContinue
}

# The mode, in a child PowerShell with a gh that answers from files and records every write.
$dr = Join-Path ([IO.Path]::GetTempPath()) ('mirror-drift-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dr | Out-Null
try {
  $drRunner = Join-Path $dr 'run-drift.ps1'
  [IO.File]::WriteAllText($drRunner, @'
param([string]$Dir)
function global:gh {
  $a = @($args)
  $p = [string]$a[-1]
  $x = [array]::IndexOf($a, '-X')
  if ($x -ge 0) {
    $in = [array]::IndexOf($a, '--input')
    $body = if ($in -ge 0) { [IO.File]::ReadAllText([string]$a[$in + 1]) } else { '' }
    Add-Content -LiteralPath (Join-Path $env:TEST_ANSWERS 'calls.txt') -Value "$($a[$x + 1]) $p $body"
    $global:LASTEXITCODE = 0; return '{"number":42}'
  }
  $f = Join-Path $env:TEST_ANSWERS 'issues.json'
  if ($p -notmatch '/issues\?' -or -not (Test-Path $f)) { $global:LASTEXITCODE = 1; return }
  $global:LASTEXITCODE = 0; [IO.File]::ReadAllText($f)
}
& (Join-Path $env:TEST_HELPER_DIR 'mirror-pipeline.ps1') -Mode DriftReport -Dir $Dir
exit $LASTEXITCODE
'@)
  function Invoke-DriftCase([string]$Name, $Rows, [string]$JobResult, [string]$Issues, [string[]]$Expect, [string[]]$Absent = @(), [string]$Matrix = '') {
    $case = Join-Path $dr ($Name -replace '[^a-z]', '-'); New-Item -ItemType Directory -Force $case | Out-Null
    $sumDir = Join-Path $case 'drift'; New-Item -ItemType Directory -Force $sumDir | Out-Null
    foreach ($row in @($Rows | Where-Object { $null -ne $_ })) {
      New-Item -ItemType Directory -Force (Join-Path $sumDir "drift-$($row.unit)") | Out-Null
      [IO.File]::WriteAllText((Join-Path $sumDir "drift-$($row.unit)/whatif-result.json"), (ConvertTo-Json -InputObject $row -Depth 5))
    }
    [IO.File]::WriteAllText((Join-Path $case 'issues.json'), $Issues)
    $keep = @{}
    $set = @{ TEST_ANSWERS = $case; TEST_HELPER_DIR = (Split-Path -Parent $helper); GITHUB_REPOSITORY = 'org/repo'; DRIFT_RESULT = $JobResult; MATRIX = $Matrix; RUN_URL = 'https://run/9'; GITHUB_STEP_SUMMARY = (Join-Path $case 'summary.md'); GITHUB_OUTPUT = '' }
    foreach ($k in $set.Keys) { $keep[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $set[$k]) }
    $prevEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $console = & $childExe @($childArgs + @('-File', $drRunner, '-Dir', $sumDir)) 2>&1 | ForEach-Object { "$_" }; $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $prevEap; foreach ($k in $set.Keys) { [Environment]::SetEnvironmentVariable($k, $keep[$k]) } }
    $calls = if (Test-Path (Join-Path $case 'calls.txt')) { [IO.File]::ReadAllText((Join-Path $case 'calls.txt')) } else { '' }
    $text = ($console -join "`n") + "`n" + $calls
    $ok = ($code -eq 0)
    foreach ($e in $Expect) { if ($text -notlike ('*' + [WildcardPattern]::Escape($e) + '*')) { $ok = $false; Write-Host "      missing: $e" -ForegroundColor Yellow } }
    foreach ($e in $Absent) { if ($text -like ('*' + [WildcardPattern]::Escape($e) + '*')) { $ok = $false; Write-Host "      present: $e" -ForegroundColor Yellow } }
    if (-not $ok) { Write-Host "      exit $code`n      $($text -replace "`n", "`n      ")" -ForegroundColor Yellow }
    Assert-True $ok "drift report: $Name"
  }
  $title = $script:DriftIssueTitle
  $driftRows = @([pscustomobject]@{ unit = 'u2'; result = 'DRIFT'; findings = @('modify /x') })
  $cleanRows = @([pscustomobject]@{ unit = 'u2'; result = 'clean'; findings = @() })
  $fpNow = (Format-DriftIssueBody $driftRows 'drift' 'x' 'failure').fingerprint
  $bot = @{ login = 'github-actions[bot]' }
  $openSame = ConvertTo-Json -Compress -Depth 5 -InputObject @(,@([ordered]@{ number = 7; title = $title; user = $bot; body = "old text`n<!-- mirror-drift findings $fpNow -->" }))
  $openOther = ConvertTo-Json -Compress -Depth 5 -InputObject @(,@([ordered]@{ number = 7; title = $title; user = $bot; body = "old text`n<!-- mirror-drift findings $('0' * 64) -->" }))
  $openPr = ConvertTo-Json -Compress -Depth 5 -InputObject @(,@([ordered]@{ number = 8; title = $title; user = $bot; body = ''; pull_request = @{ url = 'x' } }, [ordered]@{ number = 9; title = 'another issue'; user = $bot; body = '' }, [ordered]@{ number = 10; title = $title; user = @{ login = 'someone' }; body = '' }))
  $openMarker = ConvertTo-Json -Compress -Depth 5 -InputObject @(,@([ordered]@{ number = 7; title = $title; user = $bot; body = "- <!-- mirror-drift findings $('1' * 64) -->`n<!-- mirror-drift findings $fpNow -->" }))
  Invoke-DriftCase 'drift with no open issue opens one' $driftRows 'failure' '[[]]' @('POST repos/org/repo/issues {', 'issue #42 is opened (drift)', 'modify /x')
  Invoke-DriftCase 'the same findings update the issue and add no comment' $driftRows 'failure' $openSame @('PATCH repos/org/repo/issues/7 {', 'its findings are the same') @('issues/7/comments')
  Invoke-DriftCase 'other findings update the issue and add a comment' $driftRows 'failure' $openOther @('PATCH repos/org/repo/issues/7 {', 'POST repos/org/repo/issues/7/comments', 'its findings changed')
  Invoke-DriftCase 'a clean run closes the open issue with a comment' $cleanRows 'success' $openSame @('POST repos/org/repo/issues/7/comments', '"state":"closed"', 'issue #7 is closed')
  Invoke-DriftCase 'a clean run with no open issue writes nothing' $cleanRows 'success' '[[]]' @('no drift issue is open') @('POST ', 'PATCH ')
  Invoke-DriftCase 'no result opens the issue as not checked' $null 'failure' '[[]]' @('POST repos/org/repo/issues {', 'ended before they wrote a result', '(error)')
  Invoke-DriftCase 'a unit whose job wrote no result is named in the issue' $cleanRows 'failure' '[[]]' @('POST repos/org/repo/issues {', 'u9', 'wrote no result', '(error)') -Matrix '[{"unit":"u2"},{"unit":"u9"}]'
  Invoke-DriftCase 'a pull request, an issue of another title and one by another user are left alone' $driftRows 'failure' $openPr @('POST repos/org/repo/issues {') @('issues/8', 'issues/9', 'issues/10')
  Invoke-DriftCase 'the marker of the report is the last one in the text' $driftRows 'failure' $openMarker @('its findings are the same') @('issues/7/comments')
} finally {
  Remove-Item -LiteralPath $dr -Recurse -Force -ErrorAction SilentlyContinue
}

Restore-RunnerEnv
Write-Host ''
Write-Host ("{0} passed, {1} failed." -f $script:passes, $script:failures)
if ($script:failures -gt 0) { exit 1 }
exit 0

