# The demo, as a script

This is the script for the talk. It runs the same steps as the production setup, with the same commands and in the same order, against the test repository `themasterishome/demo-bicep-deploy-test` and the Visual Studio subscription in the test tenant.

How to read it:

- A quoted paragraph is what you say.
- A code block is one command. From "One example, made and removed" on, the quoted line above the block says what that command is and what it does. Say that line, copy the command, run it, and wait for it to finish before the next one.
- Any other paragraph is a cue for you: what you should see, and what to do when the result is different. In Part 0 the cue also says why the check is there.
- A quoted paragraph that starts with "In production" is still something you say. It tells the audience where the real setup does the same thing a little differently.

Run every command in a Windows PowerShell window in this folder, never in Git Bash. Git Bash rewrites an argument that starts with `/subscriptions/` into a Windows path, and the command then fails.

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

Confirm that Azure CLI, GitHub CLI, Git and Python respond, then confirm that this folder's Git remote is the test repository.

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

The variable list shows no `MIRROR_PIPELINE_ENABLED` and no `MIRROR_DRIFT_SCHEDULE_ENABLED`, or shows them as `false`. The second command shows seven lines with `true`, left from the earlier runs. Step 2 sets all seven enabled flags to `false` before anything runs. The pull requests in steps 6, 11, 13, 14 and 15 set six of them back to `true`, one unit at a time. `demo-subscription` stays disabled in this demo. There is no wave 3. That unit has no wave number.

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

> In production, the same process runs on GitHub Enterprise Cloud in IT's private repository. It covers about seventy units across eleven subscriptions and the tenant, with teams as reviewers and a smaller team approving changes that affect access.

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

> In production, this pattern scales to twenty-five GitHub environments and twenty-four managed identities. Each subscription has its own deploy identity and govern identity, and those identities live in a locked resource group in the platform subscription.

### One example, made and removed

> Let's build one example from scratch. I'll create a GitHub environment, a managed identity with a narrowly scoped role, and a federated credential that connects them. Once we've seen how they work together, I'll remove everything we created.

If an earlier run of this part stopped midway, run the removal commands at the end of this part first, so the names are free. `az group delete` takes a few minutes.

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

The output shows seven lines with `false`.

> The flags look right. I'll stage `deploy/units.json` now.

```powershell
git add deploy/units.json
```

> Next, I'll commit that change with a message explaining that every unit is disabled for the next demo.

```powershell
git commit -m "Disable every unit for the next demo"
```

> Now I'll push the updated `master` to the test repository, where direct pushes are allowed and the pipeline switch is still off, so every job will skip.

```powershell
git push test HEAD:master
```

The push prints the new commit range. On GitHub, open the **Actions** tab and look for `mirror-validate`. Its jobs should all be skipped because the pipeline switch is off. There should be no `mirror-deploy-unit` run because that workflow starts only when someone selects **Run workflow**.

> In the production Enterprise repository, a ruleset protects `master`, so we'd push this same commit to a branch with a command like `git push origin HEAD:refs/heads/sync-demo` and open a pull request into `master`. We won't run those steps here because this test repository allows direct pushes, and this commit is already on `master`.

A refusal that names the token scope means `gh auth refresh -h github.com -s workflow`. A refusal that names the account means `gh auth switch --hostname github.com --user themasterishome`, then `gh auth setup-git`.

### 3. Turn the pipeline switch on (GUIDE.md step 3.20)

> Every workflow checks the repository variable `MIRROR_PIPELINE_ENABLED` before its jobs run. I call it the pipeline switch because setting it to anything other than `true` stops every job. That gives us one place to pause the whole pipeline if something looks wrong.
>
> Now that the setup is in place, I'll turn the pipeline switch on by setting `MIRROR_PIPELINE_ENABLED` to `true`.

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

> Let's read the repository variables back and confirm the switch is on.

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

The list shows `MIRROR_PIPELINE_ENABLED` with the value `true`. Setting it starts no run by itself. In the browser the same variable is under **Settings** > **Secrets and variables** > **Actions** > **Variables**. A refusal means the active account is not `themasterishome`. Switch it as in step 1.

> In production, IT sets the same variable once the GitHub environments, the managed identities and the variables are in place and checked.

### 4. The first validate run (GUIDE.md step 3.21)

> First, I'll show that our offline checks work without signing in to Azure. I'll open a pull request that touches no deployment unit, so the change has nothing to preview.
>
> We'll start the first check from a new branch. I'll create `first-checks` and switch to it now.

```powershell
git switch --create first-checks
```

> We need a small change for the pull request, but we don't want to touch a deployment unit. I'll add a blank line to `README.md`.

```powershell
Add-Content -Path README.md -Value ''
```

> The harmless README change is ready. I'll commit it.

```powershell
git commit --all --message "First run of the checks"
```

> Next, I'll push `first-checks` and set the test remote as its upstream.

```powershell
git push -u test first-checks
```

