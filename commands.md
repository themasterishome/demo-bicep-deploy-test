```powershell
az version
```

```powershell
gh --version
```

```powershell
git --version
```

```powershell
python --version
```

```powershell
git remote -v
```

```powershell
az account show --query "{name:name, tenantId:tenantId, user:user.name}" -o json
```

```powershell
az login --tenant d1a349ef-6ac8-4588-a88d-5dab272c700b
```

```powershell
az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

```powershell
gh auth switch --hostname github.com --user themasterishome
```

```powershell
gh auth status
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/collaborators --jq ".[] | {login: .login, admin: .permissions.admin, push: .permissions.push}"
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/environments --jq ".environments[].name"
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/environments/mirror-production-demo --jq ".protection_rules"
```

```powershell
foreach ($e in 'mirror-reader-dispatch', 'mirror-production-demo', 'mirror-privileged-demo', 'mirror-privileged-tenant') { Write-Host $e; gh api "repos/themasterishome/demo-bicep-deploy-test/environments/$e/deployment-branch-policies" --jq ".branch_policies[].name" }
```

```powershell
az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az lock list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, level:level}" -o table
```

```powershell
az role definition list --custom-role-only true --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].roleName" -o tsv
```

```powershell
az role assignment list --assignee-object-id (az identity show --name id-mirror-deploy-demo --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query principalId -o tsv) --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

```powershell
az keyvault show --name kv-demo-mirror-secrets --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "{rbac:properties.enableRbacAuthorization, template:properties.enabledForTemplateDeployment, retention:properties.softDeleteRetentionInDays, purge:properties.enablePurgeProtection, firewall:properties.networkAcls.defaultAction}" -o json
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/actions/oidc/customization/sub
```

```powershell
foreach ($i in 'id-mirror-reader', 'id-mirror-deploy-demo', 'id-mirror-govern-demo', 'id-mirror-govern-tenant') { az identity federated-credential list --identity-name $i --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].subject" -o tsv }
```

```powershell
$repo = 'themasterishome/demo-bicep-deploy-test'
$sub = '77488719-1168-4d53-af9a-f5c3bc9291d7'
$repoId = gh api "repos/$repo" --jq .id
$pairs = @(
  @('mirror-reader', 'id-mirror-reader'),
  @('mirror-reader-dispatch', 'id-mirror-reader'),
  @('mirror-production-demo', 'id-mirror-deploy-demo'),
  @('mirror-privileged-demo', 'id-mirror-govern-demo'),
  @('mirror-privileged-tenant', 'id-mirror-govern-tenant')
)
foreach ($pair in $pairs) {
  $name = $pair[0]
  $identity = $pair[1]
  $variables = @(gh variable list --env $name --repo $repo --json name,value | Out-String | ConvertFrom-Json)
  $variable = [string](($variables | ForEach-Object { $_ }) | Where-Object { $_.name -eq 'AZURE_CLIENT_ID' }).value
  $client = az identity show --name $identity --resource-group rg-demo-identities --subscription $sub --query clientId -o tsv
  $subjects = @(az identity federated-credential list --identity-name $identity --resource-group rg-demo-identities --subscription $sub --query "[].subject" -o tsv)
  $expected = "repo:themasterishome@49098959/demo-bicep-deploy-test@${repoId}:environment:${name}"
  $idOk = ($variable -eq $client)
  $subjectOk = ($subjects -contains $expected)
  Write-Host "$name -> $identity : client ID matches $idOk, credential for the environment $subjectOk"
}
```

```powershell
foreach ($e in 'mirror-reader', 'mirror-reader-dispatch', 'mirror-production-demo', 'mirror-privileged-demo', 'mirror-privileged-tenant') { Write-Host $e; gh variable list --env $e --repo themasterishome/demo-bicep-deploy-test }
```

```powershell
az account management-group show --name mg-demo
```

```powershell
az group list --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[?tags.purpose=='demo-bicep-deploy'].name" -o tsv
```

```powershell
az resource list --resource-group rg-demo-network --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az resource list --resource-group rg-demo-routing --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az stack sub list --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az stack group list --resource-group rg-demo-network --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az stack group list --resource-group rg-demo-routing --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az stack mg list --management-group-id mg-demo --query "[].name" -o tsv
```

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

