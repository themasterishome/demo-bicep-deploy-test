# The demo, as a script

This is the script for the talk. It runs the same steps as the production setup, with the same commands and in the same order, against the test repository `themasterishome/demo-bicep-deploy-test` and the Visual Studio subscription in the test tenant.

How to read it:

- A quoted paragraph is what you say.
- A code block is one command. From "One example, made and removed" on, the quoted line above the block says what that command is and what it does. Say that line, copy the command, run it, and wait for it to finish before the next one.
- Any other paragraph is a cue for you: what you should see, and what to do when the result is different. In Part 0 the cue also says why the check is there.
- A quoted paragraph that starts with "In production" is still something you say. It tells the audience where the real setup does the same thing a little differently.

Run every command in a Windows PowerShell window in this folder, never in Git Bash. Git Bash rewrites an argument that starts with `/subscriptions/` into a Windows path, and the command then fails. Do the whole of Part 2 in one window. Its blocks share the variables `$branchPolicy`, `$example` and `$repoId`, and a new window has none of them. The other parts use no variable from an earlier block.

In this folder the test repository's remote is named `test`. GUIDE.md calls that same remote `origin`. Use `test` in every command here. GUIDE.md has the full detail behind each step. The GUIDE.md numbers in the headings are the same numbers as the project's PIPELINE.md. The numbers of this script, 1 to 18, are the order of the talk.

Two accounts take part. `themasterishome` owns the repository, writes the code, merges, and starts every run. `klaudiomarashi` reviews pull requests and approves deployments, in a private browser window. GitHub will not let an account approve a deployment that the same account started.

Names, used the same way all the way through:

- **Pipeline switch.** The repository variable `MIRROR_PIPELINE_ENABLED`. While it is not `true`, every job skips.
- **Weekly drift switch.** The repository variable `MIRROR_DRIFT_SCHEDULE_ENABLED`. It allows the Monday run.
- **Enabled flag.** `"enabled"` on one unit in `deploy/units.json`. A unit is included in a run only when its flag is `true`.
- **GitHub environment.** A named place in the repository settings where a job runs. It holds that job's variables and its protection rules. A deployment waits for approval in a GitHub environment.
- **Managed identity.** An Azure identity whose credentials Azure holds. A job signs in as one. There is no password to copy. The four in this demo are the reader identity `id-mirror-reader`, the deploy identity `id-mirror-deploy-demo`, and the govern identities `id-mirror-govern-demo` and `id-mirror-govern-tenant`.
- **Reader role.** The built-in Azure role that can read a scope. It is a permission. It is a different thing from the reader identity.
- **Federated credential.** The trust record on a managed identity. Azure accepts GitHub's short-lived token only when the token's subject names this repository and one GitHub environment.
- **What-if.** Azure's preview of a deployment. It reports what would change, and it writes nothing.
- **Gate.** The check that reads every record of a what-if and passes or fails the run.
- **Second check.** A fresh what-if taken after the deployment.
- **Tier.** Production or privileged. A privileged unit sets `"tier": "privileged"` in `deploy/units.json`. The tier chooses the managed identity, the GitHub environment, and which approval the run waits for.

A plan job takes one to two minutes. An apply job takes about three. Say the quoted line, start the run, and use the wait to point at what the screen is doing.

## Part 0. Before the audience arrives

These checks are not part of the talk. Run them first, so the talk does not stop on a missing piece. If a check shows that something is missing, the GUIDE.md step named in that heading is the one that creates it.

### The tools

Confirm that Azure CLI (2.76 or later), GitHub CLI (2.48 or later), Git (2.28 or later) and Python 3 respond, then confirm that this folder's Git remote is the test repository. Python is used once, in step 10, to unpack the evidence zip.

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

`git remote -v` lists the remote `test` with the address `https://github.com/themasterishome/demo-bicep-deploy-test.git`.

### The Azure sign-in

Confirm that Azure CLI is in the demo tenant and on the Visual Studio subscription before any later Azure command.

```powershell
az account show --query "{name:name, tenantId:tenantId, user:user.name}" -o json
```

The output names the Visual Studio Enterprise Subscription and the tenant `d1a349ef-6ac8-4588-a88d-5dab272c700b`. **Only if it does not**, sign in to that tenant and select the subscription.

```powershell
az login --tenant d1a349ef-6ac8-4588-a88d-5dab272c700b
```

```powershell
az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

### The GitHub sign-ins

The commands in the talk run as `themasterishome`. Switch to that account, then confirm the token can push workflow files.

```powershell
gh auth switch --hostname github.com --user themasterishome
```

```powershell
gh auth status
```

The active account is `themasterishome`, with the scopes `repo` and `workflow`. In a private browser window, `klaudiomarashi` is signed in to github.com.

### The repository and the second account

Confirm that the reviewer account is a collaborator. `klaudiomarashi` needs access so that account can approve.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/collaborators --jq ".[] | {login: .login, admin: .permissions.admin, push: .permissions.push}"
```

The output lists `themasterishome` with `admin` true and `klaudiomarashi` with `push` true. If the repository is gone, do GUIDE.md section 3 from step 3.3.

### The five GitHub environments (GUIDE.md step 3.11)

List the GitHub environments, then read the protection rule on the one where a normal deployment waits.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/environments --jq ".environments[].name"
```

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/environments/mirror-production-demo --jq ".protection_rules"
```

The first command lists `mirror-reader`, `mirror-reader-dispatch`, `mirror-production-demo`, `mirror-privileged-demo` and `mirror-privileged-tenant`. The second shows a `required_reviewers` rule with `prevent_self_review` true and the second account.

`mirror-reader` and `mirror-reader-dispatch` are where the reader identity signs in. The other three are where a deployment waits for approval.

A run from another branch is refused only when the environment has a branch rule, and step 5 shows that refusal. Read the branch rule of the four environments that need one.

```powershell
foreach ($e in 'mirror-reader-dispatch', 'mirror-production-demo', 'mirror-privileged-demo', 'mirror-privileged-tenant') { Write-Host $e; gh api "repos/themasterishome/demo-bicep-deploy-test/environments/$e/deployment-branch-policies" --jq ".branch_policies[].name" }
```

Every environment name is followed by `master`. A name with nothing under it has no branch rule, and GUIDE.md step 3.11 adds it with its `gh api --method POST` line.

### The managed identities, the lock and the roles (GUIDE.md steps 3.12 to 3.15)

Confirm the four managed identities, the delete lock that protects them, and the custom roles the setup created.

```powershell
az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az lock list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, level:level}" -o table
```

```powershell
az role definition list --custom-role-only true --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].roleName" -o tsv
```

The first command lists `id-mirror-reader`, `id-mirror-deploy-demo`, `id-mirror-govern-demo` and `id-mirror-govern-tenant`. The second lists the lock `mirror-identities-no-delete`. The third lists the Mirror roles of GUIDE.md step 3.13. The role `Demo Reader Plus` appears only after step 13, wave 4.

### The deploy identity's roles and the vault (GUIDE.md steps 3.12 and 3.15)

Read the roles of the deploy identity and the settings of the secrets vault. A missing role shows up late, as `AuthorizationFailed` or `LinkedAuthorizationFailed` in step 11 or 12, in front of the audience.

```powershell
az role assignment list --assignee-object-id (az identity show --name id-mirror-deploy-demo --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query principalId -o tsv) --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{role:roleDefinitionName, scope:scope}" -o table
```

```powershell
az keyvault show --name kv-demo-mirror-secrets --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "{rbac:properties.enableRbacAuthorization, template:properties.enabledForTemplateDeployment, retention:properties.softDeleteRetentionInDays, purge:properties.enablePurgeProtection, firewall:properties.networkAcls.defaultAction}" -o json
```

The first command lists Contributor and Mirror Lock Writer on each of the three workload groups, Resource Policy Contributor, Mirror Platform Deployment and Role Based Access Control Administrator on the subscription, and Mirror Key Vault Deployment on `kv-demo-mirror-secrets`. Nothing is listed on the group `rg-demo-identities` itself. The second command prints `"rbac": true`, `"template": true`, `"retention": 90`, `"purge": true` and `"firewall": "Deny"`. Nothing here reads the secret.

### The federated credentials (GUIDE.md steps 3.16 and 3.17)