> With the branch pushed, let's open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head first-checks --title "First run of the checks" --body "First run of the checks"
```

Open the pull request in the browser and show the checks at the bottom of the **Conversation** tab.

> These five jobs run on every push and pull request without calling Azure. `secret-scan` looks for passwords and keys, while `actionlint` checks that the workflow files are valid. `workflow-hygiene` checks the pipeline rules and runs their tests, `preflight` compiles every unit and checks the code layout, and `portability` makes sure the scripts behave consistently on Windows and Linux. Because these checks run before any Azure sign-in, they can catch a problem before it reaches the deployment stage.
>
> `mirror-pr` runs alongside them and works out which units the change touches. Since this pull request touches no units, there is no what-if to run and `pr-gate` passes.

After a few minutes the five jobs are green. `mirror-pr` shows the job `plan` and a green `pr-gate`, with no `whatif` job. The ruleset `protect-master` requires those five jobs plus `pr-gate`, six checks in all. If a job fails, open it and read its first error (GUIDE.md section 5). If `protect-master` does not list the six checks yet, add them as GUIDE.md step 3.21, item 3, shows.

> I'll close this pull request without merging and return to `master`. We'll keep the branch because the next step uses it to test the environment rule.
>
> First, I'll close the pull request.

```powershell
gh pr close first-checks --repo themasterishome/demo-bicep-deploy-test
```

> Now let's return to `master`.

```powershell
git switch master
```

### 5. The first drift run (GUIDE.md step 3.22)

> Next, I'll show that the reader identity can sign in from GitHub and that the drift workflow can report a problem through a repository issue. Every unit is off, so there is nothing to inspect. The check will stop on purpose, and the workflow should report that result.
>
> Let's start `mirror-drift` from `master` and watch the sign-in succeed before the check reports that no units are enabled.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

Open the run from **Actions** > **mirror-drift** when it ends. The `azure/login` step is green. "Drift sweep (read-only)" fails, and its last line starts with `STOP: no enabled unit to check in deploy/units.json`. The `report` job prints `Drift report: issue #N is opened (error).` The **Issues** tab holds the issue.

> The sign-in worked without a password because GitHub's token matched the federated credential. The workflow also opened an issue in the repository, which notifies the people watching it. A failed run can be easy to miss, but the issue makes the result visible.

> Since every unit is disabled, the check cannot report a clean result, and the issue will stay open until we close it. Let's list the open issues and note its number.

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

> Now I'll close that issue. Replace `ISSUE_NUMBER` with the number from the list before running this.

```powershell
gh issue close ISSUE_NUMBER --repo themasterishome/demo-bicep-deploy-test
```

> Now let's test the branch rule. I'll start the same drift check from `first-checks`, the branch we created in step 4, and GitHub should block it before any job can run.

```powershell
gh workflow run mirror-drift.yml --ref first-checks --repo themasterishome/demo-bicep-deploy-test
```

> Give GitHub about 30 seconds to reject the run, then check the three newest drift runs. The latest one should show a `failure` conclusion because the environment blocks it before any step starts.

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

The run fails before any step, with `Branch "first-checks" is not allowed to deploy to mirror-reader-dispatch due to environment protection rules`, and the `report` job is skipped.

> GitHub rejected the run before any step started, just as we expected. A workflow copied to another branch can't use this environment because only `master` is allowed. We apply the same branch protection to every deployment environment.
>
> Now let's remove `first-checks` from the remote.

```powershell
git push test --delete first-checks
```

> And we'll remove the local copy too.

```powershell
git branch --delete --force first-checks
```

A failed sign-in with `AADSTS70021` means the federated credential's subject does not match, or the credential is only a minute old. Wait a few minutes and run it again, or compare it with the read-back of GUIDE.md step 3.17. A `report` job that fails means Issues are off. Turn them on under **Settings** > **General** > **Features** and run it again. A `report` job that prints `is updated` instead of `is opened` means a drift issue was still open. Close it as Part 0 shows. If the run on `first-checks` signs in, `mirror-reader-dispatch` has no branch rule (GUIDE.md step 3.11).

### 6. A pull request and its preview (GUIDE.md section 4.2, items 1 and 2)

> Now let's move on to a real change. Every change follows the same path through a branch, an edit, and a pull request. I'll enable the pilot unit, which deploys an empty template to an empty resource group. That lets us prove the sign-in, permissions, approval, and evidence work together without creating any resources.
>
> We created the demo resource groups by hand earlier. Before running a preview, I'll make sure `rg-demo-pilot`, `rg-demo-network`, and `rg-demo-routing` exist. This setup is safe to repeat.

```powershell
foreach ($g in 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') { az group create --name $g --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy --query properties.provisioningState -o tsv }
```

The output is `Succeeded` three times.

> I'll create a branch called `enable-pilot` and switch to it. Then I'll edit the `pilot-empty-rg` flag by hand, so we can see exactly which unit we're enabling.

```powershell
git switch --create enable-pilot
```

Open `deploy/units.json` in an editor, set `"enabled": true` in the entry of `pilot-empty-rg` and save it.

> The single flag is updated. I'll commit that change now.

```powershell
git commit --all --message "Enable the pilot unit"
```