```powershell
Select-String -Path deploy\units.json -Pattern '"enabled"'
```

```powershell
gh run list --workflow mirror-deploy-unit.yml --status waiting --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test --jq .has_issues
```

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh issue close ISSUE_NUMBER --comment "Closed before a new run of the demo" --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/rulesets --jq ".[].name"
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/environments --jq ".environments[].name"
```

```powershell
az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
gh api --method DELETE repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example
```

```powershell
az group delete --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --yes
```

```powershell
$branchPolicy = @{ protected_branches = $false; custom_branch_policies = $true }
```

```powershell
@{ deployment_branch_policy = $branchPolicy } | ConvertTo-Json -Depth 4 | gh api --method PUT repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example --input -
```

```powershell
gh api --method POST repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example/deployment-branch-policies -f name=master -f type=branch
```

```powershell
az group create --name rg-demo-example --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-example -o table
```

```powershell
$example = az identity create --name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth -o json | Out-String | ConvertFrom-Json
```

```powershell
$example | Select-Object name, clientId, principalId
```

```powershell
az role assignment create --assignee-object-id $example.principalId --assignee-principal-type ServicePrincipal --role acdd72a7-3385-48ef-bd42-f606fba81ae7 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o table
```

```powershell
$repoId = gh api repos/themasterishome/demo-bicep-deploy-test --jq .id
```

```powershell
az identity federated-credential create --name github-mirror-example --identity-name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --issuer https://token.actions.githubusercontent.com --subject "repo:themasterishome@49098959/demo-bicep-deploy-test@${repoId}:environment:mirror-example" --audiences api://AzureADTokenExchange -o table
```

```powershell
gh variable set AZURE_CLIENT_ID --env mirror-example --body $example.clientId --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable list --env mirror-example --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh api --method DELETE repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example
```

```powershell
az role assignment delete --assignee $example.principalId --role acdd72a7-3385-48ef-bd42-f606fba81ae7 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

```powershell
az identity delete --name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

```powershell
az group delete --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --yes
```

```powershell
az group exists --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

```powershell
az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

```powershell
gh auth switch --hostname github.com --user themasterishome
```

```powershell
git switch master
```

```powershell
git status --short
```

```powershell
git log --oneline -3
```

```powershell
(Get-Content deploy\units.json -Raw) -replace '"enabled": true', '"enabled": false' | Set-Content deploy\units.json -NoNewline
```

```powershell
Select-String -Path deploy\units.json -Pattern '"enabled"'
```

```powershell
git add deploy/units.json
```

```powershell
git commit -m "Disable every unit for the next demo"
```

```powershell
git push test HEAD:master
```

```powershell
git push origin HEAD:refs/heads/sync-demo
```

```powershell
gh auth refresh -h github.com -s workflow
```

```powershell
gh auth switch --hostname github.com --user themasterishome
```

```powershell
gh auth setup-git
```

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch --create first-checks
```

```powershell
Add-Content -Path README.md -Value ''
```

```powershell
git commit --all --message "First run of the checks"
```

```powershell
git push -u test first-checks
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head first-checks --title "First run of the checks" --body "First run of the checks"
```

```powershell
gh pr close first-checks --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh issue close ISSUE_NUMBER --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-drift.yml --ref first-checks --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git push test --delete first-checks
```

```powershell
git branch --delete --force first-checks
```

```powershell
foreach ($g in 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') { az group create --name $g --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy --query properties.provisioningState -o tsv }
```

```powershell
git switch --create enable-pilot
```

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "pilot-empty-rg".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

```powershell
git diff --stat
```

```powershell
git commit --all --message "Enable the pilot unit"
```

```powershell
git push -u test enable-pilot
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-pilot --title "Enable the pilot unit" --body "Enable the pilot unit"
```

