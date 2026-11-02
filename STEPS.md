# The demo, as a script

This is the script for the talk. It runs the same steps as the production setup, with the same commands and in the same order, against the test repository `themasterishome/demo-bicep-deploy-test` and the Visual Studio subscription in the test tenant.

How to read it:

- A quoted paragraph is what you say.
- A code block is one command. Copy it, run it, and wait for it to finish before the next one.
- Any other paragraph is a cue for you: why this command is next, what you should see, and what to do when the result is different.
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

> What I'm about to show you is how we manage Azure with code. The resources we look after, the estate, are written in Bicep so the file matches what is live. The code is the production environment. A resource changes in Azure only after the same change has gone through a pull request that somebody reviewed.
>
> This demo runs in my own test tenant, on a small made-up estate of seven units. A unit is one piece of the estate that deploys on its own, such as one resource group, the settings of one subscription, or one management group. The workflows, the scripts and the checks are the same files production uses.
>
> There are four workflows. `mirror-validate` checks the code on every push, and it never calls Azure. `mirror-pr` previews every pull request against live Azure, and it changes nothing. `mirror-deploy-unit` deploys, and only when a person starts it and a second person approves that exact plan. `mirror-drift` checks whether live Azure still matches the code. In production that check runs every week.
>
> I use two accounts today. `themasterishome` writes the change and starts every run. `klaudiomarashi`, in a private browser window, reviews pull requests and approves deployments. GitHub will not let the person who started a deployment approve it. That setting is Prevent self-review. It is the four-eyes rule: two people have to agree, and they cannot be the same person.

> In production, this runs on GitHub Enterprise Cloud, in a private repository of IT's organization, with about seventy units across eleven subscriptions and the tenant. The reviewers there are teams, and a smaller team approves anything that changes who has access to what.

## Part 2. What was set up before, and one example of each

> Before any of this can run, three things have to exist: GitHub environments in the repository, managed identities in Azure for the jobs to sign in as, and a federated credential that links each environment to one identity. Creating all of it takes a while, so I set it up before today. I'll make one of each in front of you, so you can see the pieces, and then I'll remove the example. Everything else was made the same way.

### Show what is already there

List the GitHub environments. You will point at these names while you explain them.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/environments --jq ".environments[].name"
```

> These are the five GitHub environments. A GitHub environment is a named place in the repository settings where a job runs. It has its own variables, its own rule about which branch may use it and, if we want, its own reviewers. A job that deploys always runs in a GitHub environment, so that is where the approval happens.
>
> Two of them are for the reader identity, which only ever previews. `mirror-reader` serves pull request previews, from any branch. `mirror-reader-dispatch` serves the plans and the drift check, from `master` only. The other three are where deployments wait for approval. One is for ordinary resources. Two are for the privileged units, the ones that change who has access.

List the managed identities in the locked resource group.

```powershell
az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

> These are the four managed identities the pipeline signs in as. A managed identity means Azure holds the credential. Nobody can add a password or a client secret to it. The reader identity, `id-mirror-reader`, can only read and preview. The deploy identity, `id-mirror-deploy-demo`, writes ordinary resources. The two govern identities write the Owner-class role assignments and the custom roles, and nothing else.
>
> A job proves who it is with a federated credential. GitHub hands the job a short-lived token that says which repository and which GitHub environment it came from. Azure accepts that token only when the managed identity trusts exactly that repository and that environment. There is no secret stored anywhere that someone could copy.

> In production, there are twenty-five GitHub environments and twenty-four managed identities. Each subscription has its own deploy identity and its own govern identity. The identities sit in their own locked resource group in the platform subscription.

### One example, made and removed

> I'll make one example from scratch. A new GitHub environment, a new managed identity with one small role, and the federated credential that ties the two together. Then I'll remove all of it.

If an earlier run of this part stopped midway, run the removal commands at the end of this part first, so the names are free. `az group delete` takes a few minutes.

Create the example GitHub environment. The first command builds the branch policy. The second creates the environment with that policy. The third allows only the branch `master` to use it.

```powershell
$branchPolicy = @{ protected_branches = $false; custom_branch_policies = $true }
```

```powershell
@{ deployment_branch_policy = $branchPolicy } | ConvertTo-Json -Depth 4 | gh api --method PUT repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example --input -
```

```powershell
gh api --method POST repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example/deployment-branch-policies -f name=master -f type=branch
```

> The environment exists now, and only a run on `master` may enter it. A copy of the workflow on some other branch cannot use it, so that copy cannot sign in as the managed identity behind it either.

> In production, the deployment environments also get the approvers team as required reviewers, with Prevent self-review on. The reader environments have no reviewers, because a preview changes nothing.

Create a resource group that exists only for this example, so the cleanup deletes nothing else.

```powershell
az group create --name rg-demo-example --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-example -o table
```

Create the managed identity and keep its IDs in `$example`. The client ID is what a workflow stores. The principal ID is what a role assignment uses.

```powershell
$example = az identity create --name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth -o json | Out-String | ConvertFrom-Json
```

```powershell
$example | Select-Object name, clientId, principalId
```

> That is a new managed identity. On its own it can do nothing. It has no role, and nothing is allowed to sign in as it yet.

Assign one role, the built-in Reader role, on this resource group only. The GUID is the role definition ID of Reader.