> Next, I'll push `enable-pilot` to the test repository.

```powershell
git push -u test enable-pilot
```

> With the branch up, let's open the pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-pilot --title "Enable the pilot unit" --body "Enable the pilot unit"
```

Show the pull request. `mirror-pr` has a job `whatif pilot-empty-rg`. Its comment shows the gate PASS and no records.

> This is the part reviewers often find most useful. Before the pull request can be merged, the pipeline runs a what-if against live Azure. It shows what the deployment would do without changing anything, and it runs as the reader identity, which has no write access. The gate checks every record and stops the run if the plan includes a create, change, or delete that hasn't been explicitly named. That gives the reviewer a clear picture of what would actually happen.

A `whatif` job that fails with `ResourceGroupNotFound` means `rg-demo-pilot` is missing. Run the first command of this step again. A refused push means the token lacks the `workflow` scope, or the active account is wrong (step 1).

### 7. Approve and merge, and see that the merge starts nothing (GUIDE.md section 4.2, items 3 and 4)

In the private window, as `klaudiomarashi`, open the pull request, select **Files changed**, then **Review changes**, **Approve** and **Submit review**.

> The second person has approved the code, so now I'll merge the pull request.
>
> After the second person approves, I'll squash-merge the pull request and delete its branch.

```powershell
gh pr merge enable-pilot --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> The merge is done. Let's switch back to `master`.

```powershell
git switch master
```

> I'll now bring local `master` up to date with the test repository.

```powershell
git pull test master
```

> Let's look at the recent deploy runs on `master` and confirm that the merge didn't start a deployment.

```powershell
gh run list --workflow mirror-deploy-unit.yml --branch master --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

No run of `mirror-deploy-unit` began at the merge.

> The merge changed the code on `master`, but it deployed nothing, and that's intentional. A deployment needs its own change ticket, reason, and reviewer for that specific run. Merging doesn't provide those details, so someone has to start the deployment as a separate step.

GitHub refuses the merge while a required check is still running, or while the branch is not up to date. Wait for the checks, or select **Update branch**. If you are running alone, follow GUIDE.md section 3.0 and merge your own pull request. With the two accounts, `klaudiomarashi` approves first. If a run did start, open it and read its trigger. `mirror-deploy-unit.yml` starts only from `workflow_dispatch`, which is **Run workflow**.

### 8. A plan only (GUIDE.md section 4.2, item 11)

> Before deploying, I'll ask the pipeline for a plan from `master`. It's a what-if, so it won't change anything. This lets us see exactly what the deployment would do before we decide whether to apply it.
>
> First, let's ask for a plan without applying it. I'll start `mirror-deploy-unit` for `pilot-empty-rg` with `apply` left off, using ticket `DEMO-0003` and a reason that says this is a plan only.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot, plan only" --repo themasterishome/demo-bicep-deploy-test
```

Open the run "Deploy pilot-empty-rg (DEMO-0003)". The jobs `select`, `plan pilot-empty-rg` and `collect` run. The summary shows "Gate PASS, approvable" and ends with "This run was started as a plan only (apply is off). Nothing waits for a reviewer."

> The run records the change ticket and reason, so we can see later why it was started. The `select` job checks the inputs, `plan` runs the what-if as the reader identity, and `collect` sorts the result into the right tier. Since this is plan-only, it doesn't wait for approval and nothing gets deployed.

A run that fails in `select` names the input it refused, such as a unit whose enabled flag is still `false`. Enable the unit (step 6) and start again. The same run can be started in the browser with **Actions** > **mirror-deploy-unit** > **Run workflow**. Keep `master`, and leave `apply` unticked.

### 9. Deploy the pilot, with an approval (GUIDE.md section 4.2, items 5 to 9)

> Now we're ready to run the deployment with `apply` turned on. That means it can deploy only after a reviewer has approved the plan.
>
> The plan is ready. Now I'll start the same unit again with `apply` set to `true`, keeping ticket `DEMO-0003`. This time the run can deploy after approval.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Open the run. After `plan pilot-empty-rg` and `collect`, the job `apply pilot-empty-rg` shows **Waiting** for the GitHub environment `mirror-production-demo`. Show that waiting job in your own window first.

> The deployment is paused while it waits for a reviewer. Since I started the run, GitHub won't let me approve it. That's Prevent self-review at work. The reviewer inspects the plan attached to this run and compares it with the plan-only preview, then approves with a comment that includes the ticket number.

Do not select **Start all waiting jobs**. That is the administrator bypass, and it would approve the run as the person who started it. **Review deployments** shows nothing to tick on an old or finished run, so stay on the newest one.

In the private window, open the run, select **Review deployments**, tick `mirror-production-demo`, write a comment that names `DEMO-0003` and select **Approve and deploy**.

> The reviewer has approved the run. Let's find its ID so we can follow it to completion.

```powershell
gh run list --workflow mirror-deploy-unit.yml --limit 1 --repo themasterishome/demo-bicep-deploy-test
```