```powershell
gh pr merge enable-pilot --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

```powershell
gh run list --workflow mirror-deploy-unit.yml --branch master --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot, plan only" --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh run list --workflow mirror-deploy-unit.yml --limit 1 --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh run watch RUN_ID --repo themasterishome/demo-bicep-deploy-test
```

```powershell
az stack group show --name mirror-pilot-empty-rg --resource-group rg-demo-pilot --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "{state:provisioningState, resources:length(resources), unmanage:actionOnUnmanage, deny:denySettings.mode, by:systemData.createdBy}" -o json
```

```powershell
gh run download RUN_ID --name plan-pilot-empty-rg --dir C:\demo-setup\plan-pilot --repo themasterishome/demo-bicep-deploy-test
```

```powershell
Get-Content deploy\adoption\rg-demo-network.md
```

```powershell
git switch --create enable-waves
```

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "rg-demo-network".*?"enabled": )false', '${1}true' -replace '(?s)("name": "rg-demo-routing".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

```powershell
git diff --stat
```

```powershell
git commit --all --message "Enable the network and routing units"
```

```powershell
git push -u test enable-waves
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-waves --title "Enable the network and routing units" --body "Enable the network and routing units"
```

```powershell
gh pr merge enable-waves --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, bring the network under the stack" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, plan after the first deployment" --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch --create network-deployed
```

```powershell
git rm deploy\adoption\rg-demo-network.md
```

```powershell
git commit --all --message "Mark rg-demo-network deployed and remove its adoption file"
```

```powershell
git push -u test network-deployed
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head network-deployed --title "Mark rg-demo-network deployed" --body "First deployment done"
```

```powershell
gh pr merge network-deployed --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, bring the routing under the stack" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch --create enable-privileged
```

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "demo-privileged".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

```powershell
git diff --stat
```

```powershell
git commit --all --message "Enable the privileged unit"
```

```powershell
git push -u test enable-privileged
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-privileged --title "Enable the privileged unit" --body "Enable the privileged unit"
```

```powershell
gh pr merge enable-privileged --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, the privileged unit" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch --create enable-subscription
```

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "demo-subscription".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

```powershell
git commit --all --message "Enable the subscription unit"
```

```powershell
git push -u test enable-subscription
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-subscription --title "Enable the subscription unit" --body "Enable the subscription unit"
```

```powershell
gh pr merge enable-subscription --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-subscription -f changeRef=DEMO-0007 -f reason="Wave 3, the subscription layer" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch --create enable-tenant-governance
```

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "demo-tenant-governance".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

```powershell
git commit --all --message "Enable the management group governance unit"
```

```powershell
git push -u test enable-tenant-governance
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-governance --title "Enable the management group governance unit" --body "Enable the management group governance unit"
```

```powershell
gh pr merge enable-tenant-governance --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 5, Reader on the management group" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
az stack mg show --management-group-id mg-demo --name mirror-demo-tenant-governance --query "{state:provisioningState, unmanage:actionOnUnmanage, resources:resources[].id}" -o json
```

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0010 -f reason="Undo the drift on nsg-demo" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable set MIRROR_DRIFT_SCHEDULE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch --create network-tag
```

```powershell
git commit --all --message "A tag on nsg-demo"
```

```powershell
git push -u test network-tag
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head network-tag --title "A tag on nsg-demo" --body "A tag on nsg-demo"
```

```powershell
gh pr merge network-tag --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0011 -f reason="A tag on nsg-demo" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body false --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable delete MIRROR_DRIFT_SCHEDULE_ENABLED --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

```powershell
az stack sub list --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az stack sub delete --name mirror-demo-subscription --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --action-on-unmanage detachAll --yes
```

```powershell
gh auth switch --hostname github.com --user klaudiomarashi
```

```powershell
az account set --subscription SUBSCRIPTION_ID
```

```powershell
az stack group show --name mirror-UNIT --resource-group RESOURCE_GROUP --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "{state:provisioningState, error:error, failed:failedResources}"
```

```powershell
az stack sub show --name mirror-UNIT --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "{state:provisioningState, error:error, failed:failedResources}"
```

```powershell
az stack mg show --name mirror-UNIT --management-group-id MANAGEMENT_GROUP_ID --query "{state:provisioningState, error:error, failed:failedResources}"
```