```powershell
az role assignment create --assignee-object-id $example.principalId --assignee-principal-type ServicePrincipal --role acdd72a7-3385-48ef-bd42-f606fba81ae7 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o table
```

If it answers `PrincipalNotFound`, the new identity is not in the directory yet. Wait a minute and run the same command again.

> That GUID is the built-in Reader role, the permission to read a scope. It is separate from the reader identity we saw a moment ago. Each managed identity of the pipeline holds only the roles its job needs, and only on the scope it needs. The real reader identity holds Reader and a small custom role so it can preview. The deploy identity holds Contributor, plus a few narrow roles, and it may write ordinary role assignments. Only the govern identities may write the Owner-class ones.

Read the repository's numeric ID. The federated credential's subject includes it, so the trust is bound to this repository and not merely to its name.

```powershell
$repoId = gh api repos/themasterishome/demo-bicep-deploy-test --jq .id
```

Create the federated credential. The subject names the owner, the repository, and the GitHub environment `mirror-example`.

```powershell
az identity federated-credential create --name github-mirror-example --identity-name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --issuer https://token.actions.githubusercontent.com --subject "repo:themasterishome@49098959/demo-bicep-deploy-test@${repoId}:environment:mirror-example" --audiences api://AzureADTokenExchange -o table
```

> Look at the subject. It names the owner and the repository, each with its number, and then the GitHub environment. The numbers matter. A repository that is deleted and created again under the same name gets a new number, so the new repository cannot take over this trust.

> In production, the subject names IT's organization and repository in the same form, and the issuer is the one the enterprise uses.

Store the client ID on the GitHub environment, as the variable `AZURE_CLIENT_ID`. That tells a job in this environment which managed identity to sign in as. Then list the variable so the audience can see the value.

```powershell
gh variable set AZURE_CLIENT_ID --env mirror-example --body $example.clientId --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable list --env mirror-example --repo themasterishome/demo-bicep-deploy-test
```

> The client ID is public. On its own, it cannot sign anyone in. Sign-in also needs the federated credential. A job on `master`, in this environment, can now sign in as this managed identity and read this one resource group, and nothing more. The real setup is this, repeated for each GitHub environment and each managed identity.

Remove the example in this order. Delete the GitHub environment first. Its variable goes with it.

```powershell
gh api --method DELETE repos/themasterishome/demo-bicep-deploy-test/environments/mirror-example
```

Delete the Reader role assignment by the identity's principal ID, so the delete cannot hit a different assignment.

```powershell
az role assignment delete --assignee $example.principalId --role acdd72a7-3385-48ef-bd42-f606fba81ae7 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

Delete the managed identity. The federated credential goes with it.

```powershell
az identity delete --name id-mirror-example --resource-group rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

Delete the example resource group, then confirm it is gone.

```powershell
az group delete --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --yes
```