> Now let's watch the run until it finishes. Replace `RUN_ID` with the long number in the list's `ID` column. It's also the number after `/actions/runs/` in the run address. The `#N` in the title is a different number. Put the actual ID here before running the command.

```powershell
gh run watch RUN_ID --repo themasterishome/demo-bicep-deploy-test
```

The summary ends with `Gate step exit: 0, deployed, and the second check passed.` The run keeps the artifacts `reviewed-plan-pilot-empty-rg` and `evidence-deploy-pilot-empty-rg`.

> After approval, the apply job first checks that `master` hasn't changed and that the plan is less than a day old. It then signs in as the deploy identity, takes a fresh what-if, and compares that result with the approved plan. This is the first check, and deployment proceeds only if the two plans match. After deploying, the job takes a second what-if to confirm there is nothing left to change. If either check finds a difference, the job stops.

> In production, the reviewer is anyone in the approvers team except the person who started the run, and the comment names IT's change ticket.

An apply that runs at once, with no pause, means the GitHub environment has no required reviewer (GUIDE.md step 3.11). Read a failed apply in "Reading a failed run" at the end.

### 10. Download the evidence (GUIDE.md section 4.2, item 10)

> Every deployment leaves evidence that shows what happened. In production, we attach that evidence to the change ticket.
>
> The deployment has finished, so let's find its evidence artifact. The list shows an ID and name for each artifact. Find `evidence-deploy-pilot-empty-rg` and use the same `RUN_ID` from step 9.

```powershell
gh api "repos/themasterishome/demo-bicep-deploy-test/actions/runs/RUN_ID/artifacts" --jq ".artifacts[] | [.id, .name] | @tsv"
```

The next commands use that run's artifact ID and artifact name.

> First, I'll make a folder to hold the evidence download.

```powershell
New-Item -ItemType Directory -Force C:\demo-setup\evidence-pilot | Out-Null
```

> On Windows, `gh run download` fails for these artifacts because the zip contains the same entry twice. So we'll fetch the zip through the API instead. `cmd /c` keeps Windows PowerShell 5.1 from changing its bytes. Fill in `ARTIFACT_ID` and `ARTIFACT_NAME` from the list above.

```powershell
cmd /c "gh api repos/themasterishome/demo-bicep-deploy-test/actions/artifacts/ARTIFACT_ID/zip > C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip"
```

> Now I'll use Python to unpack the zip into a folder with the artifact's name.

```powershell
python -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip C:\demo-setup\evidence-pilot\ARTIFACT_NAME
```

> Let's locate the two files we want to show: `approval.txt` and `post-summary.txt`.

```powershell
Get-ChildItem -Path C:\demo-setup\evidence-pilot -Recurse -Include approval.txt, post-summary.txt | Select-Object -ExpandProperty FullName
```

The last command prints the paths of `approval.txt`, which has a `deployed=` line, and `post-summary.txt`, which says Gate PASS.

> `approval.txt` records who started the run, which options they chose, and whether it deployed. `post-summary.txt` contains the second check. Together, these files show what we planned, what the reviewer approved, and what Azure ended up with.

### 11. Wave 1, the network (GUIDE.md section 4.3)

A wave is the next unit in the deploy order. Wave 0 was the pilot. Wave 1 creates the network.

> Now we're moving on to the first units that create real resources. The network unit sets up a network security group, a virtual network, a private endpoint with its DNS, and the related lock, policy, and Reader assignment. I'll enable both the network and routing units in one pull request, but routing won't run until the network wave is complete.
>
> Let's create a branch for the network and routing changes, and switch to it.

```powershell
git switch --create enable-waves
```

Open `deploy/units.json`, set `"enabled": true` in the entries of `rg-demo-network` and `rg-demo-routing` and save it.

> Both enabled flags are set. I'll commit them together.

```powershell
git commit --all --message "Enable the network and routing units"
```

> Next, I'll push `enable-waves` to the test repository.

```powershell
git push -u test enable-waves
```

> With the branch pushed, let's open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-waves --title "Enable the network and routing units" --body "Enable the network and routing units"
```

Show the preview comment. Approve the pull request as `klaudiomarashi`, the same clicks as step 7.

> Once the pull request is approved, I'll squash-merge it and delete the branch. As before, that puts the code on `master` but starts no deployment.

```powershell
gh pr merge enable-waves --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> Let's switch back to `master` now.

```powershell
git switch master
```

> And I'll bring local `master` up to date with the test repository.

```powershell
git pull test master
```

> Just as before, merging only updates the code and starts no deployment. I'll ask the pipeline for a plan now, so we can see what the network unit would create.
>
> I'll start a plan-only run for `rg-demo-network` with ticket `DEMO-0004`. The summary will give us the resource IDs, including two with GUIDs generated by Bicep, so I'll copy those from the output rather than guess them.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

Open that run. The plan is red, and its summary gives the ready command with the nine resource IDs.

> The plan is red because it would create nine resources, and we haven't approved those creates yet. The gate requires the person starting the deployment to list every resource by its full resource ID in `allowCreate`. The reviewer can then check that list, and the run stops if the plan includes any create that wasn't named.