Read the subject prefix GitHub puts on a token, then list the subjects the managed identities trust. A later sign-in works only when those two match.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/actions/oidc/customization/sub
```

```powershell
foreach ($i in 'id-mirror-reader', 'id-mirror-deploy-demo', 'id-mirror-govern-demo', 'id-mirror-govern-tenant') { az identity federated-credential list --identity-name $i --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].subject" -o tsv }
```

The first command prints a `sub_claim_prefix` of the form `repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID`. The second prints five subjects. Each one is that prefix, then `:environment:`, then the name of one GitHub environment. The reader identity has two, because it serves `mirror-reader` and `mirror-reader-dispatch`. The other three identities have one each. If a subject differs, GUIDE.md step 3.17, item 2, replaces it in place.

### The environment variables match the managed identities (GUIDE.md steps 3.18 and 3.19)

Each GitHub environment stores `AZURE_CLIENT_ID`, the public client ID of the managed identity that jobs in that environment use. This script checks two things for every environment: the variable equals that identity's client ID, and the identity has a federated credential whose subject names that environment. Copy it as a whole.

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

The output is five lines, and both values on every line are `True`.

The workflows also read `AZURE_TENANT_ID` from each environment. List the variables of every environment to see both.

```powershell
foreach ($e in 'mirror-reader', 'mirror-reader-dispatch', 'mirror-production-demo', 'mirror-privileged-demo', 'mirror-privileged-tenant') { Write-Host $e; gh variable list --env $e --repo themasterishome/demo-bicep-deploy-test }
```

Each environment lists `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`, and the tenant ID is `d1a349ef-6ac8-4588-a88d-5dab272c700b`.

### The management group (GUIDE.md step 3.15, item 8)

Wave 5 deploys the management group `mg-demo`, which was created once by hand. Confirm it is there before the talk.

```powershell
az account management-group show --name mg-demo
```

The output names the group. An error that the group is not found, or `AuthorizationFailed`, means it is missing.

### What is deployed already

See which demo resource groups exist, and whether the network and routing groups already hold resources. That decides whether the later waves show Create records or NoChange.

```powershell
az group list --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[?tags.purpose=='demo-bicep-deploy'].name" -o tsv
```

```powershell
az resource list --resource-group rg-demo-network --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

```powershell
az resource list --resource-group rg-demo-routing --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

The first command lists `rg-demo-identities`, `rg-demo-pilot`, `rg-demo-network` and `rg-demo-routing`. If the other two commands print nothing, those groups are empty and the waves create the resources. If they print resource names, those units are deployed already. Their plans then show NoChange and need no `allowCreate`. That shows the second-run proof, and it skips the Create records. To show the Create records, remove the demo with GUIDE.md section 6 and set it up again with section 3.

### The pipeline switch is off, and the units are still enabled

These are two different controls. The pipeline switch is a repository variable. The enabled flags are inside `deploy/units.json`. Check both.

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

```powershell
Select-String -Path deploy\units.json -Pattern '"enabled"'
```

The variable list shows no `MIRROR_PIPELINE_ENABLED` and no `MIRROR_DRIFT_SCHEDULE_ENABLED`, or shows them as `false`. The second command shows seven lines, one for each unit, each `true` or `false`. Step 2 sets all seven enabled flags to `false` before anything runs. The pull requests in steps 6, 11, 13, 14 and 15 set six of them back to `true`, one unit at a time. `demo-subscription` is wave 3 and stays disabled in this demo.

### No deployment run is waiting from an earlier demo

A deployment run that waits for approval holds the place of its unit, so a newer run of the same unit waits behind it. List the runs that wait.

```powershell
gh run list --workflow mirror-deploy-unit.yml --status waiting --repo themasterishome/demo-bicep-deploy-test
```

The command prints nothing. **Only if** it lists a run, open it, select **Review deployments** and **Reject**, and write a comment that names the reason. An apply whose `master` has moved refuses after its approval anyway.

### Issues are on, and no drift issue is open

The drift workflow keeps a single GitHub issue up to date. Confirm that Issues are enabled, and that no drift issue is still open from an earlier run.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test --jq .has_issues
```

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

The first prints `true`. The second prints nothing. **Only if** it lists the issue "The drift check found a difference between live Azure and the code, or a unit it could not check", close it. The drift report keeps one issue, and step 5 would otherwise comment on the old one. Replace `ISSUE_NUMBER` with the number the list prints.

```powershell
gh issue close ISSUE_NUMBER --comment "Closed before a new run of the demo" --repo themasterishome/demo-bicep-deploy-test
```

In the private window, as `klaudiomarashi`, open the repository, select **Watch** > **Custom**, tick **Issues** and select **Apply**. That account then gets a notification when the drift issue opens and when a comment is added to it. A change that only updates the run link inside the issue sends no notification.

### The rulesets

Confirm the two rulesets that protect the repository. `protect-master` is what forces a pull request into `master`.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/rulesets --jq ".[].name"
```

The names `protect-master` and `protect-tags` mean the rulesets of GUIDE.md steps 3.7 and 3.9 exist.

A ruleset that requires a pull request refuses a direct push to `master`. Step 2 says what to do then. An empty output (`[]` without the `--jq` filter) means the repository has no ruleset, so a pull request merges without the six checks and without the second account's approval. The GitHub environments would still ask for an approval. To show both, create the rulesets with GUIDE.md steps 3.7 and 3.9 after step 2 and before step 4.

## Part 1. The opening

> Let me show you how we manage Azure through code. We describe the resources in Bicep and keep that code aligned with what's live, so it acts as the source of truth for the production environment. When we change a resource through the pipeline, the proposed code has to go through a reviewed pull request first. Someone can still make a direct change in Azure, and later we'll see how the drift check finds it.
>
> Today we're using my test tenant and a deliberately small estate of seven units. Each unit is an independently deployed part of that estate, such as a resource group, a subscription's settings, or a management group. Although the estate is small, it uses the same workflows, scripts, and checks as production.
>
> Four workflows carry out the process. `mirror-validate` checks the code on every push without calling Azure, while `mirror-pr` previews each pull request against live Azure without changing anything. When we're ready to deploy, `mirror-deploy-unit` runs only after one person starts it and a second person approves that exact plan. Finally, `mirror-drift` checks whether live Azure still matches the code. In production, that check runs every week.
>
> I'll use two accounts today. `themasterishome` writes the changes and starts each run, while `klaudiomarashi` reviews pull requests and approves deployments in a private browser window. GitHub's Prevent self-review setting stops the person who started a deployment from approving it, so two different people have to agree. That's the four-eyes rule.

> In production, the same process runs on GitHub Enterprise Cloud in IT's private repository. It covers about sixty-five units across ten subscriptions and the tenant, with teams as reviewers and a smaller team approving changes that affect access.

## Part 2. What was set up before, and one example of each

> Before the pipeline can run, we need three pieces in place: GitHub environments, managed identities in Azure, and federated credentials that connect each environment to an identity. Setting up the whole system takes time, so I did that before today. I'll build one example of each now, explain how the pieces fit together, and then remove the example. The rest of the setup follows the same pattern.

### Show what is already there

List the GitHub environments. You will point at these names while you explain them.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/environments --jq ".environments[].name"
```

> Here are the five GitHub environments. Each one is a named place in the repository settings where a job runs, with its own variables and branch rules, and optionally its own reviewers. Deployment jobs use an environment to apply those rules and wait for approval.
>
> Two environments are for the reader identity, which only previews changes. `mirror-reader` handles pull request previews from any branch, while `mirror-reader-dispatch` is reserved for plans and drift checks from `master`. The other three are where deployments wait for approval. One handles ordinary resources, and the other two handle privileged units that change access.

List the managed identities in the locked resource group.