```powershell
az group exists --name rg-demo-example --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

`az group delete` takes a few minutes. When the delete has finished, the last command prints `false`.

> The federated credential went with the managed identity. The real identities sit in a resource group with a delete lock, `mirror-identities-no-delete`, so nobody can remove them by accident. Removing one of those takes the lock off first, deletes each item by its ID, and puts the lock back.

## Part 3. The demo

### 1. Sign in and start from `master`

> I'll start from a clean copy of the code, on `master`. That is the branch production deploys from.

Point Azure CLI at the demo subscription.

```powershell
az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
```

Use the GitHub account that writes the code and starts the runs.

```powershell
gh auth switch --hostname github.com --user themasterishome
```

Check out `master`, confirm the working folder is clean, and show the latest commits.

```powershell
git switch master
```

```powershell
git status --short
```

```powershell
git log --oneline -3
```

`git status` prints nothing. The log shows the newest commit at the top. A failed `git switch master` prints its reason.

### 2. Turn every unit off and push the folder (GUIDE.md steps 3.5 and 3.20)

> First I'll turn every unit off. Each unit has an enabled flag in `deploy/units.json`. A unit is included in a deployment only after someone sets that flag in a reviewed change. The first deployment of a unit is a decision.

Set every enabled flag to `false`, then show the seven lines so you can see the edit before you commit it.

```powershell
(Get-Content deploy\units.json -Raw) -replace '"enabled": true', '"enabled": false' | Set-Content deploy\units.json -NoNewline
```

```powershell
Select-String -Path deploy\units.json -Pattern '"enabled"'
```

The output shows seven lines with `false`.

Commit that change.

```powershell
git add deploy/units.json
```

```powershell
git commit -m "Disable every unit for the next demo"
```

> Now I'll push the code to GitHub. The workflows arrive with it. The pipeline switch, `MIRROR_PIPELINE_ENABLED`, is still off, so every job skips. Nothing can run while the folder is landing.

Push `master` to the test repository.

```powershell
git push test HEAD:master
```

The push prints the new commit range. On GitHub, the **Actions** tab shows a run of `mirror-validate` with every job skipped. `mirror-deploy-unit` shows no run, because it starts only with **Run workflow**.

> In production, IT pushes the folder into its own repository, and the ruleset on `master` requires a pull request for that too.

**Only if** the push is refused with `Repository rule violations found`, the ruleset `protect-master` requires a pull request. Push a branch instead, open the pull request, and follow the commands through the reset.

```powershell
git push test HEAD:refs/heads/sync-demo
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head sync-demo --title "Bring the demo up to date" --body "Bring the demo up to date"
```

The pull request body is only a description. The change ticket goes in the `changeRef` input of **Run workflow**, later. Approve the pull request as `klaudiomarashi`, then merge it. A squash merge is a new commit, so the local `master` has to be reset onto the merged commit. Without that reset, every later `git pull test master` stops because the branches have diverged.

```powershell
gh pr merge sync-demo --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git fetch test
```

```powershell
git switch master
```

```powershell
git reset --hard test/master
```

```powershell
git log --oneline -1
```

The log shows the squash commit. A refusal that names the token scope means `gh auth refresh -h github.com -s workflow`. A refusal that names the account means `gh auth switch --hostname github.com --user themasterishome`, then `gh auth setup-git`.

### 3. Turn the pipeline switch on (GUIDE.md step 3.20)

> Every job of every workflow starts with one condition, the repository variable `MIRROR_PIPELINE_ENABLED`. I call it the pipeline switch. While it is not `true`, every job skips. If something ever looks wrong, one change stops the whole pipeline.

Set the pipeline switch, then list the repository variables so you can see the value.

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

The list shows `MIRROR_PIPELINE_ENABLED` with the value `true`. Setting it starts no run by itself. In the browser the same variable is under **Settings** > **Secrets and variables** > **Actions** > **Variables**. A refusal means the active account is not `themasterishome`. Switch it as in step 1.

> In production, IT sets the same variable once the GitHub environments, the managed identities and the variables are in place and checked.

### 4. The first validate run (GUIDE.md step 3.21)

> The first thing I'll prove is the offline checks. I'll open a pull request that touches no unit, so nothing signs in to Azure.

Create a branch and make an empty change to `README.md`, so the pull request has a commit and touches no unit.

```powershell
git switch --create first-checks
```

```powershell
Add-Content -Path README.md -Value ''
```

```powershell
git commit --all --message "First run of the checks"
```

Push the branch and open the pull request.

```powershell
git push -u test first-checks
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head first-checks --title "First run of the checks" --body "First run of the checks"
```

Open the pull request in the browser and show the checks at the bottom of the **Conversation** tab.

> Five jobs run on every push and every pull request, and none of them calls Azure. `secret-scan` looks for passwords and keys in the code. `actionlint` checks that the workflow files are valid. `workflow-hygiene` checks the pipeline's own rules and runs its tests. `preflight` compiles every unit and checks the layout of the code. `portability` checks that the scripts behave the same on Windows and on Linux. A mistake caught here is caught before any job signs in to Azure.
>
> `mirror-pr` runs as well. It works out which units this change touches. This change touches none, so there is no what-if to run, and its check, `pr-gate`, passes.

After a few minutes the five jobs are green. `mirror-pr` shows the job `plan` and a green `pr-gate`, with no `whatif` job. The ruleset `protect-master` requires those five jobs plus `pr-gate`, six checks in all. If a job fails, open it and read its first error (GUIDE.md section 5). If `protect-master` does not list the six checks yet, add them as GUIDE.md step 3.21, item 3, shows.

Close the pull request without merging, and go back to `master`. Keep the branch. Step 5 starts a run from it.

```powershell
gh pr close first-checks --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

### 5. The first drift run (GUIDE.md step 3.22)

> Next I'll prove two things. The reader identity can sign in from GitHub, and the drift check can open an issue. Every unit is switched off, so the check has nothing to inspect. It stops on purpose, and that stop is itself reported.

Start `mirror-drift` from `master`.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

Open the run from **Actions** > **mirror-drift** when it ends. The `azure/login` step is green. "Drift sweep (read-only)" fails, and its last line starts with `STOP: no enabled unit to check in deploy/units.json`. The `report` job prints `Drift report: issue #N is opened (error).` The **Issues** tab holds the issue.

> The sign-in worked with no password, through the federated credential. And the result is an issue in the repository. The people who watch the repository get notified. A red run on its own is easy to miss. An issue is not.