> The summary gives us a ready-to-use command with the nine resource IDs. Copy those IDs into `allowCreate` here, then check the ticket and reason before running it. This deployment uses ticket `DEMO-0004`, the reason `Wave 1, create the network`, and `apply` is on, so it will wait for approval before it deploys. GUIDE.md section 4.3, item 5, lists the nine IDs.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, create the network" -f apply=true -f allowCreate="ID1,ID2,ID3,ID4,ID5,ID6,ID7,ID8,ID9" --repo themasterishome/demo-bicep-deploy-test
```

Nine is the count in an empty group. If the lock, the policy assignment or the role assignment is live already, the ready command lists fewer. Approve the waiting apply as in step 9, with a comment that names `DEMO-0004`.

The plan shows the verdict approvable and nine Create records. After the approval, the second check ends with `NoChange=8`, one `Ignore` and one `Modify`, and the summary ends with `Gate step exit: 0, deployed, and the second check passed.` The Ignore is the network interface Azure creates for the private endpoint. The Modify is provider-set fields on the endpoint's zone group. `deploy/boundaries.json` lists both, so the gate passes them. If you are asked: the second check is judged without the `allowCreate` list, so a resource that was not created as the code says fails here.

In the portal, `rg-demo-network` holds `nsg-demo` and `vnet-demo`. The lock `lock-rg-demo-network` shows under **Locks**.

> The second check runs a fresh what-if without the `allowCreate` list. Since it passes, we know the gate found no differences beyond the documented `Ignore` and `Modify` cases, so the resources are in the expected state under those rules.

Download the evidence as in step 10, with `evidence-deploy-rg-demo-network`. If the resources exist already, the plan shows NoChange and passes with no `allowCreate`, and the apply still waits for the reviewer. A red plan with exit code 2 names a setup problem (GUIDE.md section 5).

### 12. Wave 2, the routing (GUIDE.md section 4.4)

> We enabled routing in the same pull request, so there is no need to open another one. It runs after the network because it is second in the deployment order. This unit also creates an Automation account and a credential for it. The credential's password stays in Key Vault, so it never appears in the repository.

> I'll wait for the network deployment in step 11 to finish before starting routing. As before, we'll begin with a plan and review its Create records before anyone approves the deployment.
>
> The network wave is complete. Next, let's get a plan for `rg-demo-routing` with ticket `DEMO-0005`.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

In an empty group the plan is red with four Creates: `rt-demo`, `asg-demo`, the Automation account `aa-demo-secrets` and its credential `demo-cred`.

> The plan summary gives us the exact command and all four resource IDs. Here, `allowCreate` names every resource in the plan, `apply` is on, and the ticket is `DEMO-0005`. The reason tells the reviewer that this run creates the routing.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, create the routing" -f apply=true -f allowCreate="/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/applicationSecurityGroups/asg-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets/credentials/demo-cred" --repo themasterishome/demo-bicep-deploy-test
```

If the resources exist already, the plan is green with no Create and the deployment needs no `allowCreate`. Approve the waiting apply as in step 9, with a comment that names `DEMO-0005`.

The second check shows `rt-demo`, `asg-demo`, `aa-demo-secrets` and `demo-cred` as NoChange.

> When the deployment needed the password, it read it directly from Key Vault using `az.getSecret` in the parameters file. The evidence replaces the value with `<secure input, not recorded>`, so the password never appears in a log or in a repository file.

> In production, the same vault pattern holds the VPN shared keys. IT loads them into the vault once, and the code reads them at deployment.

> Now let's deploy the same code a second time. Since the first deployment already created the resources, the plan should contain no Creates and won't need an `allowCreate` list. The reason records that we're applying the same commit again.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, the second deployment of the same commit" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Approve it as in step 9. The plan, the first check and the second check all show `NoChange=4`, and the gate step exits 0.

> This shows that the code now matches what's live. When we deploy the same commit again, Azure finds nothing to change. That's the state we want every production unit to reach.

A failure that names the vault means the deploy identity lacks the role Mirror Key Vault Deployment on that vault (GUIDE.md step 3.15). GUIDE.md section 4.4 explains the proof.

### 13. Wave 4, the privileged unit (GUIDE.md section 4.5)

This demo has no wave 3. `demo-subscription` stays disabled, on purpose. The next unit is wave 4.

> Some resources control who has access, such as Owner role assignments and custom roles. We put those in a privileged unit with its own managed identity and GitHub environment. If the ordinary deploy identity could both create resources and grant access, it could effectively make itself an Owner. That's why it cannot grant Owner. Access changes have to go through a separate, more restricted path.
>
> Let's create and switch to a branch for the privileged unit: `enable-privileged`.

```powershell
git switch --create enable-privileged
```

Open `deploy/units.json`, set `"enabled": true` in the entry of `demo-privileged` and save it.

> I've enabled the unit. Now I'll commit that flag.

```powershell
git commit --all --message "Enable the privileged unit"
```

> Next, I'll push `enable-privileged` to the test repository.

```powershell
git push -u test enable-privileged
```