```powershell
az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

> These are the four managed identities used by the pipeline. Azure manages their credentials, so we don't have to store or rotate a password or client secret. The reader identity, `id-mirror-reader`, can only read and preview. The deploy identity, `id-mirror-deploy-demo`, writes ordinary resources, while the two govern identities can manage Owner-class role assignments and custom roles.
>
> When a job needs to sign in, GitHub gives it a short-lived token identifying the repository and environment it came from. The managed identity's federated credential tells Azure which tokens to trust, so the job can exchange a matching token for access without a stored secret.

> In production, this pattern scales to twenty-three GitHub environments and twenty-two managed identities. Each subscription has its own deploy identity and govern identity, and those identities live in a locked resource group in the platform subscription.

### One example, made and removed

> Let's build one example from scratch. I'll create a GitHub environment, a managed identity with a narrowly scoped role, and a federated credential that connects them. Once we've seen how they work together, I'll remove everything we created.

**Only if** an earlier run of this part stopped midway, run these two commands first, in the window you use for this part, so the names are free. They remove the environment and the whole example group, and the group takes the identity, its credential and its role assignment with it. `az group delete` takes a few minutes. Ignore a message that the environment or the group is not found. Otherwise skip to the quoted paragraph that starts with "Let's start by setting the branch policy".

> I'll remove the example environment, in case it is still there.

```powershell
gh api --method DELETE repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example
```

> And the example group, which takes the identity, its credential and its role assignment with it.

```powershell
az group delete --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --yes
```


> Let's start by setting the branch policy. We want this environment to use its own list of allowed branches, rather than GitHub's protected-branch setting. We'll attach the policy in the next step.

```powershell
$branchPolicy = @{ protected_branches = $false; custom_branch_policies = $true }
```

> With the policy ready, I'll create the GitHub environment `mirror-example` and attach it.

```powershell
@{ deployment_branch_policy = $branchPolicy } | ConvertTo-Json -Depth 4 | gh api --method PUT repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example --input -
```

> Now I'll add the branch rule: only runs from `master` may use `mirror-example`.

```powershell
gh api --method POST repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example/deployment-branch-policies -f name=master -f type=branch
```

> The environment is ready, and only a run from `master` can use it. That means a copy of the workflow on another branch cannot enter the environment or use the managed identity attached to it.

> In production, each deployment environment also requires approval from the approvers team, with Prevent self-review enabled. The reader environments don't need reviewers because their previews make no changes.

> Next, the identity needs a home. I'll create a resource group just for this example, so the cleanup cannot affect anything else.

```powershell
az group create --name rg-demo-example --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-example -o table
```

> Now let's create the managed identity, `id-mirror-example`. I'll keep its returned details in `$example`: the client ID identifies it for sign-in, and the principal ID is the one we'll use for its role assignment.

```powershell
$example = az identity create --name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth -o json | Out-String | ConvertFrom-Json
```

> Now let's pick out the name, client ID, and principal ID. That gives us a quick look at what we created and shows which identifier we'll use for sign-in and for the role assignment.

```powershell
$example | Select-Object name, clientId, principalId
```

> Great, now we have our managed identity. On its own, it has no permissions to access Azure resources, so we'll give it a role at the scope it needs. In this example, that scope is the `rg-demo-example` resource group we just created. The role assignment determines what the identity can access. The federated credential sets the trusted sign-in path, so Azure knows which GitHub workload can use the identity. We'll create that in a moment.

> Let's give it one permission for this example: the built-in Reader role, scoped only to this resource group. The GUID here is Reader's role definition ID.

```powershell
az role assignment create --assignee-object-id $example.principalId --assignee-principal-type ServicePrincipal --role acdd72a7-3385-48ef-bd42-f606fba81ae7 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o table
```

If it answers `PrincipalNotFound`, the new identity is not in the directory yet. Wait a minute and run the same command again.

> That GUID identifies the built-in Reader role, which grants read access at the scope we chose. Notice that the role is separate from the reader identity we saw earlier. Each pipeline identity gets only the roles its job needs, and only at the scopes where it needs them. The real reader identity has Reader and a small custom role for previews, while the deploy identity has Contributor and a few narrower roles that let it manage ordinary role assignments. Only the govern identities can create the Owner-class assignments.

> Before we create the trust, we need the repository's numeric ID. I'll save it in `$repoId`. The federated credential's subject uses it to bind trust to this specific repository, not just its name.

```powershell
$repoId = gh api repos/themasterishome/demo-bicep-deploy-test --jq .id
```

> Now let's connect GitHub to the identity. The federated credential names the repository and the `mirror-example` environment in its subject, and identifies GitHub as the token issuer. Azure will trust a token from this environment only when its claims match that configuration.

```powershell
az identity federated-credential create --name github-mirror-example --identity-name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --issuer https://token.actions.githubusercontent.com --subject "repo:themasterishome@49098959/demo-bicep-deploy-test@${repoId}:environment:mirror-example" --audiences api://AzureADTokenExchange -o table
```

> Take a look at the subject. It identifies the owner and repository by their numbers, then names the GitHub environment. Those numbers matter because deleting and recreating a repository gives it a new ID, even if it has the same name. The new repository therefore cannot inherit this trust.

> In production, the subject names IT's organization and repository in the same form, and the issuer is the one the enterprise uses.

> The trust is in place. Next, I'll store the identity's client ID in the GitHub environment as `AZURE_CLIENT_ID`, so a job running there knows which identity to request.

```powershell
gh variable set AZURE_CLIENT_ID --env mirror-example --body $example.clientId --repo themasterishome/demo-bicep-deploy-test
```

> Let's check that the client ID is now listed in `mirror-example`.

```powershell
gh variable list --env mirror-example --repo themasterishome/demo-bicep-deploy-test
```

> The client ID isn't a secret, and it can't authenticate a job by itself. The job also needs a matching federated credential. With both pieces in place, a job from `master` running in this environment can sign in as the managed identity, then read only this resource group because that's the scope of its Reader role. The production setup repeats this pairing for each environment and identity.

> Now let's clean up the example in reverse order. First, I'll delete the GitHub environment. Its variable is removed with it.

```powershell
gh api --method DELETE repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example
```

> The environment is gone. Next, I'll remove the Reader role assignment using this identity's principal ID, so we target the right assignment.

```powershell
az role assignment delete --assignee $example.principalId --role acdd72a7-3385-48ef-bd42-f606fba81ae7 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

> With its role removed, we can delete the managed identity. Its federated credential goes with it.

```powershell
az identity delete --name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

> Finally, I'll delete the resource group we made for the example. This can take a few minutes.

```powershell
az group delete --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --yes
```

> Once the delete finishes, let's check that the group is gone. We expect this to print `false`.

```powershell
az group exists --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

> The federated credential was removed along with the managed identity. The production identities are protected by a delete lock named `mirror-identities-no-delete`. If one ever needs to be removed, we first take off the lock, delete each item by its ID, and then put the lock back.

## Part 3. The demo

### 1. Sign in and start from `master`

> I'll start from a clean copy of the code, on `master`. That is the branch production deploys from.
>
> First, I'll point Azure CLI at the demo subscription. That way, the Azure commands that follow use the right subscription.