Close the issue. With every unit disabled, no run is clean, so no run will close it for you. List the open issues, then replace `ISSUE_NUMBER` with the number the list prints.

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh issue close ISSUE_NUMBER --repo themasterishome/demo-bicep-deploy-test
```

> Now the branch rule. I'll start the same check from the other branch, the one from step 4.

```powershell
gh workflow run mirror-drift.yml --ref first-checks --repo themasterishome/demo-bicep-deploy-test
```

Wait about 30 seconds, then list the runs until the newest one has failed. This run should be refused by the GitHub environment before any step starts. In plain-text output the conclusion reads `failure`. In the console, that same result is a failure mark in the status column.

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

The run fails before any step, with `Branch "first-checks" is not allowed to deploy to mirror-reader-dispatch due to environment protection rules`, and the `report` job is skipped.

> GitHub refused the run before a single step ran. A copy of a workflow on another branch, an older one or a changed one, cannot use this GitHub environment. Only `master` can. The same rule guards every environment that deploys.

Delete the branch on the remote, then delete it locally.

```powershell
git push test --delete first-checks
```

```powershell
git branch --delete --force first-checks
```

A failed sign-in with `AADSTS70021` means the federated credential's subject does not match, or the credential is only a minute old. Wait a few minutes and run it again, or compare it with the read-back of GUIDE.md step 3.17. A `report` job that fails means Issues are off. Turn them on under **Settings** > **General** > **Features** and run it again. A `report` job that prints `is updated` instead of `is opened` means a drift issue was still open. Close it as Part 0 shows. If the run on `first-checks` signs in, `mirror-reader-dispatch` has no branch rule (GUIDE.md step 3.11).

### 6. A pull request and its preview (GUIDE.md section 4.2, items 1 and 2)

> Now a real change. Every change starts the same way: a branch, an edit, and a pull request. I'll turn on the pilot unit. It deploys an empty template into an empty resource group. It proves the sign-in, the roles, the approval and the evidence, and it creates no resource.

The demo's resource groups are created by hand once. This command is safe to run again. It makes sure `rg-demo-pilot`, `rg-demo-network` and `rg-demo-routing` exist before any preview looks for them.

```powershell
foreach ($g in 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') { az group create --name $g --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy --query properties.provisioningState -o tsv }
```

The output is `Succeeded` three times.

Create the branch, then edit the enabled flag by hand. The replace in step 2 was for every unit. This change is one unit, so the audience can see the line.

```powershell
git switch --create enable-pilot
```

Open `deploy/units.json` in an editor, set `"enabled": true` in the entry of `pilot-empty-rg` and save it.

Commit, push, and open the pull request.

```powershell
git commit --all --message "Enable the pilot unit"
```

```powershell
git push -u test enable-pilot
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-pilot --title "Enable the pilot unit" --body "Enable the pilot unit"
```

Show the pull request. `mirror-pr` has a job `whatif pilot-empty-rg`. Its comment shows the gate PASS and no records.

> This is the part reviewers like most. Before anyone merges, the pipeline previews the change against live Azure. Azure calls that preview a what-if. It reports what a deployment would do, and it writes nothing. The preview runs as the reader identity, which cannot write anything. The gate then judges every record of the preview. A record that would create, change or delete something nobody has named fails the gate. The reviewer reads what will really happen.

A `whatif` job that fails with `ResourceGroupNotFound` means `rg-demo-pilot` is missing. Run the first command of this step again. A refused push means the token lacks the `workflow` scope, or the active account is wrong (step 1).

### 7. Approve and merge, and see that the merge starts nothing (GUIDE.md section 4.2, items 3 and 4)

In the private window, as `klaudiomarashi`, open the pull request, select **Files changed**, then **Review changes**, **Approve** and **Submit review**.

> The second person approves the code. Now I'll merge it.

Squash-merge the pull request, update local `master`, then list deploy runs. The list is how you show that the merge started nothing.

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

No run of `mirror-deploy-unit` began at the merge.

> Merging deployed nothing. That is on purpose. A deployment needs a change ticket, a reason, and a reviewer for that exact moment. A merge has none of those. The merge puts the code on `master`. The deployment is a separate step, and someone has to start it.

GitHub refuses the merge while a required check is still running, or while the branch is not up to date. Wait for the checks, or select **Update branch**. If you are running alone, follow GUIDE.md section 3.0 and merge your own pull request. With the two accounts, `klaudiomarashi` approves first. If a run did start, open it and read its trigger. `mirror-deploy-unit.yml` starts only from `workflow_dispatch`, which is **Run workflow**.

### 8. A plan only (GUIDE.md section 4.2, item 11)

> Before I deploy, I'll ask the pipeline for a plan. It is the same what-if, taken from `master`, and it deploys nothing. It is the safe way to see exactly what a deployment would do.

Start `mirror-deploy-unit` with `apply` left off. The change ticket is `DEMO-0003`.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot, plan only" --repo themasterishome/demo-bicep-deploy-test
```

Open the run "Deploy pilot-empty-rg (DEMO-0003)". The jobs `select`, `plan pilot-empty-rg` and `collect` run. The summary shows "Gate PASS, approvable" and ends with "This run was started as a plan only (apply is off). Nothing waits for a reviewer."

> The run carries the change ticket and the reason, so anyone can see later why it ran. `select` checks the inputs. `plan` takes the what-if as the reader identity. `collect` sorts the plan into the right tier. Nothing waits, and nothing deploys.

A run that fails in `select` names the input it refused, such as a unit whose enabled flag is still `false`. Enable the unit (step 6) and start again. The same run can be started in the browser with **Actions** > **mirror-deploy-unit** > **Run workflow**. Keep `master`, and leave `apply` unticked.

### 9. Deploy the pilot, with an approval (GUIDE.md section 4.2, items 5 to 9)

> Now the deployment itself, with `apply` on. Apply means: after a reviewer approves the plan, deploy it.

Start the same unit again, this time with `-f apply=true`.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Open the run. After `plan pilot-empty-rg` and `collect`, the job `apply pilot-empty-rg` shows **Waiting** for the GitHub environment `mirror-production-demo`. Show that waiting job in your own window first.

> The deployment has stopped, and it is waiting for a reviewer. I started this run, so GitHub does not let me approve it. That is Prevent self-review. The reviewer reads the plan, the same records we saw in the plan-only run, and approves with a comment that names the ticket.

Do not select **Start all waiting jobs**. That is the administrator bypass, and it would approve the run as the person who started it. **Review deployments** shows nothing to tick on an old or finished run, so stay on the newest one.

In the private window, open the run, select **Review deployments**, tick `mirror-production-demo`, write a comment that names `DEMO-0003` and select **Approve and deploy**. Then watch the run until it finishes.

```powershell
gh run list --workflow mirror-deploy-unit.yml --limit 1 --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh run watch RUN_ID --repo themasterishome/demo-bicep-deploy-test
```

Replace `RUN_ID` with the long number in the `ID` column. That is the run ID, the same number after `/actions/runs/` in the run's address. The `#N` on the run title is a different number, and the first column is the status, not the ID. The summary ends with `Gate step exit: 0, deployed, and the second check passed.` The run keeps the artifacts `reviewed-plan-pilot-empty-rg` and `evidence-deploy-pilot-empty-rg`.

> After the approval, the apply job checks that `master` has not moved and that the plan is less than a day old. It signs in as the deploy identity, takes a fresh what-if, and compares it with the plan that was approved. That comparison is the first check. It deploys only when they match. Then it takes another what-if, the second check, which has to show nothing left to change. If anything differs at any of these points, the job stops.

> In production, the reviewer is anyone in the approvers team except the person who started the run, and the comment names IT's change ticket.

An apply that runs at once, with no pause, means the GitHub environment has no required reviewer (GUIDE.md step 3.11). Read a failed apply in "Reading a failed run" at the end.

### 10. Download the evidence (GUIDE.md section 4.2, item 10)

> Every deployment leaves evidence. In production this goes on the change ticket.

List the artifacts of the run you just watched. You need the ID and the name of `evidence-deploy-pilot-empty-rg`.

```powershell
gh api "repos/themasterishome/demo-bicep-deploy-test/actions/runs/RUN_ID/artifacts" --jq ".artifacts[] | [.id, .name] | @tsv"
```

Use that run ID, and the artifact ID and name from this list, in the next commands.

Create a folder for the download, fetch the zip through the API, and unpack it with Python. `gh run download` fails on these artifacts on Windows, because the zip holds the same entry twice. The `cmd /c` keeps Windows PowerShell 5.1 from changing the bytes of the zip.

```powershell
New-Item -ItemType Directory -Force C:\demo-setup\evidence-pilot | Out-Null
```

```powershell
cmd /c "gh api repos/themasterishome/demo-bicep-deploy-test/actions/artifacts/ARTIFACT_ID/zip > C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip"
```

```powershell
python -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip C:\demo-setup\evidence-pilot\ARTIFACT_NAME
```

Find the two files the audience should see.

```powershell
Get-ChildItem -Path C:\demo-setup\evidence-pilot -Recurse -Include approval.txt, post-summary.txt | Select-Object -ExpandProperty FullName
```

The last command prints the paths of `approval.txt`, which has a `deployed=` line, and `post-summary.txt`, which says Gate PASS.

> `approval.txt` records who ran it, which run, which options, and that it deployed. `post-summary.txt` is the second check. Together they show what was planned, what was approved, and what Azure ended up with.

### 11. Wave 1, the network (GUIDE.md section 4.3)

A wave is the next unit in the deploy order. Wave 0 was the pilot. Wave 1 creates the network.

> Now real resources. The network unit creates a network security group, a virtual network, a private endpoint and its DNS, plus a lock, a policy assignment and a Reader role assignment on the group. I'll enable this unit, and the routing unit with it, in one pull request. Routing comes after the network, so it waits until this wave has finished.

Create the branch, enable both units, and open the pull request.

```powershell
git switch --create enable-waves
```

Open `deploy/units.json`, set `"enabled": true` in the entries of `rg-demo-network` and `rg-demo-routing` and save it.

```powershell
git commit --all --message "Enable the network and routing units"
```

```powershell
git push -u test enable-waves
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-waves --title "Enable the network and routing units" --body "Enable the network and routing units"
```

Show the preview comment. Approve the pull request as `klaudiomarashi`, the same clicks as step 7, then merge it and update local `master`.

```powershell
gh pr merge enable-waves --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

> The merge started nothing, same as before. I'll ask for a plan.

Start a plan-only run so the summary can hand you the resource IDs. Two of those IDs contain GUIDs that Bicep generates, so copy them from the summary. Do not type them from memory.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

Open that run. The plan is red, and its summary gives the ready command with the nine resource IDs.

> The plan is red because it would create nine resources, and nobody has agreed to those creates yet. The gate does not let a Create through on its own. The person who starts the deployment has to name every resource that will be created, by its full resource ID, in an input called `allowCreate`. The reviewer sees that list. A resource the code would create that is not on the list stops the run.

Copy the ready command from the summary. Replace `<ticket>` with `DEMO-0004` and `<why>` with `Wave 1, create the network`, add `--repo themasterishome/demo-bicep-deploy-test`, and run it. It has this shape. GUIDE.md section 4.3, item 5, lists the nine IDs.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, create the network" -f apply=true -f allowCreate="ID1,ID2,ID3,ID4,ID5,ID6,ID7,ID8,ID9" --repo themasterishome/demo-bicep-deploy-test
```

Nine is the count in an empty group. If the lock, the policy assignment or the role assignment is live already, the ready command lists fewer. Approve the waiting apply as in step 9, with a comment that names `DEMO-0004`.

The plan shows the verdict approvable and nine Create records. After the approval, the second check ends with `NoChange=8`, one `Ignore` and one `Modify`, and the summary ends with `Gate step exit: 0, deployed, and the second check passed.` The Ignore is the network interface Azure creates for the private endpoint. The Modify is provider-set fields on the endpoint's zone group. `deploy/boundaries.json` lists both, so the gate passes them. If you are asked: the second check is judged without the `allowCreate` list, so a resource that was not created as the code says fails here.

In the portal, `rg-demo-network` holds `nsg-demo` and `vnet-demo`. The lock `lock-rg-demo-network` shows under **Locks**.

> The second check is a fresh what-if, and it does not get the list of allowed creates. So this pass means each resource was created as the code describes.

Download the evidence as in step 10, with `evidence-deploy-rg-demo-network`. If the resources exist already, the plan shows NoChange and passes with no `allowCreate`, and the apply still waits for the reviewer. A red plan with exit code 2 names a setup problem (GUIDE.md section 5).

### 12. Wave 2, the routing (GUIDE.md section 4.4)

> The routing unit was enabled in the same pull request, so it needs no new one. It comes second in the order, so it deploys after the network has finished. It also holds an Automation account with a credential. The password for that credential lives in a Key Vault. No file in the repository holds that password.

Start this only after the run of step 11 has finished. Ask for the plan first, so you can read the Create records before anyone approves a deployment.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

In an empty group the plan is red with four Creates: `rt-demo`, `asg-demo`, the Automation account `aa-demo-secrets` and its credential `demo-cred`. Copy the ready command, replace `<ticket>` with `DEMO-0005` and `<why>` with `Wave 2, create the routing`, add `--repo themasterishome/demo-bicep-deploy-test` and run it. It has this shape.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, create the routing" -f apply=true -f allowCreate="/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/applicationSecurityGroups/asg-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets/credentials/demo-cred" --repo themasterishome/demo-bicep-deploy-test
```

If the resources exist already, the plan is green with no Create and the deployment needs no `allowCreate`. Approve the waiting apply as in step 9, with a comment that names `DEMO-0005`.

The second check shows `rt-demo`, `asg-demo`, `aa-demo-secrets` and `demo-cred` as NoChange.

> The deployment read the password from the vault at the moment it ran, through the `az.getSecret` function in the parameters file. The evidence shows `<secure input, not recorded>` in its place. The password is in no log and in no file.

> In production, the same vault pattern holds the VPN shared keys. IT loads them into the vault once, and the code reads them at deployment.

Show that a second deployment of the same code changes nothing. This run has no `allowCreate`, because the plan should hold no Create.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, the second deployment of the same commit" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Approve it as in step 9. The plan, the first check and the second check all show `NoChange=4`, and the gate step exits 0.

> This is the proof that the code is a true mirror of what is live. Deploying the same commit again finds nothing to change. That is what we aim for with every unit in production.

A failure that names the vault means the deploy identity lacks the role Mirror Key Vault Deployment on that vault (GUIDE.md step 3.15). GUIDE.md section 4.4 explains the proof.

### 13. Wave 4, the privileged unit (GUIDE.md section 4.5)

This demo has no wave 3. `demo-subscription` stays disabled, on purpose. The next unit is wave 4.

> Some resources control access, such as an Owner role assignment or a custom role. Those live in a privileged unit, with their own managed identity and their own GitHub environment. An identity that can both create resources and grant access is, in effect, Owner of the subscription. So the deploy identity cannot grant Owner. Access changes go through a second door.

Create the branch, enable `demo-privileged`, and open the pull request.

```powershell
git switch --create enable-privileged
```

Open `deploy/units.json`, set `"enabled": true` in the entry of `demo-privileged` and save it.

```powershell
git commit --all --message "Enable the privileged unit"
```

```powershell
git push -u test enable-privileged
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-privileged --title "Enable the privileged unit" --body "Enable the privileged unit"
```

Approve the pull request as `klaudiomarashi` and merge it. As in step 7, the merge puts the code on `master` and starts no deployment. Update local `master`.

```powershell
gh pr merge enable-privileged --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

Ask for the plan. The summary's ready command is where the two resource IDs come from.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

The plan's ready command lists two IDs: the Owner role assignment on `rg-demo-network`, and the role definition `Demo Reader Plus`. Copy it, replace `<ticket>` with `DEMO-0006` and `<why>` with `Wave 4, the privileged unit`, add `--repo themasterishome/demo-bicep-deploy-test` and run it. It has this shape.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, the privileged unit" -f apply=true -f allowCreate="ID1,ID2" --repo themasterishome/demo-bicep-deploy-test
```

The job that waits is `apply privileged demo-privileged`. It is not named `apply demo-privileged`. It waits in the GitHub environment `mirror-privileged-demo`, and it deploys as the govern identity `id-mirror-govern-demo`. The second check ends with `NoChange=2`.

> This run is waiting in a different GitHub environment. The tier of the unit decided that. The person who started the run did not pick it. Before approving, the reviewer checks that every role assignment is named, and that nobody gains Owner beyond what the ticket says.

> In production, a smaller team approves the privileged environments. That team is the people who may change who has access to what. In the demo, the same second account approves both tiers, because a personal account has no teams.

Approve it in `mirror-privileged-demo` as `klaudiomarashi`, with a comment that names `DEMO-0006`. A production unit that declares an Owner assignment fails the `preflight` job of `mirror-validate`. That is the other half of the same rule: the code is refused before anyone can deploy it from the ordinary tier.

### 14. Wave 5, the management group (GUIDE.md section 4.6)

> Not everything lives in a subscription. Management groups sit above the subscriptions, so their units deploy at tenant level, with a managed identity of their own.

Create the branch, enable `demo-tenant-management-group`, and open the pull request.

```powershell
git switch --create enable-tenant-mg
```

Open `deploy/units.json`, set `"enabled": true` in the entry of `demo-tenant-management-group` and save it.

```powershell
git commit --all --message "Enable the management group unit"
```

```powershell
git push -u test enable-tenant-mg
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-mg --title "Enable the management group unit" --body "Enable the management group unit"
```

Approve the pull request as `klaudiomarashi` and merge it, then update local `master`. The merge starts no deployment.

```powershell
gh pr merge enable-tenant-mg --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

> A what-if cannot run for a management group that does not exist yet. So `mg-demo` was created once by hand, and this unit finds it as it already is. The plan holds no Create, so the deployment needs no `allowCreate`.

Start the deployment directly. There is no plan-only run in this step, because the pull request preview already showed no Create.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-management-group -f changeRef=DEMO-0007 -f reason="Wave 5, the management group" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting job `apply privileged demo-tenant-management-group` in the GitHub environment `mirror-privileged-tenant`, as `klaudiomarashi`, with a comment that names `DEMO-0007`. The apply signs in as `id-mirror-govern-tenant`. The second check passes with `NoChange=1`.

> In production, the management group above the subscriptions is found the same way. The tenant units deploy with the tenant govern identity, after the privileged team's approval.

`AuthorizationFailed` on a tenant unit means the reader identity lacks Reader, or lacks Mirror What-If Reader Tenant, on the Tenant Root Group (GUIDE.md step 3.14, item 3).

### 15. Wave 6, the Reader role assignment on the management group (GUIDE.md section 4.7)

> The last unit gives the reader identity the Reader role on the management group. It has its own pull request, so each tenant unit has its own preview and its own approval.

Create the branch, enable `demo-tenant-governance`, and open the pull request.

```powershell
git switch --create enable-tenant-governance
```

Open `deploy/units.json`, set `"enabled": true` in the entry of `demo-tenant-governance` and save it.

```powershell
git commit --all --message "Enable the management group governance unit"
```

```powershell
git push -u test enable-tenant-governance
```

```powershell
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-governance --title "Enable the management group governance unit" --body "Enable the management group governance unit"
```

Approve the pull request as `klaudiomarashi` and merge it, then update local `master`.

```powershell
gh pr merge enable-tenant-governance --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
```

```powershell
git switch master
```

```powershell
git pull test master
```

Ask for the plan. You need the resource ID of the Reader role assignment from the ready command. The plan of a tenant unit needs `mg-demo` to exist, which is why step 14 comes first.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

The ready command lists the ID of the Reader role assignment on `mg-demo`. Copy it, replace `<ticket>` with `DEMO-0008` and `<why>` with `Wave 6, Reader on the management group`, add `--repo themasterishome/demo-bicep-deploy-test` and run it. It has this shape.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, Reader on the management group" -f apply=true -f allowCreate=ID --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting job `apply privileged demo-tenant-governance` in `mirror-privileged-tenant`, as `klaudiomarashi`, with a comment that names `DEMO-0008`. The plan holds one Create. The second check passes with `NoChange=1`.

### 16. The drift check and the drift issue (GUIDE.md section 4.9)

> Everything we deployed matches the code. People still have the portal. If someone changes a resource by hand, live Azure and the code drift apart. The drift check finds that. It runs a what-if of every enabled unit, read-only, and keeps one GitHub issue up to date with what it found.

Wait for each run to finish before the next action. A drift run started while another one is still waiting replaces the waiting one. This command shows the state of the recent drift runs. Use it before every start in this step.

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

Action 1. Run the check while everything matches the code.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The run is green. The `report` job prints `Drift report: every checked unit is clean, and no drift issue is open.`

Action 2. Make a change in the portal, outside the code. In the Azure portal, search for **Route tables**, select `rt-demo`, select **Tags**, add the name `changedBy` with the value `portal` and select **Apply**.

> I just did what happens in real life. Someone fixed something in the portal, outside the code.

Action 3. Run the check again, so it can see the tag.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The run is red. `rg-demo-routing` is `DRIFT`, with a Modify on `rt-demo` that removes the tag `changedBy`. The `report` job prints `Drift report: issue #N is opened (drift).`

Action 4. Open the **Issues** tab and show the issue. It lists `rg-demo-routing` and links the run.

> The check changed nothing in Azure. It only reports. The issue is the alert. The people who watch the repository are notified when it opens, and the issue says which unit drifted and links the evidence.

Action 5. Run it a third time, with no further change, to show what a repeat finding does.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The `report` job prints `Drift report: issue #N is updated with this run, and its findings are the same (drift).` It adds no comment.

> The findings are the same, so it updates the run link and stays quiet. Nobody gets the same alert every week.

Action 6. Repair the drift by deploying the value that is in the code. A change to a resource that already exists has to be named too, this time with `allowModify`. Approve the run as `klaudiomarashi` and wait for it to finish.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0010 -f reason="Undo the drift on rt-demo" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo --repo themasterishome/demo-bicep-deploy-test
```

> The repair is an ordinary deployment, with a ticket and an approval. If the portal change had been the right one, we would bring it into the code with a pull request instead of deploying over it.

Action 7. Run the check once more. This run should find every unit clean and close the issue.

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

The run is green. The `report` job prints `Drift report: every checked unit is clean, so issue #N is closed.` The issue is closed with a comment.

> When everything is clean again, the issue closes itself.

A run that lists `demo-subscription` as `DRIFT`, with NoRecord lines, means that unit is enabled. The subscription holds resource groups that are not part of the demo, such as WinServ2022, Automation, coach01 to coach29 and consultant01 to consultant13. Leave them alone, and keep `demo-subscription` disabled. A drift run that reports another resource group the code does not declare means the subscription holds another group. The summary names it. A `report` job that fails means Issues are off. `klaudiomarashi` is notified only when that account watches the repository.

### 17. Turn on the weekly drift run

> The check can also start by itself, every Monday at 05:00 UTC. It has its own switch, `MIRROR_DRIFT_SCHEDULE_ENABLED`, so it starts only when the team is ready to act on what it finds.

Set the weekly drift switch only when at least one unit is enabled. A run with every unit disabled fails on purpose, which is what step 5 showed.

```powershell
gh variable set MIRROR_DRIFT_SCHEDULE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
```

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

The list shows `MIRROR_DRIFT_SCHEDULE_ENABLED` with the value `true`. The next Monday, the runs of `mirror-drift` include one whose event is `schedule`. The demo does not wait for that Monday. **Run workflow** runs the same two jobs.

> In production, the weekly start stays off until IT is ready for it, and then IT sets the same variable. GitHub tells only the last person who edited the schedule about a failed scheduled run. That is one more reason the result is an issue, which everyone watching the repository can see.

A weekly run that skipped every job means this variable is not `true`, or the pipeline switch is off.

### 18. A change after the baseline, and a rollback (optional, GUIDE.md sections 4.8 and 4.10)

> Once a unit mirrors what is live, every later change is a normal pull request. If a change turns out wrong, the rollback is the same route in reverse: a revert in git, a what-if, an approval, and a deployment.

Follow GUIDE.md section 4.8 and then 4.10. The merge of each pull request starts no run. The resource IDs for `allowModify` are in the preview's comment. The second check ends with `NoChange=2` after the rule is added, and `nsg-demo` is NoChange again after the rollback. GUIDE.md section 5 lists the causes when something fails.

## The closing

> To sum up. Every change is code, reviewed in a pull request that carries a real what-if. A deployment happens only when a person starts it, a second person approves that exact plan, and a second check passes afterwards. The pipeline signs in with federated credentials, and no stored secret. The identities that write can sign in from `master` only. A change to who has access goes through the privileged tier, which is a separate door. And every week the drift check looks for a difference between live Azure and the code, and tells us when it finds one.

## Turning the demo off

Set the pipeline switch to `false`, so every job of every workflow skips.

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body false --repo themasterishome/demo-bicep-deploy-test
```

Delete the weekly drift switch. If you only turn the pipeline switch off, this variable is still `true`, and the Monday run starts the next time the pipeline switch is turned on.

```powershell
gh variable delete MIRROR_DRIFT_SCHEDULE_ENABLED --repo themasterishome/demo-bicep-deploy-test
```

See whether a drift issue is still open. Close it if the list prints one, the same way as in Part 0.

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
```

Switch the GitHub CLI back to `klaudiomarashi`.

```powershell
gh auth switch --hostname github.com --user klaudiomarashi
```

Point Azure CLI back at the subscription you use day to day. Replace `SUBSCRIPTION_ID` with that subscription's ID. The demo resources stay until GUIDE.md section 6 removes them.

```powershell
az account set --subscription SUBSCRIPTION_ID
```

## Reading a failed run

1. On GitHub, open **Actions**, then **mirror-deploy-unit**, then the run, then the apply job. The gate step's log prints its exit code and the last lines of the deploy script. The codes are 0 for deployed and checked, 1 for refused by the gate, 2 for a setup or identity problem, and 3 for a deployment that ran and failed, or whose second check failed. The job summary holds the plan verdict. The artifacts `evidence-deploy-UNIT` and `reviewed-plan-UNIT` hold the what-if results as JSON.
2. In Azure, open the deployment record `mirror-UNIT-COMMIT`. In the portal, that is the subscription or the resource group, then **Deployments**, then the failed record, then **Operation details**. That page names the resource and the error code. From the CLI, use the first command for a subscription unit and the second for a resource group unit. Replace `UNIT`, `COMMIT` and `RESOURCE_GROUP` from the run.

   ```powershell
   az deployment sub show --name mirror-UNIT-COMMIT --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.error
   ```

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