> With the branch pushed, let's open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-privileged --title "Enable the privileged unit" --body "Enable the privileged unit"
```

Approve the pull request as `klaudiomarashi`.

> After approval, I'll squash-merge the pull request and delete its branch. Just as in step 7, the code reaches `master`, but no deployment starts.

```powershell
gh pr merge enable-privileged --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> Let's return to `master`.

```powershell
git switch master
```

> Now I'll update local `master` from the test repository.

```powershell
git pull test master
```

> Before we deploy, let's ask for a plan with ticket `DEMO-0006`. The summary will give us the two resource IDs we need for the deployment command.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

The plan's ready command lists two IDs: the Owner role assignment on `rg-demo-network`, and the role definition `Demo Reader Plus`.

> The plan summary has the exact IDs. Copy both into `allowCreate` here. This run uses ticket `DEMO-0006` and the reason `Wave 4, the privileged unit`. `apply` is on.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, the privileged unit" -f apply=true -f allowCreate="ID1,ID2" --repo themasterishome/demo-bicep-deploy-test
```

The job that waits is `apply privileged demo-privileged`. It is not named `apply demo-privileged`. It waits in the GitHub environment `mirror-privileged-demo`, and it deploys as the govern identity `id-mirror-govern-demo`. The second check ends with `NoChange=2`.

> Notice that this run is waiting in a different GitHub environment. The unit's tier selected that environment automatically, not the person who started the run. Before approving, the reviewer checks that every role assignment is named and that nobody gets Owner access beyond what the ticket allows.

> In production, only a smaller team can approve the privileged environments because that team is responsible for access changes. In this demo, the same second account approves both tiers since a personal account can't belong to the approver teams.

Approve it in `mirror-privileged-demo` as `klaudiomarashi`, with a comment that names `DEMO-0006`. A production unit that declares an Owner assignment fails the `preflight` job of `mirror-validate`. That is the other half of the same rule: the code is refused before anyone can deploy it from the ordinary tier.

### 14. Wave 5, the management group (GUIDE.md section 4.6)

> Not everything lives inside a subscription. Management groups sit above subscriptions, so their units deploy at the tenant level and use their own managed identity.
>
> Next, let's create and switch to a branch for the tenant management-group unit: `enable-tenant-mg`.

```powershell
git switch --create enable-tenant-mg
```

Open `deploy/units.json`, set `"enabled": true` in the entry of `demo-tenant-management-group` and save it.

> The unit is enabled. I'll commit that flag now.

```powershell
git commit --all --message "Enable the management group unit"
```

> Now I'll push `enable-tenant-mg` to the test repository.

```powershell
git push -u test enable-tenant-mg
```

> Let's open a pull request from this branch into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-mg --title "Enable the management group unit" --body "Enable the management group unit"
```

Approve the pull request as `klaudiomarashi`.

> After approval, I'll squash-merge the pull request and delete the branch. Remember, the merge itself starts no deployment.

```powershell
gh pr merge enable-tenant-mg --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> The merge is complete. Let's switch back to `master`.

```powershell
git switch master
```

> And I'll update local `master` from the test repository.

```powershell
git pull test master
```

> We created `mg-demo` by hand because Azure can't run a what-if against a management group that doesn't exist yet. This unit updates that existing group, and the pull-request preview showed no Creates. So we can go straight to deployment without a separate plan-only run or an `allowCreate` list. We'll use ticket `DEMO-0007`.
>
> Let's start that deployment now.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-management-group -f changeRef=DEMO-0007 -f reason="Wave 5, the management group" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting job `apply privileged demo-tenant-management-group` in the GitHub environment `mirror-privileged-tenant`, as `klaudiomarashi`, with a comment that names `DEMO-0007`. The apply signs in as `id-mirror-govern-tenant`. The second check passes with `NoChange=1`.

> In production, we find the management group above the subscriptions the same way. Tenant-level units then deploy with the tenant govern identity, but only after the privileged team approves them.

`AuthorizationFailed` on a tenant unit means the reader identity lacks Reader, or lacks Mirror What-If Reader Tenant, on the Tenant Root Group (GUIDE.md step 3.14, item 3).

### 15. Wave 6, the Reader role assignment on the management group (GUIDE.md section 4.7)

> This final unit assigns the Reader role to the reader identity at the management-group scope. It has a separate pull request, which gives each tenant unit its own preview and approval.
>
> For the final tenant unit, let's create and switch to `enable-tenant-governance`.

```powershell
git switch --create enable-tenant-governance
```

Open `deploy/units.json`, set `"enabled": true` in the entry of `demo-tenant-governance` and save it.

> The Reader role assignment unit is enabled. I'll commit that change.

```powershell
git commit --all --message "Enable the management group governance unit"
```

> Next, I'll push the branch to the test repository.

```powershell
git push -u test enable-tenant-governance
```

> With the branch pushed, let's open its pull request into `master`.

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-governance --title "Enable the management group governance unit" --body "Enable the management group governance unit"
```

Approve the pull request as `klaudiomarashi`.