```powershell
az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

> Next, I'll switch GitHub CLI to `themasterishome`, the account that will write the code and start the runs.

```powershell
gh auth switch --hostname github.com --user themasterishome
```

> Let's make sure we're on `master`, the branch we'll use for the demo.

```powershell
git switch master
```

> Before we go further, let's check for uncommitted changes. If the folder is clean, this prints nothing.

```powershell
git status --short
```

> And let's look at the latest three commits, with the newest one at the top.

```powershell
git log --oneline -3
```

`git status` prints nothing. A failed `git switch master` prints its reason.

### 2. Turn every unit off and push the folder (GUIDE.md steps 3.5 and 3.20)

> Before we do anything else, let's make sure nothing deploys by accident. Each unit has an enabled flag in `deploy/units.json`, and a unit is included only after that flag is turned on in a reviewed change. Enabling a unit is a deliberate decision, so we'll start this demo with every unit turned off.
>
> I'll set every enabled flag in the file to `false`.

```powershell
(Get-Content deploy\units.json -Raw) -replace '"enabled": true', '"enabled": false' | Set-Content deploy\units.json -NoNewline
```

> Let's verify the edit before we commit it. We should see seven enabled flags, all set to `false`.

```powershell
Select-String -Path deploy\units.json -Pattern '"enabled"'
```

> All seven lines say `false`, so every unit is off and nothing can deploy by accident. I'll stage that one file so it's ready to commit.

```powershell
git add deploy/units.json
```

> Now I'll commit it with a message that says exactly what the change is, so anyone reading the history later knows why every unit was turned off.

```powershell
git commit -m "Disable every unit for the next demo"
```

> Next, I'll push this commit straight to `master` in the test repository. I can do that here because this is a free test repository, and I've left direct pushes to `master` open so the demo stays short. In our Enterprise repository that isn't possible. A ruleset protects `master` there, so the same commit would go to a branch first and come in through a pull request with a review. The push is still safe, because the pipeline switch is off. The switch is the repository variable `MIRROR_PIPELINE_ENABLED`, and while it's set to `false`, every job in every workflow skips.

```powershell
git push test HEAD:master
```

> The push prints the commit range it sent. If we look at the **Actions** tab on GitHub, there's a new `mirror-validate` run, because that workflow starts on every push to `master`. All of its jobs show as skipped, which tells us the switch is doing its job. We also don't see a `mirror-deploy-unit` run, and we never will after a push, because that workflow starts only when someone selects **Run workflow**.
>
> In the Enterprise repository, this same change would go to a branch first and then into `master` through a pull request. This is the command I would have used there. I'm not running it, because this commit is already on `master` in the test repository.

```powershell
git push origin HEAD:refs/heads/sync-demo
```

> If a push like this is ever refused, GitHub says why. When the message names the token scope, this command gives the token the workflow scope it needs. I'm not running it now, because the push went through.

```powershell
gh auth refresh -h github.com -s workflow
```

> When the message names the account, these two commands put the right account back for git. Again, the push worked, so I don't need them today.

```powershell
gh auth switch --hostname github.com --user themasterishome
```

```powershell
gh auth setup-git
```

### 3. Turn the pipeline switch on (GUIDE.md step 3.20)

> Now that every unit is off, I can turn the pipeline itself on. Every workflow reads the repository variable `MIRROR_PIPELINE_ENABLED` before any job runs, and only the value `true` lets the jobs go ahead. I call it the pipeline switch, because it gives us one place to pause the whole pipeline if something ever looks wrong.
>
> I'll set it to `true` now.

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

> Let's read the repository variables back, so we can see the value GitHub actually stored rather than trust the command.

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

> `MIRROR_PIPELINE_ENABLED` now shows `true`. Setting a variable doesn't start a run by itself, so nothing has happened yet. In the browser, you'd find the same variable under **Settings** > **Secrets and variables** > **Actions** > **Variables**. If the command is ever refused, the active account isn't `themasterishome`, and switching it as we did at the start fixes that.
>
> In the Enterprise repository, IT sets this same variable, but only once the GitHub environments, the managed identities and their variables are all in place and checked.

### 4. The first validate run (GUIDE.md step 3.21)

> With the switch on, the first thing I want to show you is the set of offline checks, the ones that run without ever signing in to Azure. To do that, I'll open a pull request that touches no deployment unit, so there's nothing for Azure to preview and we only see the offline checks.
>
> I'll start by creating a branch called `first-checks` and switching to it.

```powershell
git switch --create first-checks
```

> A pull request needs a change, and I want one that can't affect any deployment, so I'll add a blank line to `README.md`.

```powershell
Add-Content -Path README.md -Value ''
```

> That's the whole change. I'll commit it.

```powershell
git commit --all --message "First run of the checks"
```

> Now I'll push the branch to the test repository and set it to track the remote, so later pushes from it are simpler.

```powershell
git push -u test first-checks
```

> With the branch on GitHub, I'll open a pull request from it into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head first-checks --title "First run of the checks" --body "First run of the checks"
```

> Let's open that pull request in the browser. The checks are listed at the bottom of the **Conversation** tab.
>
> Five of them come from `mirror-validate`, and they run on every push and every pull request without touching Azure. `secret-scan` looks for passwords and keys that shouldn't be in the code, and `actionlint` checks that the workflow files themselves are valid. `workflow-hygiene` checks the pipeline's own rules and runs their tests, `preflight` compiles every unit and checks how the code is laid out, and `portability` makes sure the scripts behave the same on Windows and Linux. Because all of this happens before any sign-in, a mistake gets caught here instead of halfway through a deployment.
>
> Alongside them, `mirror-pr` works out which units the change touches. This pull request touches none, so there's no what-if to run, and `pr-gate` passes straight away.
>
> After a few minutes, all five checks turn green. `mirror-pr` shows only its `plan` job and a green `pr-gate`, with no `whatif` job, which is exactly what we expect for a change that touches no unit. The ruleset `protect-master` requires those five checks plus `pr-gate`, six in all, before anything can merge. If one of them ever fails, we open it and read the first error, and section 5 of the guide in this repository lists the usual causes.
>
> I don't want to merge this, because it was only there to show the checks. I'll close the pull request and go back to `master`, but I'll keep the branch, because the next step uses it to test the environment rule.

```powershell
gh pr close first-checks --repo themasterishome/demo-bicep-deploy-test
```

> And now back to `master`.

```powershell
git switch master
```

### 5. The first drift run (GUIDE.md step 3.22)

> The next thing to prove is that GitHub can sign in to Azure as our reader identity, and that the drift workflow can raise a problem as an issue in the repository. Right now every unit is off, so the drift check has nothing to inspect. That's actually useful here, because the check stops on purpose, and we get to see how the workflow reports it.
>
> I'll start `mirror-drift` from `master`.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

> Once the run ends, let's open it from **Actions** > **mirror-drift**. The `azure/login` step is green, so the sign-in worked. The next step, `Drift sweep (read-only)`, fails, and its last line starts with `STOP: no enabled unit to check in deploy/units.json`, which is the stop we expected. The `report` job then prints `Drift report: issue #N is opened (error).`, and the **Issues** tab now holds that issue.
>
> Two things happened there that matter. The sign-in needed no password, because GitHub presented a token that matched the federated credential on the identity. And the failure didn't just sit in a run log that nobody reads. It opened an issue, which notifies everyone who watches the repository.
>
> Since every unit is disabled, no later run can come back clean and close that issue for us, so I'll close it by hand. First, let's list the open issues to get its number.

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

> I'll close it now, using the number from that list.

```powershell
gh issue close ISSUE_NUMBER --repo themasterishome/demo-bicep-deploy-test
```

> Now let's test the branch rule on the environments. I'll start the same drift check, but from `first-checks` instead of `master`. GitHub should refuse to let it into the environment before any job runs, because only `master` is allowed there.

```powershell
gh workflow run mirror-drift.yml --ref first-checks --repo themasterishome/demo-bicep-deploy-test
```

> I'll give GitHub about 30 seconds, then list the three newest drift runs. The newest one should show `failure`.

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

> It failed before any step started, with `Branch "first-checks" is not allowed to deploy to mirror-reader-dispatch due to environment protection rules`, and the `report` job was skipped. That's the protection we wanted. Someone could copy a workflow onto another branch, but it still can't use this environment, and every deployment environment has the same rule.
>
> That branch has done its job, so I'll remove it from the test repository.

```powershell
git push test --delete first-checks
```

> And I'll remove the local copy as well.

```powershell
git branch --delete --force first-checks
```

> If the sign-in ever fails with `AADSTS70021`, the federated credential's subject doesn't match, or the credential is only a minute old, so we wait a few minutes and run it again. If the `report` job fails, Issues are turned off in the repository settings. If it says `is updated` rather than `is opened`, an older drift issue was still open. And if a run from another branch ever does sign in, that environment is missing its branch rule.

### 6. A pull request and its preview (GUIDE.md section 4.2, items 1 and 2)

> Now we can move on to a real change. Every change takes the same path, a branch, an edit and a pull request, and I'll start with the pilot unit. It deploys an empty template into an empty resource group, so it proves that the sign-in, the permissions, the approval and the evidence all work together without creating a single resource.
>
> The demo's resource groups were created by hand before we started. Before any preview runs against them, I'll make sure `rg-demo-pilot`, `rg-demo-network` and `rg-demo-routing` all exist. This is safe to run again, because a group that exists already is left as it is.

```powershell
foreach ($g in 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') { az group create --name $g --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy --query properties.provisioningState -o tsv }
```

> We get `Succeeded` three times, so all three groups are there. In production, the pilot's resource group is created by hand under the pilot's change ticket, because the pipeline cannot create the group its own proof runs against, and it needs no tags. Every other group exists already, because the code mirrors what's live.
>
> I'll create a branch called `enable-pilot` for this change and switch to it.

```powershell
git switch --create enable-pilot
```

> Now I'll set `"enabled": true` in the entry of `pilot-empty-rg`. I change this one flag on purpose, so the pull request shows exactly which unit we're turning on.

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "pilot-empty-rg".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

> Let's check the edit before we commit it. Git should list only `deploy/units.json`, with one line changed.