> Once the pull request is approved, I'll squash-merge it and delete the branch.

```powershell
gh pr merge enable-tenant-governance --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

> Let's return to `master` for the deployment.

```powershell
git switch master
```

> I'll bring local `master` up to date one more time.

```powershell
git pull test master
```

> Before we deploy, let's ask for the plan with ticket `DEMO-0008`. Its summary will give us the Reader role assignment's resource ID. This tenant-level plan also needs `mg-demo` to exist, which is why we ran step 14 first.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

The ready command lists the ID of the Reader role assignment on `mg-demo`.

> This is that command, in shape. Copy the ID from the summary into `allowCreate`. The ticket is `DEMO-0008` and the reason is `Wave 6, Reader on the management group`. `apply` is on.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, Reader on the management group" -f apply=true -f allowCreate=ID --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting job `apply privileged demo-tenant-governance` in `mirror-privileged-tenant`, as `klaudiomarashi`, with a comment that names `DEMO-0008`. The plan holds one Create. The second check passes with `NoChange=1`.

### 16. The drift check and the drift issue (GUIDE.md section 4.9)

> Everything we've deployed now matches the code, but people can still make changes in the portal. When someone changes a resource by hand, live Azure and the code drift apart. The drift check catches those differences by running a read-only what-if for every enabled unit, then keeping a single GitHub issue up to date with its findings.

> I'll wait for each run to finish before starting the next one. If another drift run starts while one is still waiting, GitHub replaces the waiting run.
>
> Before we run the drift check, let's look at its recent runs. We'll use this view to track each run in this part.

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

> We'll start with a clean baseline by running `mirror-drift` from `master` while everything still matches the code.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The run is green. The `report` job prints `Drift report: every checked unit is clean, and no drift issue is open.`

> Now I'll make a small change directly in the portal by adding a tag to the route table. That gives us a simple example of drift to find.

In the Azure portal, search for **Route tables**, select `rt-demo`, select **Tags**, add the name `changedBy` with the value `portal` and select **Apply**.

> That's a common real-world situation. Someone makes a quick fix in the portal, but the code hasn't caught up yet.

> I've changed the tag outside the code, so let's run the drift check again and see if it spots the difference.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The run is red. `rg-demo-routing` is `DRIFT`, with a Modify on `rt-demo` that removes the tag `changedBy`. The `report` job prints `Drift report: issue #N is opened (drift).`

Open the **Issues** tab and show the issue. It lists `rg-demo-routing` and links the run.

> The drift check hasn't changed anything in Azure. It only reports what it found, and the GitHub issue acts as the alert. People watching the repository are notified when that issue opens, and the report tells them which unit drifted and links to the evidence.

> Nothing else has changed. Let's run the check once more and see how the workflow handles the same finding when it comes back.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The `report` job prints `Drift report: issue #N is updated with this run, and its findings are the same (drift).` It adds no comment.

> The findings haven't changed, so the workflow updates the run link without adding another comment. That way, people don't receive the same alert every week.

> To repair the drift, we'll deploy the value that's already recorded in the code. Since `rt-demo` already exists, we need to name it in `allowModify`. We'll run this with ticket `DEMO-0010` and `apply` turned on.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0010 -f reason="Undo the drift on rt-demo" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo --repo themasterishome/demo-bicep-deploy-test
```

Approve the run as `klaudiomarashi` and wait for it to finish.

> This is still an ordinary deployment, so it has a ticket and needs approval. If the portal change had been the right one, we would update the code through a pull request instead of deploying over that change.

> The repair is complete, so let's run the check one last time. We expect every unit to be clean and the drift issue to close.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The run is green. The `report` job prints `Drift report: every checked unit is clean, so issue #N is closed.` The issue is closed with a comment.

> Once the check confirms that everything is back in sync, it closes the issue for us.

A run that lists `demo-subscription` as `DRIFT`, with NoRecord lines, means that unit is enabled. The subscription holds resource groups that are not part of the demo, such as WinServ2022, Automation, coach01 to coach29 and consultant01 to consultant13. Leave them alone, and keep `demo-subscription` disabled. A drift run that reports another resource group the code does not declare means the subscription holds another group. The summary names it. A `report` job that fails means Issues are off. `klaudiomarashi` is notified only when that account watches the repository.

### 17. Turn on the weekly drift run

> The drift check can also run automatically every Monday at 05:00 UTC. We control that schedule with `MIRROR_DRIFT_SCHEDULE_ENABLED`, and we turn it on only when the team is ready to respond to anything it finds.
>
> To enable the weekly schedule, I'll set `MIRROR_DRIFT_SCHEDULE_ENABLED` to `true`. We should turn it on only when at least one unit is enabled, since step 5 showed that a run with every unit disabled fails on purpose.