```powershell
git diff --stat
```

`git diff --stat` shows `deploy/units.json` with `1 insertion(+), 1 deletion(-)`. If you open the file in the editor instead, set the same flag and run this check before you commit.

> One flag in one file. Now I'll commit it.

```powershell
git commit --all --message "Enable the pilot unit"
```

> I'll push the branch to the test repository.

```powershell
git push -u test enable-pilot
```

> And open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-pilot --title "Enable the pilot unit" --body "Enable the pilot unit"
```

> On the pull request, `mirror-pr` now has a job called `whatif pilot-empty-rg`, and its comment shows the gate PASS with no records, because an empty template changes nothing.
>
> This is the part reviewers usually find most useful. Before anyone can merge, the pipeline runs a what-if against live Azure, which shows what the deployment would do without changing anything. It runs as the reader identity, which has no write access at all. The gate then reads every record, and it stops the run if the plan holds a create, a change or a delete that nobody has named. So the reviewer sees what would really happen in Azure, not just a diff of the code.
>
> If that `whatif` job ever fails with `ResourceGroupNotFound`, the group `rg-demo-pilot` is missing, and the first command of this step creates it again.

### 7. Approve and merge, and see that the merge starts nothing (GUIDE.md section 4.2, items 3 and 4)

> The change needs a second person's review, so I'll switch to the private window, where I'm signed in as `klaudiomarashi`. I'll open the pull request, select **Files changed**, then **Review changes**, **Approve** and **Submit review**.
>
> Here the second account stands in for the reviewer. In our Enterprise repository, the approval has to come from a member of the approvers team, because the CODEOWNERS file names that team, and the repository's ruleset on `master` asks for a code owner's review before any merge. With the approval in place, and once the checks at the bottom of the pull request are green, I'll squash-merge the pull request and delete its branch.

```powershell
gh pr merge enable-pilot --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> The merge happened on GitHub, so my local copy is behind. I'll switch back to `master`.

```powershell
git switch master
```

> And pull the merged commit down from the test repository.

```powershell
git pull test master
```

> Now for something that surprises people. Let's look at the recent deployment runs on `master` and see whether the merge started one.

```powershell
gh run list --workflow mirror-deploy-unit.yml --branch master --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

> There's no new `mirror-deploy-unit` run, and that's on purpose. The merge changed the code on `master`, but it deployed nothing. A deployment needs its own change ticket, its own reason and its own reviewer for that one run, and a merge carries none of those. So a deployment is always a separate step that someone starts with **Run workflow**.
>
> The merge did start the checks on `master`, though, just as it would in production, and we wait for them to go green before anyone starts a deployment. If GitHub ever refuses a merge, a required check is still running or the branch is out of date. We wait for the checks and run the command again, or select **Update branch**.

### 8. A plan only (GUIDE.md section 4.2, item 11)

> Before we deploy anything, I want to see the plan on its own. I'll start `mirror-deploy-unit` for `pilot-empty-rg` with `apply` left off, so it only runs the what-if. I'll give it the ticket `DEMO-0003` and a reason that says it's a plan only, because every run records both.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot, plan only" --repo themasterishome/demo-bicep-deploy-test
```

> Let's open the run called "Deploy pilot-empty-rg (DEMO-0003)". Three jobs run, `select`, `plan pilot-empty-rg` and `collect`. The summary shows "Gate PASS, approvable" and ends with "This run was started as a plan only (apply is off). Nothing waits for a reviewer."
>
> Each job has a clear role. `select` checks the inputs, `plan` runs the what-if as the reader identity, and `collect` sorts the result into the right tier. Because `apply` was off, nothing waits for an approval and nothing is deployed, but the ticket and the reason are kept with the run, so we can always see later why it was started.
>
> You can start the same run from the browser too, with **Actions** > **mirror-deploy-unit** > **Run workflow**, keeping `master` and leaving `apply` unticked. If a run ever fails in `select`, it names the input it refused, for example a unit whose enabled flag is still `false`.

### 9. Deploy the pilot, with an approval (GUIDE.md section 4.2, items 5 to 9)

> The plan looks right, so now I'll start the same unit again with `apply` set to `true`, keeping the ticket `DEMO-0003`. This time the run can deploy, but only after a reviewer approves it.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

> Let's open the run in my own window. After `plan pilot-empty-rg` and `collect`, the job `apply pilot-empty-rg` shows **Waiting** for the GitHub environment `mirror-production-demo`. The deployment is paused until a reviewer approves it, and because I started the run, GitHub won't let me be that reviewer. That's Prevent self-review at work. The reviewer looks at the plan attached to this run, compares it with the plan-only run we just saw, and approves with a comment that names the ticket.
>
> You'll also see a button called **Start all waiting jobs**. That's the administrator bypass, and it would let the person who started the run approve it, so I won't touch it. In production, the bypass stays on as the break-glass route for an emergency, but only the two or three organization owners hold Admin on the repository. An approval and a bypass both land in the environment's deployment record, and the owners read those records every month.
>
> Now I'll go to the private window as `klaudiomarashi`, open the same run, select **Review deployments**, tick `mirror-production-demo`, write a comment that names `DEMO-0003` and select **Approve and deploy**. It has to be the newest run, because an old or finished one has nothing left to approve.
>
> The approval is in, so let's follow the run to the end. First, I'll list the newest run to get its ID.

```powershell
gh run list --workflow mirror-deploy-unit.yml --limit 1 --repo themasterishome/demo-bicep-deploy-test
```

> I'll use the long number from the `ID` column, which is also the number after `/actions/runs/` in the run's address. The `#N` in the title is a different number, so I don't use that one. Now let's watch the run until it finishes.

```powershell
gh run watch RUN_ID --repo themasterishome/demo-bicep-deploy-test
```

> The summary ends with `Gate step exit: 0, deployed, and the second check passed.`, and the run keeps two artifacts, `reviewed-plan-pilot-empty-rg` and `evidence-deploy-pilot-empty-rg`.
>
> A lot happened after the approval, so let me walk through it. The apply job first checked that `master` hadn't moved and that the plan was less than a day old. It then signed in as the deploy identity, took a fresh what-if and compared it with the plan the reviewer approved. That's the first check, and the deployment only goes ahead when the two match. After deploying, it took one more what-if to confirm that nothing is left to change, which is the second check. If either check had found a difference, the job would have stopped.
>
> In production, the reviewer is anyone in the approvers team except the person who started the run, and the comment names IT's change ticket. If `master` moves or the plan gets older than a day while an apply waits, we reject that run at once and start a new one, because the apply refuses the old plan after the approval anyway. If an apply ever runs straight through with no pause, the GitHub environment has no required reviewer, and that has to be fixed before anything else deploys.

### 10. Download the evidence (GUIDE.md section 4.2, item 10)

> Every deployment leaves evidence behind, and in production we attach it to the change ticket. Let's look at what this one left.
>
> I'll list the artifacts of the same run, using the same run ID. Each line shows an artifact's ID and name, and the one we want is `evidence-deploy-pilot-empty-rg`.

```powershell
gh api "repos/themasterishome/demo-bicep-deploy-test/actions/runs/RUN_ID/artifacts" --jq ".artifacts[] | [.id, .name] | @tsv"
```

> I'll use that artifact's ID and name in the next few commands. First, a folder to download it into.

```powershell
New-Item -ItemType Directory -Force C:\demo-setup\evidence-pilot | Out-Null
```

> `gh run download` unpacks these artifacts with a current GitHub CLI. An older one failed on them, because the zip holds the same entry twice, so I'll show the route through the API that works with any version. Wrapping it in `cmd /c` stops Windows PowerShell 5.1 from changing the bytes on the way to the file.

```powershell
cmd /c "gh api repos/themasterishome/demo-bicep-deploy-test/actions/artifacts/ARTIFACT_ID/zip > C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip"
```

> Now I'll unpack the zip with Python into a folder named after the artifact.

```powershell
python -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip C:\demo-setup\evidence-pilot\ARTIFACT_NAME
```

> Out of everything in there, two files tell the story, so let's find `approval.txt` and `post-summary.txt`.

```powershell
Get-ChildItem -Path C:\demo-setup\evidence-pilot -Recurse -Include approval.txt, post-summary.txt | Select-Object -ExpandProperty FullName
```