```powershell
gh variable set MIRROR_DRIFT_SCHEDULE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

> Let's check the repository variables and confirm the weekly switch is on.

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

The list shows `MIRROR_DRIFT_SCHEDULE_ENABLED` with the value `true`. The next Monday, the runs of `mirror-drift` include one whose event is `schedule`. The demo does not wait for that Monday. **Run workflow** runs the same two jobs.

> In production, IT leaves the weekly schedule off until the team is ready to use it, then turns it on with the same variable. GitHub notifies only the person who last edited the schedule when a scheduled run fails. That's another reason we report drift through an issue, where everyone watching the repository can see it.

A weekly run that skipped every job means this variable is not `true`, or the pipeline switch is off.

### 18. A change after the baseline, and a rollback (optional, GUIDE.md sections 4.8 and 4.10)

> Once a unit matches what's live, every later change follows the normal pull-request process. If a change turns out to be wrong, we roll it back the same way in reverse: revert it in Git, run a what-if, get approval, and deploy the correction.

Follow GUIDE.md section 4.8 and then 4.10. The merge of each pull request starts no run. The resource IDs for `allowModify` are in the preview's comment. The second check ends with `NoChange=2` after the rule is added, and `nsg-demo` is NoChange again after the rollback. GUIDE.md section 5 lists the causes when something fails.

## The closing

> To bring it all together, every change starts as code and is reviewed in a pull request with a real what-if. A deployment starts only when someone requests it, a second person approves that exact plan, and the follow-up check passes. The pipeline signs in through federated credentials without storing secrets, and write-capable identities can be used only from `master`. Changes to access go through the more restricted privileged tier. Then, every week, the drift check compares live Azure with the code and lets us know if they no longer match.

## Turning the demo off

> That's the end of the demo. I'll switch the pipeline off again by setting `MIRROR_PIPELINE_ENABLED` to `false`. From then on, every workflow job will skip.

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body false --repo themasterishome/demo-bicep-deploy-test
```

> Next, I'll remove the weekly drift switch. If we left it set to `true`, the Monday schedule could start again the next time the pipeline switch is turned on.

```powershell
gh variable delete MIRROR_DRIFT_SCHEDULE_ENABLED --repo themasterishome/demo-bicep-deploy-test
```

> Let's make sure there are no open drift issues left from the demo. If one appears here, close it using the same steps we followed in Part 0.

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

> I'll switch GitHub CLI back to `klaudiomarashi`, the reviewer account.

```powershell
gh auth switch --hostname github.com --user klaudiomarashi
```

> Finally, I'll point Azure CLI back to your usual subscription. Replace `SUBSCRIPTION_ID` with its real ID before you run this. The demo resources will remain until we remove them using GUIDE.md section 6.

```powershell
az account set --subscription SUBSCRIPTION_ID
```

## Reading a failed run

1. On GitHub, open **Actions**, then **mirror-deploy-unit**, then the run, then the apply job. The gate step's log prints its exit code and the last lines of the deploy script. The codes are 0 for deployed and checked, 1 for refused by the gate, 2 for a setup or identity problem, and 3 for a deployment that ran and failed, or whose second check failed. The job summary holds the plan verdict. The artifacts `evidence-deploy-UNIT` and `reviewed-plan-UNIT` hold the what-if results as JSON.
2. In Azure, open the deployment record `mirror-UNIT-COMMIT`. In the portal, that is the subscription or the resource group, then **Deployments**, then the failed record, then **Operation details**. That page names the resource and the error code. From the CLI, the next two commands read the same error. Replace `UNIT`, `COMMIT` and `RESOURCE_GROUP` from the run.

   > For a subscription-scope deployment, let's read the error details here.

   ```powershell
   az deployment sub show --name mirror-UNIT-COMMIT --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.error
   ```

   > If the deployment was scoped to a resource group, use this version to read its error details.

   ```powershell
   az deployment group show --name mirror-UNIT-COMMIT --resource-group RESOURCE_GROUP --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.error
   ```

3. The project's PIPELINE.md section 7 maps each message to its cause and its fix. REFERENCE.md section 4 is the rollback after exit 3. GUIDE.md section 5 lists the causes seen in this demo.
4. A deployment can fail in Azure with `ResourceNotFound` even though its plan showed NoChange. A what-if never checks that a resource a setting points at still exists, for example the scale set named by an autoscale setting. The other resources of that deployment keep their live values, and nothing is deleted. The fix is in the code. The resource whose target is gone is changed to an existing reference, and the unit is planned and deployed again at the new commit.
5. A retry is a new run, at the commit that contains the fix. Re-running the failed run does not deploy.
6. For the drift check, open the **Issues** tab and the run the issue links to. The `drift` artifact holds each unit's evidence.

## Removing a managed identity and its roles

Do this in order. Delete each object by its ID, so a delete cannot hit a different object that happens to share the name.

1. Take the delete lock `mirror-identities-no-delete` off the identity resource group.
2. Delete each role assignment of that managed identity.
3. Delete the managed identity. Its federated credentials go with it.
4. Delete the role definitions the setup created for it.
5. Delete the policy assignment on the resource group.
6. Put the lock back.

On the GitHub side, delete the environment's variables, then delete the GitHub environment and its branch rule. GUIDE.md section 6 has the commands for this demo. The project's PIPELINE.md section 7.1 has the commands for the project.