> `approval.txt` records who started the run, which options they chose, and in its `deployed=` line, whether it deployed. `post-summary.txt` holds the second check, and it says Gate PASS. Together they show what we planned, what the reviewer approved and what Azure ended up with, which is exactly what a change ticket needs.

### 11. Wave 1, the network (GUIDE.md section 4.3)

> A wave is simply the next unit in the deployment order. Wave 0 was the pilot, and wave 1 is the network, which is where we start creating real resources. The network unit creates a network security group, a virtual network, a private endpoint with its DNS, and the lock, the policy and the Reader assignment that go with them. I'll turn on the network and the routing units in one pull request, but routing still waits until the network wave is done.
>
> I'll create a branch for that change and switch to it.

```powershell
git switch --create enable-waves
```

> Now I'll set `"enabled": true` in the entries of `rg-demo-network` and `rg-demo-routing`. Both flags are part of the same decision, so they go into one commit.

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "rg-demo-network".*?"enabled": )false', '${1}true' -replace '(?s)("name": "rg-demo-routing".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

> Let's check the edit before we commit it. Git should list only `deploy/units.json`, with two lines changed.

```powershell
git diff --stat
```

`git diff --stat` shows `deploy/units.json` with `2 insertions(+), 2 deletions(-)`. If you open the file in the editor instead, set the two flags and run this check before you commit.

> Two flags in one file. Now I'll commit them together.

```powershell
git commit --all --message "Enable the network and routing units"
```

> I'll push the branch to the test repository.

```powershell
git push -u test enable-waves
```

> And open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-waves --title "Enable the network and routing units" --body "Enable the network and routing units"
```

> The preview comment on this pull request now lists real changes, so this is what the reviewer reads. I'll approve it as `klaudiomarashi` in the private window with the same clicks as before, wait until the checks are green, and then squash-merge it and delete the branch. As before, the merge puts the code on `master` and starts no deployment.

```powershell
gh pr merge enable-waves --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> I'll switch back to `master`.

```powershell
git switch master
```

> And pull the merged commit.

```powershell
git pull test master
```

> Now I'll ask for a plan of the network unit on its own, with the ticket `DEMO-0004`. Two of its resources have names that Bicep generates as GUIDs, and nobody should try to guess those, so I'll take every resource ID from the plan's summary instead.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

> Let's open that run. The plan is red, and that's expected. It would create nine resources, and the gate won't approve a create that nobody has named. Whoever starts the deployment has to list every new resource by its full resource ID in `allowCreate`, so the reviewer can check that list, and the run stops if the plan holds any create that isn't on it.
>
> The summary helps here, because it gives us a ready command with all nine resource IDs already filled in. I'll copy those IDs into `allowCreate`, and check the ticket `DEMO-0004` and the reason `Wave 1, create the network`. `apply` is on, so the run will wait for an approval before it deploys.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, create the network" -f apply=true -f allowCreate="ID1,ID2,ID3,ID4,ID5,ID6,ID7,ID8,ID9" --repo themasterishome/demo-bicep-deploy-test
```

> Nine is the count for an empty group. If the lock, the policy assignment or the role assignment had been live already, the ready command would list fewer. I'll approve the waiting apply in the private window, as before, with a comment that names `DEMO-0004`.
>
> The plan shows the verdict approvable with nine Create records. After the approval, the second check ends with `NoChange=8`, one `Ignore` and one `Modify`, and the summary ends with `Gate step exit: 0, deployed, and the second check passed.` The Ignore is the network interface Azure creates for the private endpoint by itself, and the Modify is a few fields the provider sets on the endpoint's zone group. Both are listed in `deploy/boundaries.json`, so the gate knows them and lets them pass.
>
> The second check is the honest one, because it runs a fresh what-if without the `allowCreate` list. A resource that wasn't created the way the code describes would fail right there. It passed, so apart from those two known records, the resources in Azure are exactly what the code says.
>
> If we open `rg-demo-network` in the portal, it now holds `nsg-demo` and `vnet-demo`, and the lock `lock-rg-demo-network` shows under **Locks**. The evidence downloads the same way as in step 10, this time from `evidence-deploy-rg-demo-network`. Had these resources existed already, the plan would have shown NoChange and passed with no `allowCreate`, and the apply would still have waited for the reviewer. A red plan with exit code 2 means a setup problem rather than a change.

### 12. Wave 2, the routing (GUIDE.md section 4.4)

> Routing was turned on in the same pull request, so there's nothing to merge this time. It runs second because it comes after the network in the deployment order. Besides the route table, this unit creates an Automation account with a credential, and the credential's password lives in Key Vault, so it never appears in the repository.
>
> The network wave has finished, so we can start routing the same way, with a plan first. I'll use the ticket `DEMO-0005`.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

> In an empty group, the plan is red with four Creates: `rt-demo`, `asg-demo`, the Automation account `aa-demo-secrets` and its credential `demo-cred`. The summary gives the exact command with all four resource IDs, so `allowCreate` names every resource in the plan and nothing else. `apply` is on, the ticket stays `DEMO-0005`, and the reason tells the reviewer that this run creates the routing.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, create the routing" -f apply=true -f allowCreate="/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/applicationSecurityGroups/asg-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets/credentials/demo-cred" --repo themasterishome/demo-bicep-deploy-test
```

> I'll approve the waiting apply in the private window with a comment that names `DEMO-0005`. Once it finishes, the second check shows `rt-demo`, `asg-demo`, `aa-demo-secrets` and `demo-cred` as NoChange. If the resources had existed already, the plan would have been green with no Create, and no `allowCreate` would have been needed.
>
> The interesting part is the password. When the deployment needed it, it read it straight from Key Vault, through `az.getSecret` in the parameters file. In the evidence, the value shows as `<secure input, not recorded>`, so the password never appears in a log or in a file in the repository. In production, the VPN shared keys work the same way. IT loads them into the vault once, and the code reads them at deployment. My own role on the vault is removed afterwards.
>
> Now I want to show what a finished unit looks like. I'll deploy the same commit a second time. The resources exist now, so the plan should hold no Creates and need no `allowCreate`, and the reason says that this is the second deployment of the same commit.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, the second deployment of the same commit" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

> I'll approve it the same way. The plan, the first check and the second check all show `NoChange=4`, and the gate step exits 0. That's the proof we're after. When the same code is deployed again, Azure finds nothing to change, so the code and what's live are the same, and that's the state we want every production unit to reach.
>
> Two inputs of the form stay empty for the whole demo. In production, `allowHeld` lifts a hold, for example on the VPN gateways, and `acknowledgeReview` is ticked when the reviewer accepts the plan's review items. A unit with review items takes two rounds. The first plan, with the box off, is not approvable and lists each item. After the items are checked, a new run with the box ticked is the one that gets approved. This demo has no holds and no review items, so we never need them here.
>
> If a deployment like this ever fails on the vault, the deploy identity is missing the role Mirror Key Vault Deployment on that vault.

### 13. Wave 4, the privileged unit (GUIDE.md section 4.5)

> You might notice we're jumping from wave 2 to wave 4. Wave 3 is `demo-subscription`, and it stays off on purpose, because this subscription also holds resource groups that have nothing to do with the demo. In production, the subscription units, the budgets among them, deploy exactly like the resource group units we've just seen.
>
> Wave 4 is about access. Some resources decide who can do what, like Owner role assignments and custom roles, and we keep those in a privileged unit with its own managed identity and its own GitHub environment. If the ordinary deploy identity could create resources and grant access at the same time, it could in effect make itself an Owner. That's why it can't grant Owner, and why access changes go down a separate, tighter path.
>
> I'll create a branch called `enable-privileged` and switch to it.

```powershell
git switch --create enable-privileged
```

> Now I'll set `"enabled": true` in the entry of `demo-privileged`.

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "demo-privileged".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

> Let's check the edit before we commit it. Git should list only `deploy/units.json`, with one line changed.

```powershell
git diff --stat
```

`git diff --stat` shows `deploy/units.json` with `1 insertion(+), 1 deletion(-)`. If you open the file in the editor instead, set the same flag and run this check before you commit.

> Now I'll commit that flag.

```powershell
git commit --all --message "Enable the privileged unit"
```

> I'll push the branch to the test repository.

```powershell
git push -u test enable-privileged
```

> And open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-privileged --title "Enable the privileged unit" --body "Enable the privileged unit"
```

> I'll approve it as `klaudiomarashi` in the private window, wait until the checks are green, then squash-merge it and delete the branch. Just like before, the code reaches `master` and no deployment starts.

```powershell
gh pr merge enable-privileged --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> Back to `master`.

```powershell
git switch master
```

> And I'll pull the merged commit.

```powershell
git pull test master
```

> As always, the plan comes first, with the ticket `DEMO-0006`. Its summary will give us the two resource IDs the deployment needs.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

> The plan's ready command lists two IDs, the Owner role assignment on `rg-demo-network` and the role definition `Demo Reader Plus`. I'll copy both into `allowCreate`, with the ticket `DEMO-0006`, the reason `Wave 4, the privileged unit`, and `apply` on.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, the privileged unit" -f apply=true -f allowCreate="ID1,ID2" --repo themasterishome/demo-bicep-deploy-test
```

> Look at the job that's waiting this time. It's called `apply privileged demo-privileged`, not `apply demo-privileged`, and it waits in a different GitHub environment, `mirror-privileged-demo`. It will deploy as the govern identity `id-mirror-govern-demo`. Nobody chose that environment when starting the run. The unit's tier chose it. Before approving, the reviewer checks that every role assignment is named, and that nobody gets Owner beyond what the ticket allows.
>
> Here, the same second account approves both tiers, because a personal account can't join the approver teams. In production, only a smaller team can approve the privileged environments, because that team answers for access changes. We also prove the privileged tier first with a plan only, so the very first privileged run ends at the plan, with every count NoChange.
>
> I'll approve it in `mirror-privileged-demo` as `klaudiomarashi`, with a comment that names `DEMO-0006`, and the second check ends with `NoChange=2`. There's a second half to this rule as well. A production unit that declares an Owner assignment fails the `preflight` job of `mirror-validate`, so that code is refused before anyone could deploy it from the ordinary tier.

### 14. Wave 5, the management group (GUIDE.md section 4.6)

> Not everything lives inside a subscription. Management groups sit above the subscriptions, so their units deploy at the tenant level, with their own managed identity.
>
> I'll create a branch called `enable-tenant-mg` for the management group unit.

```powershell
git switch --create enable-tenant-mg
```

> Now I'll set `"enabled": true` in the entry of `demo-tenant-management-group`.

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "demo-tenant-management-group".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

> Let's check the edit before we commit it. Git should list only `deploy/units.json`, with one line changed.

```powershell
git diff --stat
```

`git diff --stat` shows `deploy/units.json` with `1 insertion(+), 1 deletion(-)`. If you open the file in the editor instead, set the same flag and run this check before you commit.

> Now I'll commit it.

```powershell
git commit --all --message "Enable the management group unit"
```

> I'll push the branch to the test repository.

```powershell
git push -u test enable-tenant-mg
```

> And open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-mg --title "Enable the management group unit" --body "Enable the management group unit"
```

> I'll approve it as `klaudiomarashi`, wait until the checks are green, then squash-merge it and delete the branch. Again, the merge on its own deploys nothing.

```powershell
gh pr merge enable-tenant-mg --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> Back to `master`.

```powershell
git switch master
```

> And I'll pull the merged commit.

```powershell
git pull test master
```

> This unit is a little different. We created `mg-demo` by hand before the demo, because Azure can't run a what-if against a management group that doesn't exist yet. So this unit only updates a group that's already there, and the pull request's preview showed no Creates. That means we can go straight to the deployment, without a plan-only run and without an `allowCreate` list, using the ticket `DEMO-0007`.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-management-group -f changeRef=DEMO-0007 -f reason="Wave 5, the management group" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

> The job that waits is `apply privileged demo-tenant-management-group`, in the GitHub environment `mirror-privileged-tenant`. I'll approve it as `klaudiomarashi` with a comment that names `DEMO-0007`. The apply signs in as `id-mirror-govern-tenant`, and the second check passes with `NoChange=1`.
>
> In production, there are three tenant units. Two of them deploy against the Tenant Root Group, one for the management groups and one for their role assignments, and the third deploys against the management group below it. They go through exactly this path, with the tenant govern identity, and only after the privileged team approves them.
>
> If a tenant unit ever fails with `AuthorizationFailed`, the reader identity is missing Reader, or Mirror What-If Reader Tenant, on the Tenant Root Group.

### 15. Wave 6, the Reader role assignment on the management group (GUIDE.md section 4.7)

> The last unit gives the reader identity the Reader role on the management group. It has its own pull request, so each tenant unit gets its own preview and its own approval.
>
> I'll create a branch called `enable-tenant-governance` and switch to it.

```powershell
git switch --create enable-tenant-governance
```

> Now I'll set `"enabled": true` in the entry of `demo-tenant-governance`.

```powershell
(Get-Content deploy\units.json -Raw) -replace '(?s)("name": "demo-tenant-governance".*?"enabled": )false', '${1}true' | Set-Content deploy\units.json -NoNewline
```

> Let's check the edit before we commit it. Git should list only `deploy/units.json`, with one line changed.

```powershell
git diff --stat
```

`git diff --stat` shows `deploy/units.json` with `1 insertion(+), 1 deletion(-)`. If you open the file in the editor instead, set the same flag and run this check before you commit.

> Now I'll commit it.

```powershell
git commit --all --message "Enable the management group governance unit"
```

> I'll push the branch to the test repository.

```powershell
git push -u test enable-tenant-governance
```

> And open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-governance --title "Enable the management group governance unit" --body "Enable the management group governance unit"
```

> I'll approve it as `klaudiomarashi`, wait until the checks are green, then squash-merge it and delete the branch.

```powershell
gh pr merge enable-tenant-governance --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> Back to `master` for the deployment.

```powershell
git switch master
```

> And one last pull of the merged commit.

```powershell
git pull test master
```

> This unit creates something new, so the plan comes first, with the ticket `DEMO-0008`, and its summary will give us the resource ID of the Reader role assignment. The plan needs `mg-demo` to exist, and it does, because we created it by hand before the demo. Step 14 came first only to keep the same order as production.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

> The ready command lists the ID of the Reader role assignment on `mg-demo`. I'll copy that ID into `allowCreate`, with the ticket `DEMO-0008`, the reason `Wave 6, Reader on the management group`, and `apply` on.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, Reader on the management group" -f apply=true -f allowCreate=ID --repo themasterishome/demo-bicep-deploy-test
```

> The job `apply privileged demo-tenant-governance` waits in `mirror-privileged-tenant`, and I'll approve it as `klaudiomarashi` with a comment that names `DEMO-0008`. The plan held one Create, and the second check passes with `NoChange=1`. That's every unit deployed.

### 16. The drift check and the drift issue (GUIDE.md section 4.9)

> Everything we've deployed now matches the code, but that only stays true until someone changes something in the portal. When that happens, live Azure and the code drift apart. The drift check catches it by running a read-only what-if for every enabled unit, and it keeps one GitHub issue up to date with what it finds.
>
> I'll let each run finish before starting the next one, because if a new drift run starts while another is still waiting, GitHub replaces the waiting one. Let's look at the recent drift runs first, since this list is how we'll follow each run in this part.

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

> I'll start with a clean baseline, running `mirror-drift` from `master` while everything still matches the code.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

> The run is green, and the `report` job prints `Drift report: every checked unit is clean, and no drift issue is open.`, so we have our clean starting point.
>
> Now I'll do what people really do, a quick change straight in the portal. I'll search for **Route tables**, select `rt-demo`, select **Tags**, add the name `changedBy` with the value `portal` and select **Apply**. The change works, but the code doesn't know about it.
>
> Let's run the drift check again and see whether it notices.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

> This time the run is red. `rg-demo-routing` shows as `DRIFT`, with a Modify on `rt-demo` that would remove the tag `changedBy`, and the `report` job prints `Drift report: issue #N is opened (drift).` Let's open the **Issues** tab, where the issue names `rg-demo-routing` and links straight to the run.
>
> Notice that the drift check changed nothing in Azure. It only reports, and the issue is the alert. Everyone watching the repository is notified when it opens, and the issue tells them which unit drifted and where the evidence is.
>
> Nothing else has changed, so let's run the check once more and see how the workflow handles the same finding coming back.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

> The `report` job prints `Drift report: issue #N is updated with this run, and its findings are the same (drift).`, and it adds no new comment. Since the findings are the same, it only updates the link to the latest run, so people don't get the same alert every week.
>
> Here I'll repair the drift by deploying the value the code already holds. `rt-demo` exists, so this is a change rather than a create, and the gate needs it named in `allowModify`. I'll use the ticket `DEMO-0010` with `apply` on.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0010 -f reason="Undo the drift on rt-demo" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo --repo themasterishome/demo-bicep-deploy-test
```

> I'll approve it as `klaudiomarashi` and let it finish. It's still an ordinary deployment, with a ticket and an approval like any other. If the portal change had been the right one, we wouldn't deploy over it. We'd bring it into the code through a pull request instead.
>
> In production, IT makes that call for each finding. We first find out who changed the resource and when, through Change Analysis or the activity log, so a change made in the portal is never quietly reversed.
>
> The repair is done, so let's run the check one last time. This time we expect every unit to be clean and the issue to close.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

> The run is green, and the `report` job prints `Drift report: every checked unit is clean, so issue #N is closed.` The issue is closed with a comment, so once everything is back in line, the pipeline tidies up after itself.
>
> One unit stays out of the drift check on purpose. If `demo-subscription` were enabled, the run would list it as `DRIFT`, with NoRecord lines for the resource groups in this subscription that aren't part of the demo, and the summary would name each one. The second account also hears about the issue only when it watches the repository.

### 17. Turn on the weekly drift run

> Running the drift check by hand is fine for a demo, but it can also run by itself every Monday at 05:00 UTC. The schedule has its own switch, the repository variable `MIRROR_DRIFT_SCHEDULE_ENABLED`, because we only want it on once the team is ready to act on what it finds. It also needs at least one enabled unit, because, as step 5 showed, a run with every unit off fails on purpose.
>
> I'll turn the schedule on now.

```powershell
gh variable set MIRROR_DRIFT_SCHEDULE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

> Let's list the repository variables to confirm it.

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

> `MIRROR_DRIFT_SCHEDULE_ENABLED` shows `true`. From next Monday, the `mirror-drift` runs include one whose event is `schedule`. We won't wait for Monday, because **Run workflow** runs exactly the same two jobs. If a weekly run ever skips every job, either this variable isn't `true` or the pipeline switch is off.
>
> In production, IT leaves the schedule off until the team is ready for it, then turns it on with this same variable. When a scheduled run fails, GitHub notifies only the person who last edited the schedule, which is another reason we report drift through an issue that everyone watching can see. With Enterprise Managed Users, the schedule also stops if that person is removed from the identity provider, so a member of the approvers team makes the last change to the schedule. Changing the default branch makes that person the actor too.

### 18. A change after the baseline, and a rollback (optional, GUIDE.md sections 4.8 and 4.10)

> Once a unit matches what's live, every later change goes through the same pull request process we've used all along. And if a change turns out to be wrong, we roll it back the same way in reverse, by reverting it in Git, running a what-if, getting the approval and deploying the correction.
>
> For this part, I'll follow sections 4.8 and 4.10 of the guide, where the example adds a rule to `nsg-demo`. The guide's commands push to a remote called `origin`, and this repository's remote is called `test`, so that's the name I'll use. As always, merging each pull request starts no run, and the resource IDs for `allowModify` come from the preview's comment. After the rule is added, the second check ends with `NoChange=8`, one `Ignore` and one `Modify`, just as in wave 1, with `nsg-demo` among the NoChange records. After the rollback, `nsg-demo` is NoChange again.

## The closing

> So, to bring it all together. Every change starts as code and is reviewed in a pull request with a real what-if against Azure. A deployment starts only when someone asks for it, a second person approves that exact plan, and the check after the deployment has to pass. The pipeline signs in through federated credentials, so there are no stored secrets, and the identities that can write can only be used from `master`. Changes to access take the tighter, privileged path. And every week, the drift check compares live Azure with the code and tells us when they no longer match.

## Turning the demo off

> That's the end of the demo, so I'll put things back the way they were. First, I'll set the pipeline switch, `MIRROR_PIPELINE_ENABLED`, back to `false`, so every workflow job skips again.

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body false --repo themasterishome/demo-bicep-deploy-test
```

> Next, I'll delete the weekly drift switch. If it stayed `true`, the Monday schedule would start again the next time someone turned the pipeline on.

```powershell
gh variable delete MIRROR_DRIFT_SCHEDULE_ENABLED --repo themasterishome/demo-bicep-deploy-test
```

> Let's check that no drift issue is left open from the demo. If one shows up, I'll close it the same way as in step 5.

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

> I'll switch GitHub CLI back to `klaudiomarashi`, the reviewer account.

```powershell
gh auth switch --hostname github.com --user klaudiomarashi
```

> And finally, I'll point Azure CLI back to my usual subscription. The demo's resources stay in place until we remove them with section 6 of the guide.

```powershell
az account set --subscription SUBSCRIPTION_ID
```

## Reading a failed run

> If a deployment ever fails, this is how we read what happened. On GitHub, we open **Actions**, then **mirror-deploy-unit**, then the run, then its apply job. The gate step's log prints its exit code and the last lines of the deploy script. A 0 means it deployed and both checks passed, a 1 means the gate refused it, a 2 means a setup or identity problem, and a 3 means the deployment ran and failed, or its second check failed. If the step ends with `error` or `started` instead of a code, a deployment may already have begun, so we list the deployments of that scope before doing anything else. The job summary holds the plan's verdict, and the artifacts `evidence-deploy-UNIT` and `reviewed-plan-UNIT` hold the what-if results as JSON.
>
> In Azure, the deployment record is named `mirror-UNIT-COMMIT`. In the portal, it's under the subscription, the resource group, or for a tenant unit the management group, then **Deployments**, then the failed record, then **Operation details**, which names the resource and the error code. From the CLI, we read the same error with one of three commands, filling in the unit, the commit and the scope from the run.
>
> For a deployment at the subscription, we use this one.

```powershell
az deployment sub show --name mirror-UNIT-COMMIT --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.error
```

> For a deployment into a resource group, we use this one.

```powershell
az deployment group show --name mirror-UNIT-COMMIT --resource-group RESOURCE_GROUP --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.error
```

> And a tenant unit deploys against a management group, so its record is there, under the unit's `managementGroup` from `deploy/units.json`.

```powershell
az deployment mg show --name mirror-UNIT-COMMIT --management-group-id MANAGEMENT_GROUP_ID --query properties.error
```

> In production, PIPELINE.md section 7 maps each message to its cause and its fix, and REFERENCE.md section 4 is the rollback after an exit 3. For this demo, section 5 of the guide lists the causes we've seen.
>
> One failure is worth knowing about in advance. A deployment can fail in Azure with `ResourceNotFound` even though its plan showed NoChange, because a what-if never checks that the resource a setting points at still exists, for example the scale set named by an autoscale setting. When that happens, the other resources of the deployment keep their live values and nothing is deleted. A failed apply may have written part of the unit, so we stop there, start no other unit and keep the evidence of the run, and in production we read the rollback section before we change the code. The fix is in the code. The resource whose target is gone becomes an existing reference, and the unit is planned and deployed again at the new commit, while the Failed record stays in the deployment history. In production, we check before a unit's first deployment that every resource a setting points at still exists, so this is found before the run instead of during it. A resource created from a source that is gone, such as a disk made from a snapshot that was deleted, is not this case, because Azure accepts that write, so it stays declared.
>
> A retry is always a new run, at the commit that holds the fix, because re-running a failed run never deploys. For the drift check, we open the **Issues** tab and the run that the issue links to, and the `drift` artifact holds each unit's evidence.

## Removing a managed identity and its roles

> When a managed identity has to go, we remove it in a fixed order, and we delete each object by its ID, so a delete can't hit a different object that happens to share the name.
>
> 1. Take the delete lock `mirror-identities-no-delete` off the identity resource group.
> 2. Delete each role assignment of that managed identity, then read the list again to confirm it's empty.
> 3. Delete the managed identity. Its federated credentials go with it.
> 4. Delete the role definitions the setup created for it, once nothing else uses them.
> 5. Put the lock back, and check that the identity is gone.
>
> On the GitHub side, we delete the environment's variables, then the GitHub environment and its branch rule. Section 6 of the guide has the commands for this demo, and PIPELINE.md section 7.1 has them for production.
