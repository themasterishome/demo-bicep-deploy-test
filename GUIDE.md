# Set up and run the demo

This guide sets up the demo repository `themasterishome/demo-bicep-deploy` from nothing and runs it in front of an audience. It follows PIPELINE.md of the project step by step, with the same step numbers, so the people watching see the same process the project goes through. Only the estate is small, made up and free.

Contents:
1. [What the demo is](#1-what-the-demo-is)
2. [Prerequisites and sign-ins](#2-prerequisites-and-sign-ins)
3. [Set up once](#3-set-up-once)
4. [The demo run](#4-the-demo-run)
5. [What can go wrong](#5-what-can-go-wrong)
6. [Clean up](#6-clean-up)

## 1. What the demo is

The repository holds the project's four workflows, the helper script `.github/scripts/mirror-pipeline.ps1`, the gate script `scripts/deploy-unit.ps1` and the preflight, unchanged in what they do. The estate is three units in the Visual Studio subscription. A merge plans a unit and deploys nothing. **Run workflow** deploys it, and only after a reviewer who did not start the run reads the plan and approves it in GitHub. The deploy identity then takes a fresh preview, deploys and takes the second check, and the run keeps the evidence.

The scripts, the workflows and their comments are the production ones with only the names changed, so some comments speak of a team, IT or more subscriptions.

The units, in the order they deploy:

| Wave | Unit | Resource group | What it deploys |
|---|---|---|---|
| 0 | `pilot-empty-rg` | `rg-demo-pilot` | An empty template. It proves the identities, the approval, the gate and the evidence without touching a resource. |
| 1 | `rg-demo-network` | `rg-demo-network` | The network security group `nsg-demo`, the virtual network `vnet-demo` (10.250.0.0/24) and its subnet `snet-default` (10.250.0.0/26), linked to that network security group. |
| 2 | `rg-demo-routing` | `rg-demo-routing` | The route table `rt-demo` with no routes and the application security group `asg-demo`. |
| none | `demo-subscription` | none | The three resource groups, declared in `infra/subscriptions/demo/main.bicep`. It carries `"route": "hand"`, so the pipeline never deploys it. It stays disabled. |

Every resource the demo creates is free. That covers the resource groups, the virtual network and subnet, the network security group, the route table, the application security group, the two managed identities and their federated credentials, the custom role, the role assignments, the lock and the policy assignment. Standard GitHub-hosted runners and artifact storage are free in a public repository.

### Demo and project side by side

| Item | Demo | Project |
|---|---|---|
| Tenant | `d1a349ef-6ac8-4588-a88d-5dab272c700b`, the personal tenant | The production tenant |
| Subscriptions | One, the Visual Studio Enterprise Subscription `77488719-1168-4d53-af9a-f5c3bc9291d7`, folder `demo` | Eleven, plus a separate subscription for the identities |
| Where the identities live | `rg-demo-identities`, in the same subscription the units deploy to | A subscription outside the 11, where no pipeline identity holds a role |
| Repository | `themasterishome/demo-bicep-deploy`, public, personal account | A private repository in a GitHub Enterprise Cloud organization |
| GitHub plan | Free. Every environment control works on Free for a public repository | Enterprise Cloud, which a private repository needs for required reviewers |
| Reviewers | You and a second GitHub account, as users, with Prevent self-review on | An approvers team, with Prevent self-review on |
| Code owners | `@themasterishome`, plus the second account | The approvers team |
| Units | 3 pipeline units and 1 by-hand unit | 32 pipeline units and 25 by-hand units |
| Rulesets | `protect-master` and `protect-tags` | `protect-master`, `protect-github-folder` and `protect-tags`, next to the organization ruleset |
| Retention | 90 days, the longest for a public repository | 365 days |
| Change tickets | Made-up numbers such as `DEMO-0001` | IT's change tickets |

What stays identical:
- the four workflows `mirror-validate`, `mirror-pr`, `mirror-deploy-unit` and `mirror-drift`, with their jobs, inputs and required checks
- the helper script and its checks (Select, InputCheck, CheckApply, ComparePlan and the others), and the gate script with its exit codes
- the switch `MIRROR_PIPELINE_ENABLED`, the variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` per environment, and the optional `MIRROR_RUNNER` and `MIRROR_MAX_PLAN_AGE_HOURS`
- the environment names `mirror-reader`, `mirror-reader-dispatch` and `mirror-production-<folder>`, which here is `mirror-production-demo`, with the branch rule `master`
- the two identities and their roles. The reader `id-mirror-reader` holds Reader and Mirror What-If Reader. The deploy identity `id-mirror-deploy-demo` holds Contributor on its subscription and nothing under `Microsoft.Authorization`
- the OpenID Connect subjects, in the form `repo:OWNER@OWNER_ID/REPOSITORY@REPOSITORY_ID:environment:ENVIRONMENT`, and the trusted-owners policy on the identity group
- the flow, which is a code pull request with a preview, a merge that plans, Run workflow with the options, the approval, the apply, the second check, the evidence and the drift check

What the demo cannot show:
- a team as reviewer and as code owner, because a personal account has no teams
- the organization settings, which are the organization ruleset, the restriction on forking, the two-factor requirement, the organization owners and the audit log
- the push ruleset `protect-github-folder` (project step 3.8), because push rulesets exist only for private and internal repositories
- the enterprise issuer of step 3.16, item 3
- PIM, because the demo needs no eligible roles, and Owner on the Visual Studio subscription does the set-up
- identities in a subscription of their own. Here the deploy identity's Contributor reaches the identity group too, which is the risk project step 3.12 avoids
- the custom roles Mirror Budget Writer and Mirror Network Peering, which the demo units do not need
- the security alerts of step 3.24, which the demo leaves out
- a private repository. In a public repository anyone can read the runs, the plans and the evidence. The demo estate is made up, so this is safe

The sweep scripts `scripts/whatif-rg-sweep.sh` and `scripts/whatif-sub-sweep.sh` carry a made-up subscription ID and are not part of the demo. The pipeline does not use them.

## 2. Prerequisites and sign-ins

You need these tools on the workstation.

| Tool | Version | Check |
|---|---|---|
| Azure CLI | 2.76 or later | `az version` |
| Bicep CLI | 0.48.1, the version the workflows pin and `deploy-unit.ps1` requires. Only needed to run the preflight or the gate script locally, because every job installs its own | `az bicep version` |
| GitHub CLI | 2.48 or later | `gh --version` |
| Git | 2.28 or later | `git --version` |
| Windows PowerShell | 5.1, for every command in this guide | `$PSVersionTable.PSVersion` |
| PowerShell 7 | 7.4 or later, optional, to run the helper tests locally as the runners do | `pwsh --version` |

To install the pinned Bicep CLI, run `az bicep install --version v0.48.1`.

Run every command in a Windows PowerShell window, never in Git Bash. Git Bash rewrites any argument that starts with `/subscriptions/` into a Windows path, and the command then fails or is refused (section 5).

You also need:
- Owner on the Visual Studio subscription, for the custom role, the role assignments, the lock and the policy assignment
- the GitHub account `themasterishome`
- a second GitHub account, to show the approval and Prevent self-review as the project has them. If you have none, follow [section 3.0](#30-if-you-run-the-demo-alone) instead

### Sign in to Azure

1. Sign in to the personal tenant.

   ```powershell
   az login --tenant d1a349ef-6ac8-4588-a88d-5dab272c700b
   ```

2. Make the Visual Studio subscription the Azure CLI's default. Do this first, because the `az policy assignment` commands of steps 3.12 and 3.17 use the sign-in of the default subscription, whatever subscription their `--scope` names. With the default in another tenant, Azure refuses them with `InvalidAuthenticationTokenTenant`.

   ```powershell
   az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   az account show --query "{name:name, tenantId:tenantId, user:user.name}" -o json
   ```

   The output names the Visual Studio Enterprise Subscription, the tenant `d1a349ef-6ac8-4588-a88d-5dab272c700b` and your account. The default stays until you change it, in every window. Section 6 sets it back.

### Sign in to GitHub

1. Check the signed-in account and its token scopes.

   ```powershell
   gh auth status
   ```

   The active account is `themasterishome`, with the scopes `repo` and `workflow` among them. The `workflow` scope is needed to push the files under `.github/workflows`. If it is missing, run `gh auth refresh -h github.com -s workflow`.

2. If more than one account is signed in, make `themasterishome` the active one.

   ```powershell
   gh auth switch --hostname github.com --user themasterishome
   ```

3. Let git use the GitHub CLI's sign-in for the push of step 3.5.

   ```powershell
   gh auth setup-git
   ```

Every `gh` command in this guide runs as `themasterishome`. The second account works in the browser only, so open a private browser window and sign it in there.

## 3. Set up once

Do the steps in order, because each one needs the steps before it. Each step has the number it has in PIPELINE.md section 3, so you can show the project step next to the demo step. Every Azure command names `--subscription 77488719-1168-4d53-af9a-f5c3bc9291d7`, apart from the `az policy assignment` commands and `az role definition list` and `delete`. Those take `--scope` and rely on the default subscription set in section 2.

The placeholders used in this section:
- `SECOND_LOGIN` is the second GitHub account's login.
- `SECOND_ID` is that account's numeric user ID, from step 3.2.
- `REPOSITORY_ID` is the repository's numeric ID, from step 3.3.
- `WHATIF_ROLE_ID` is the ID of the custom role, from step 3.13.
- `READER_CLIENT`, `READER_PRINCIPAL`, `DEPLOY_CLIENT` and `DEPLOY_PRINCIPAL` are the `clientId` and `principalId` of the two identities, from steps 3.14 and 3.15.

The owner ID of `themasterishome` is `49098959`. Step 3.2 reads it again, so you can show where it comes from.

### 3.0 If you run the demo alone

With one account, nobody can approve what that account started while Prevent self-review is on. The apply job would wait and fail after 30 days. A pull request author cannot approve their own pull request either. So the one-account demo changes three settings, and shows Prevent self-review only by explaining it:
- Step 3.4 leaves CODEOWNERS as it is.
- Step 3.7 sets **Required approvals** to 0 and leaves **Require review from Code Owners** off. A pull request is still required, and so are the six checks.
- Step 3.11 lists only you as reviewer of `mirror-production-demo`, with Prevent self-review off. You then start every run and approve it yourself.

Skip every item that says to approve the pull request as the second account (4.2 item 3, 4.3 item 3, 4.5 item 3 and 4.7 item 2), and merge the pull request yourself. Where an item says to approve a deployment as the second account, you approve it yourself.

Everything else is the same. An earlier run of these steps used exactly this variant.

### 3.1 Check the plan

The project checks that the organization is on Enterprise Cloud. The demo needs no paid plan, because GitHub offers environments, required reviewers, Prevent self-review, deployment branch rules, rulesets and code owners on Free for a public repository.

```powershell
gh api user --jq "{login: .login, plan: .plan.name}"
```

The output names `themasterishome` and its plan, for example `free`. Any plan works for a public repository.

### 3.2 Check the approvers

The project checks that the approvers team has at least two IT people. The demo's approvers are two users.

1. Read the numeric IDs of both accounts. The environments and the policy need them.

   ```powershell
   gh api users/themasterishome --jq .id
   gh api users/SECOND_LOGIN --jq .id
   ```

   Replace `SECOND_LOGIN` with the second account's login. The first command prints `49098959`. Keep the second number as `SECOND_ID`.

2. Check that you know who will act as which person in the demo. You, `themasterishome`, write the code, merge and start every run. The second account reviews pull requests and approves deployments.

### 3.3 Create the repository

1. Create an empty public repository, with no README, license or `.gitignore`, so the first push is not refused.

   ```powershell
   gh repo create themasterishome/demo-bicep-deploy --public
   ```

   The output ends with `https://github.com/themasterishome/demo-bicep-deploy`. The project creates a private repository in the organization.

2. Invite the second account as a collaborator. In the repository, open **Settings** > **Collaborators** (under **Access**) > **Add people**, type `SECOND_LOGIN`, and select **Add SECOND_LOGIN to this repository**. Then accept the invitation in the private browser window. A collaborator on a personal repository has write access, which a code owner and a pull request reviewer need. The project gives the approvers team write access instead.

3. Project items 3 and 4 (forking off, two-factor requirement) are organization settings. A personal account has neither. Forks of a public repository cannot be switched off, so step 3.6 limits what a fork's pull request can run.

Check the repository and keep its ID.

```powershell
gh api repos/themasterishome/demo-bicep-deploy --jq "{private: .private, id: .id, owner_id: .owner.id}"
```

The output is a line like `{"id":123456789,"owner_id":49098959,"private":false}`. Keep `id` as `REPOSITORY_ID`. Step 3.16 needs it.

After the invitation is accepted, check who holds which access.

```powershell
gh api repos/themasterishome/demo-bicep-deploy/collaborators --jq ".[] | {login: .login, admin: .permissions.admin, push: .permissions.push}"
```

The output lists `themasterishome` with `admin` true and `SECOND_LOGIN` with `push` true and `admin` false.

### 3.4 Fill in CODEOWNERS

Fill it in before the first push. `.github/CODEOWNERS` names `@themasterishome` on every line. Add the second account on every line too, so its approval counts as a code owner's review. GitHub accepts an approval from any one of the code owners of a path. Skip this step if you run the demo alone.

In a PowerShell window at the root of the demo-bicep-deploy folder, change the file and commit it.

```powershell
(Get-Content .github\CODEOWNERS -Raw).Replace('@themasterishome', '@themasterishome @SECOND_LOGIN') | Set-Content .github\CODEOWNERS -NoNewline
git add .github/CODEOWNERS
git commit -m "Name the second reviewer as a code owner"
```

Replace `SECOND_LOGIN` with the second account's login. Then check the file.

```powershell
Select-String -Path .github\CODEOWNERS -Pattern '@\S+' -AllMatches | ForEach-Object { $_.Matches.Value } | Sort-Object -Unique
```

The output is two lines, `@SECOND_LOGIN` and `@themasterishome`.

### 3.5 Push the folder

1. Push the local `master` to the new repository. The push carries every local commit, this guide among them.

   ```powershell
   git remote add origin https://github.com/themasterishome/demo-bicep-deploy.git
   git push -u origin master
   ```

2. Check that the remote has the branch.

   ```powershell
   git ls-remote origin master
   ```

   The output is one line, the commit ID then `refs/heads/master`.

3. Check the default branch. An empty repository takes its default branch name from your personal setting, which is `main` unless you changed it under your profile's **Settings** > **Repositories**. It can still show `main` after the push of `master`.

   ```powershell
   gh api repos/themasterishome/demo-bicep-deploy --jq .default_branch
   ```

   The output must be `master`. If it is not, set it and run the check again.

   ```powershell
   gh api --method PATCH repos/themasterishome/demo-bicep-deploy -f default_branch=master --jq .default_branch
   ```

   Do this now, before step 3.7. **Run workflow** lists only workflows that exist on the default branch, and once the ruleset blocks force pushes, an administrator cannot change the default branch without a bypass.

The push starts mirror-validate and mirror-deploy-unit. Every job of both shows as skipped, because the switch is not set yet (step 3.20). No runner starts and nothing signs in to Azure.

### 3.6 Set the Actions settings

In the repository, open **Settings** > **Actions** > **General** and set the following.

| Setting | Value | Why |
|---|---|---|
| Actions permissions | **Allow themasterishome, and select non-themasterishome, actions and reusable workflows**, with **Allow actions created by GitHub** ticked and `azure/login@*` in **Allow or block specified actions and reusable workflows** | The workflows use only `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact` and `azure/login`. |
| Require actions to be pinned to a full-length commit SHA | On | An action's owner can move a tag, not a commit SHA. The four pins are full SHAs. |
| Check, workflow run, status, artifact and log retention | **90** days | Check that it shows 90, which is the default and the maximum for a public repository. The project sets 365, which a private repository allows. |
| Approval for running fork pull request workflows from contributors | **Require approval for all external contributors** | A public repository can always be forked. The project switches forking off instead. A fork's pull request also gets a read-only token and no `id-token: write`, so it cannot sign in to Azure. |
| Workflow permissions | **Read repository contents and packages permissions** | Each job asks for its few extra rights itself. |
| Allow GitHub Actions to create and approve pull requests | Off | A workflow must never approve or merge a pull request. It is off by default on a personal repository. |

Select **Save** under each section you change. To check, reopen the page and confirm each value.

### 3.7 Create the branch ruleset protect-master

The project's organization ruleset already blocks force pushes and branch deletion, so its repository ruleset adds only the code owner review and the checks. The demo has no organization ruleset, so its ruleset carries everything.

1. Open **Settings** > **Rules** > **Rulesets** > **New ruleset** > **New branch ruleset**.
2. Set the following.

   | Setting | Value |
   |---|---|
   | Ruleset name | `protect-master` |
   | Enforcement status | **Active**. A new ruleset starts as **Disabled** |
   | Bypass list | Empty |
   | Target branches | **Add a target** > **Include default branch** |
   | Restrict deletions | On (on by default) |
   | Block force pushes | On (on by default) |
   | Require a pull request before merging | On, with **Required approvals** 1, or 0 when you run alone |
   | Require review from Code Owners | On, or off when you run alone |
   | Allowed merge methods | **Squash** only. The push run and the change ticket lookup expect one commit per pull request |
   | Require status checks to pass before merging | On, with **Require branches to be up to date before merging** |

3. Select **Create**.

Leave the list of status checks empty for now. A check name is offered only after its job has run once, and step 3.21 adds the six names. Until step 3.20 every job is skipped, and GitHub treats a skipped required check as passed. So until then only the review holds a merge back, as in the project.

If the page refuses to save while **Require status checks to pass before merging** is on and no check is listed, turn that rule off, save, and turn it on at step 3.21.

Check the ruleset.

```powershell
gh api repos/themasterishome/demo-bicep-deploy/rulesets --jq ".[] | {name, target, enforcement}"
```

The output has a line for `protect-master` with `"target":"branch"` and `"enforcement":"active"`.

### 3.8 The push ruleset (not in the demo)

The project's push ruleset `protect-github-folder` lets only the approvers team push a change under `.github/`. Push rulesets exist only for private and internal repositories, so the demo has none. In the demo, `.github/` is protected by `protect-master` and the code owner review only. Tell the audience that this is the one project control the demo leaves out.

### 3.9 Create the tag ruleset protect-tags

This stops anyone creating a tag that looks like a deployable reference, as in the project.

1. In **Settings** > **Rules** > **Rulesets**, select **New ruleset** > **New tag ruleset**.
2. Name it `protect-tags` and set **Enforcement status** to **Active**.
3. Leave the bypass list empty.
4. Select **Add a target** > **Include all tags**.
5. Turn on **Restrict creations**, **Restrict updates** and **Restrict deletions**, and select **Create**.

Check that `gh api repos/themasterishome/demo-bicep-deploy/rulesets --jq ".[].name"` lists `protect-master` and `protect-tags`.

### 3.10 Turn on push protection

Secret scanning already runs on every public repository for free. Push protection for the repository is off by default. In **Settings**, open **Advanced Security**, in the sidebar section **Security and quality** (**Security** in older layouts), and select **Enable** next to **Push protection**. If **Secret Protection** is not enabled yet, select **Enable** next to it first. The project needs GitHub Secret Protection in its plan for the same switch. In both, the Gitleaks scan of mirror-validate catches what push protection misses.

### 3.11 Create the 3 environments

The project has 13 environments, one per subscription and two for the reader. The demo has one subscription, so it has three.

| Environment | Reviewers | Deployment branches | Used by |
|---|---|---|---|
| `mirror-reader` | None | No restriction, because the previews run on pull request branches | mirror-pr `whatif` |
| `mirror-reader-dispatch` | None | **Selected branches and tags**, one branch rule `master` | mirror-deploy-unit `plan`, mirror-drift `drift` |
| `mirror-production-demo` | You and the second account, with **Prevent self-review** on | **Selected branches and tags**, one branch rule `master` | mirror-deploy-unit `apply` |

Create all three before the switch. A workflow that names an environment that does not exist creates it without reviewers or branch rule.

Create them in a PowerShell window.

```powershell
$repo = 'themasterishome/demo-bicep-deploy'
$branchPolicy = @{ protected_branches = $false; custom_branch_policies = $true }
gh api --method PUT "repos/$repo/environments/mirror-reader" | Out-Null
@{ deployment_branch_policy = $branchPolicy } | ConvertTo-Json -Depth 4 |
  gh api --method PUT "repos/$repo/environments/mirror-reader-dispatch" --input - | Out-Null
gh api --method POST "repos/$repo/environments/mirror-reader-dispatch/deployment-branch-policies" -f name=master -f type=branch | Out-Null
Write-Host 'created mirror-reader-dispatch'
@{ wait_timer = 0; prevent_self_review = $true
   reviewers = @(@{ type = 'User'; id = 49098959 }, @{ type = 'User'; id = SECOND_ID })
   deployment_branch_policy = $branchPolicy } |
  ConvertTo-Json -Depth 5 | gh api --method PUT "repos/$repo/environments/mirror-production-demo" --input - | Out-Null
gh api --method POST "repos/$repo/environments/mirror-production-demo/deployment-branch-policies" -f name=master -f type=branch | Out-Null
Write-Host 'created mirror-production-demo'
```

Replace `SECOND_ID` with the number from step 3.2. If you run alone, use `prevent_self_review = $false` and `reviewers = @(@{ type = 'User'; id = 49098959 })`. The project lists the team (`type = 'Team'`). The output is two lines, `created mirror-reader-dispatch` and `created mirror-production-demo`.

Check the three environments.

```powershell
$repo = 'themasterishome/demo-bicep-deploy'
gh api "repos/$repo/environments" --jq ".environments[].name"
gh api "repos/$repo/environments/mirror-production-demo" --jq ".protection_rules"
gh api "repos/$repo/environments/mirror-production-demo/deployment-branch-policies" --jq ".branch_policies[].name"
gh api "repos/$repo/environments/mirror-reader-dispatch/deployment-branch-policies" --jq ".branch_policies[].name"
```

The first command lists the three names. The second shows a `required_reviewers` rule with `prevent_self_review` true and both users, and a `branch_policy` rule. The third and fourth print `master`.

Keep **Allow administrators to bypass configured protection rules** on, as GitHub's default and as the project does. It is the break-glass route. You, as the repository's admin, can then use **Start all waiting jobs** on a waiting run, after a comment. The REST call has no field for it, so it is a setting under **Settings** > **Environments** > `mirror-production-demo` only.

### 3.12 Create the resource group for the identities

The project puts the identities in a subscription of their own. The demo has one subscription, so the group sits next to the units (section 1). Your CLI default is already the Visual Studio subscription (section 2).

1. Create the group.

   ```powershell
   az group create --name rg-demo-identities --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy
   ```

   The output is the group in JSON, with `"provisioningState": "Succeeded"`.

2. Lock the group against deletion. The lock stops anyone deleting the identities or their credentials. It also stops the deletion of the policy assignment of item 3, which section 6 needs to know.

   ```powershell
   az lock create --name mirror-identities-no-delete --lock-type CanNotDelete --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   ```

   The output is the lock in JSON, with `"level": "CanNotDelete"`. The portal shows this lock type as **Delete**.

3. Assign the built-in policy that allows federated credentials only from trusted GitHub owners.
   1. Check that the compliance provider is registered.

      ```powershell
      az provider show --namespace Microsoft.PolicyInsights --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query registrationState -o tsv
      ```

      The output is `Registered`. If it is not, run `az provider register --namespace Microsoft.PolicyInsights --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --wait` and check again.
   2. Assign the policy with the effect Audit.

      ```powershell
      az policy assignment create --name mirror-fic-trusted-owners `
        --display-name "GitHub federated credentials only from themasterishome" `
        --policy fd1a8e20-2c4f-4a6c-9354-b58d786d9a1f `
        --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-identities `
        --params "{ 'allowedRepoOwners': { 'value': [ 'themasterishome@49098959' ] }, 'effect': { 'value': 'Audit' } }"
      ```

      The output is the assignment in JSON, with `allowedRepoOwners` and `effect` under `parameters`. The owner value is the login, `@` and the owner ID, because the subjects of step 3.16 carry the ID.

   Create the assignment with this command only. The portal gives a new assignment a GUID as its name, and step 3.17 and section 6 find it by the name `mirror-fic-trusted-owners`. Use the portal only to show the assignment, under **Policy** > **Authoring** > **Assignments** with the scope `rg-demo-identities`.

4. Project item 4 (an eligible PIM assignment of Managed Identity Contributor) is left out. Your Owner on the subscription covers the demo.

Check the lock and the policy.

```powershell
az lock list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, level:level}" -o table
az policy assignment list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:displayName, definition:policyDefinitionId}" -o table
```

The first lists `mirror-identities-no-delete` with `CanNotDelete`. The second lists the policy, with a definition ID that ends in `fd1a8e20-2c4f-4a6c-9354-b58d786d9a1f`.

### 3.13 Create the custom role Mirror What-If Reader

The role adds `Microsoft.Resources/deployments/whatIf/action`, the one action Reader lacks for a preview at the validation level `ProviderNoRbac`. The project lists 11 subscriptions as its scopes, and the demo one.

1. Save the role file in a folder outside the repository.

   ```powershell
   New-Item -ItemType Directory -Force -Path C:\demo-setup | Out-Null
   '{"Name":"Mirror What-If Reader","IsCustom":true,"Description":"Preview deployments with what-if. Changes no resource.","Actions":["Microsoft.Resources/deployments/whatIf/action"],"NotActions":[],"AssignableScopes":["/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7"]}' | Set-Content -Path C:\demo-setup\mirror-whatif-reader.json -Encoding ascii
   ```

2. Create the role.

   ```powershell
   az role definition create --role-definition C:\demo-setup\mirror-whatif-reader.json --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   ```

   The output is the role in JSON, with `"roleName": "Mirror What-If Reader"`. If it fails because a role of that name exists, an earlier demo left it behind. Delete it as section 6 shows, or use it.

3. Read the role's ID.

   ```powershell
   az role definition list --name "Mirror What-If Reader" --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[0].name" -o tsv
   ```

   The output is one GUID, new each time the role is created. Keep it as `WHATIF_ROLE_ID`. A new role takes a short while to replicate. If the command prints nothing, wait a minute and run it again.

4. Project item 5 gives the approvers these roles too, because a writer can read the previews. In a public repository anyone can read them, so the demo skips it.

### 3.14 Create the reader identity and grant its roles

1. Create the identity.

   ```powershell
   az identity create --name id-mirror-reader --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth
   ```

   The output is the identity in JSON. Keep `clientId` as `READER_CLIENT` and `principalId` as `READER_PRINCIPAL`.

2. Grant Reader and Mirror What-If Reader on the subscription.

   ```powershell
   az role assignment create --assignee-object-id READER_PRINCIPAL --assignee-principal-type ServicePrincipal `
     --role acdd72a7-3385-48ef-bd42-f606fba81ae7 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o none
   az role assignment create --assignee-object-id READER_PRINCIPAL --assignee-principal-type ServicePrincipal `
     --role WHATIF_ROLE_ID --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o none
   ```

   Replace `READER_PRINCIPAL` and `WHATIF_ROLE_ID`. `acdd72a7-3385-48ef-bd42-f606fba81ae7` is the built-in Reader role. Each command prints nothing when it succeeds. If the second one says the role does not exist, the new role has not replicated yet. Wait a minute and run it again.

3. Check the assignments.

   ```powershell
   az role assignment list --assignee-object-id READER_PRINCIPAL --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, role:roleDefinitionName, scope:scope}" -o table
   ```

   The output has two rows, Reader and Mirror What-If Reader, on `/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7`. A new role assignment can take about 10 minutes to take effect.

4. Project item 4 declares these assignments in the code after the pilot. The demo leaves it out, because its only subscription unit, `demo-subscription`, is deployed by hand and adds nothing to the pipeline's flow.

### 3.15 Create the deploy identity

The project creates one deploy identity per subscription that has pipeline units. The demo has one.

1. Create the identity.

   ```powershell
   az identity create --name id-mirror-deploy-demo --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth
   ```

   Keep `clientId` as `DEPLOY_CLIENT` and `principalId` as `DEPLOY_PRINCIPAL`.

2. Give it Contributor on the whole subscription, by the role's ID. The gate step's identity check looks for the unit's subscription in the sign-in. Never give it User Access Administrator, Role Based Access Control Administrator or Owner.

   ```powershell
   az role assignment create --assignee-object-id DEPLOY_PRINCIPAL --assignee-principal-type ServicePrincipal `
     --role b24988ac-6180-42a0-ab88-20f7382dd24c --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o none
   ```

   `b24988ac-6180-42a0-ab88-20f7382dd24c` is the built-in Contributor role. The command prints nothing when it succeeds.

3. Project items 2.2 and 3 (Mirror Budget Writer, Mirror Network Peering) do not apply. The demo has no budget and no peering.

4. Check the assignment.

   ```powershell
   az role assignment list --assignee-object-id DEPLOY_PRINCIPAL --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, role:roleDefinitionName, scope:scope}" -o table
   ```

   The output has one row, Contributor on the subscription.

Check that both identities exist.

```powershell
az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

The output lists `id-mirror-deploy-demo` and `id-mirror-reader`. To read an identity's IDs again later, run `az identity show --name IDENTITY_NAME --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "{clientId:clientId, principalId:principalId}" -o json`.

### 3.16 Read the subject the workflows present

A federated credential trusts one exact subject. Azure accepts a wrong subject when you create the credential, and the sign-in fails later. Repositories created after 15 July 2026 use a subject with the owner ID and the repository ID, so the demo repository does.

1. Read the subject settings.

   ```powershell
   gh api repos/themasterishome/demo-bicep-deploy/actions/oidc/customization/sub
   ```

   The output is similar to the following.

   ```text
   {"use_default":true,"use_immutable_subject":true,"sub_claim_prefix":"repo:themasterishome@49098959/demo-bicep-deploy@123456789"}
   ```

   The number after `demo-bicep-deploy@` is `REPOSITORY_ID` from step 3.3. If the output has no `sub_claim_prefix`, build the prefix from the two IDs yourself.

2. Build the three subjects, the prefix, then `:environment:`, then the environment's name.

   ```text
   repo:themasterishome@49098959/demo-bicep-deploy@REPOSITORY_ID:environment:mirror-reader
   repo:themasterishome@49098959/demo-bicep-deploy@REPOSITORY_ID:environment:mirror-reader-dispatch
   repo:themasterishome@49098959/demo-bicep-deploy@REPOSITORY_ID:environment:mirror-production-demo
   ```

   Every job of these workflows names an environment, so it presents this environment form, even when a pull request starts it.

3. Confirm the issuer. `gh api users/themasterishome --jq .html_url` prints `https://github.com/themasterishome`. A personal account on github.com uses the issuer `https://token.actions.githubusercontent.com`. The project also asks an enterprise owner about the enterprise's own issuer URL, which a personal account does not have.

### 3.17 Create the federated credentials

| Identity | Environments | Credentials |
|---|---|---|
| `id-mirror-reader` | `mirror-reader` and `mirror-reader-dispatch` | 2 |
| `id-mirror-deploy-demo` | `mirror-production-demo` | 1 |

Create them one at a time, because Azure refuses concurrent changes to one identity's credentials. Use the CLI and the exact subjects of step 3.16. The portal's scenario **GitHub Actions deploying Azure resources** fills in the subject from the names, and Microsoft does not say that it adds the IDs. If you use the portal, choose **Other issuer** and paste the exact subject.

1. Create the three credentials.

   ```powershell
   az identity federated-credential create --name github-mirror-reader `
     --identity-name id-mirror-reader --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
     --issuer https://token.actions.githubusercontent.com `
     --subject "repo:themasterishome@49098959/demo-bicep-deploy@REPOSITORY_ID:environment:mirror-reader" `
     --audiences api://AzureADTokenExchange
   az identity federated-credential create --name github-mirror-reader-dispatch `
     --identity-name id-mirror-reader --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
     --issuer https://token.actions.githubusercontent.com `
     --subject "repo:themasterishome@49098959/demo-bicep-deploy@REPOSITORY_ID:environment:mirror-reader-dispatch" `
     --audiences api://AzureADTokenExchange
   az identity federated-credential create --name github-mirror-production-demo `
     --identity-name id-mirror-deploy-demo --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
     --issuer https://token.actions.githubusercontent.com `
     --subject "repo:themasterishome@49098959/demo-bicep-deploy@REPOSITORY_ID:environment:mirror-production-demo" `
     --audiences api://AzureADTokenExchange
   ```

   Replace `REPOSITORY_ID` in the three subjects. Each output is the credential in JSON, with the subject you gave.

2. Read them back. A wrong subject, issuer or audience shows no error until the sign-in fails.

   ```powershell
   foreach ($i in 'id-mirror-reader', 'id-mirror-deploy-demo') {
     az identity federated-credential list --identity-name $i --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
       --query "[].{name:name, subject:subject, issuer:issuer, audience:audiences[0]}" -o table
   }
   ```

   The output is two rows for the reader and one for the deploy identity, each with its subject, the issuer and the audience `api://AzureADTokenExchange`. If a value differs, run that credential's `create` command of item 1 again, with the same `--name` and the right value. It replaces the credential in place. Do not delete it, because the lock of step 3.12 refuses the delete.

3. Check that the three credentials are compliant with the policy. The scan can take several minutes.

   ```powershell
   az policy state trigger-scan --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   az policy state list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --filter "policyAssignmentName eq 'mirror-fic-trusted-owners'" --query "[].{res:resourceId, state:complianceState}" -o table
   ```

   The output lists the three credentials as `Compliant`. The portal shows the same under **Policy** > **Compliance**.

4. Switch the policy to Deny.

   ```powershell
   az policy assignment update --name mirror-fic-trusted-owners `
     --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-identities `
     --params "{ 'allowedRepoOwners': { 'value': [ 'themasterishome@49098959' ] }, 'effect': { 'value': 'Deny' } }"
   ```

   The output is the assignment in JSON, with `Deny` as the value of `effect`. Azure can take up to about 30 minutes to apply a changed assignment.

5. Optionally, show the audience that Deny works. Do this only after the wait of item 4. If you run it too early, it creates the credential, and the lock keeps it until section 6. A credential for another owner is refused with `RequestDisallowedByPolicy`, and nothing is created.

   ```powershell
   az identity federated-credential create --name deny-check --identity-name id-mirror-reader --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --issuer https://token.actions.githubusercontent.com --subject "repo:someone-else@1/other@2:environment:mirror-reader" --audiences api://AzureADTokenExchange
   ```

   Then check that no credential `deny-check` exists.

   ```powershell
   az identity federated-credential list --identity-name id-mirror-reader --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
   ```

   The output is `github-mirror-reader` and `github-mirror-reader-dispatch`. If it also lists `deny-check`, Deny was not in force yet. Leave the credential, because nothing signs in with that subject, and section 6 removes it with the group.

Wait a few minutes before the first run. A token request right after a credential is created can fail with `AADSTS70021`.

### 3.18 Set the environment variables

Each environment holds two variables. Neither is secret.

```powershell
$repo = 'themasterishome/demo-bicep-deploy'
foreach ($e in 'mirror-reader', 'mirror-reader-dispatch') {
  gh variable set AZURE_CLIENT_ID --env $e --body READER_CLIENT --repo $repo
  gh variable set AZURE_TENANT_ID --env $e --body d1a349ef-6ac8-4588-a88d-5dab272c700b --repo $repo
}
gh variable set AZURE_CLIENT_ID --env mirror-production-demo --body DEPLOY_CLIENT --repo $repo
gh variable set AZURE_TENANT_ID --env mirror-production-demo --body d1a349ef-6ac8-4588-a88d-5dab272c700b --repo $repo
```

Replace `READER_CLIENT` and `DEPLOY_CLIENT` with the client IDs from steps 3.14 and 3.15. Set them per environment, never at repository or organization level. A value there reaches every job whose environment has none, so one identity's client ID would show up where it does not belong, and the apply job's check of step 3.19 would pass in an environment that has no identity of its own.

Check each environment, for example with `gh variable list --env mirror-reader-dispatch --repo themasterishome/demo-bicep-deploy`. Each lists `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`.

Leave `MIRROR_RUNNER` and `MIRROR_MAX_PLAN_AGE_HOURS` unset. Every job then runs on `windows-2025`, apart from `portability`, which runs on `ubuntu-24.04`. A plan may wait 24 hours for its approval. The switch `MIRROR_PIPELINE_ENABLED` waits for step 3.20.

### 3.19 Check the client IDs of the environments

The client IDs of the two identities live in one place, the `AZURE_CLIENT_ID` variable of each environment (step 3.18). `deploy/units.json` does not hold them. `deploy-unit.ps1` accepts a service principal in a GitHub Actions job when its name equals the client ID that the workflow passes in `MIRROR_CLIENT_ID`, which is the environment's `AZURE_CLIENT_ID`. `allowedPrincipals` lists only the people who run the scripts by hand, so the file has one entry, of `"type": "user"`. Leave its name empty, because you run no script by hand in this demo.

The check in the script is a guard against mistakes. The boundary is Entra and the identity's roles. Entra issues a token to a job only when the job's subject matches a federated credential of the identity, and the subject names one repository and one environment. If someone changes a variable to another identity's client ID, the sign-in fails unless that identity trusts the environment. A changed workflow could pass the script any client ID, so what stops it is the ruleset on `master` (step 3.7) and the rule of each environment that only `master` may use it (step 3.11). The `apply` job also stops in the step before the sign-in when its environment has no `AZURE_CLIENT_ID` or the value is not a GUID.

Nothing is edited in the code. Run this check once after step 3.18, and again after any change to an identity. It compares each environment's variable with the identity's client ID, and checks that the identity has a federated credential for exactly that environment.

```powershell
$repo = 'themasterishome/demo-bicep-deploy'
$sub = '77488719-1168-4d53-af9a-f5c3bc9291d7'
$repoId = gh api "repos/$repo" --jq .id
$pairs = @(
  @('mirror-reader', 'id-mirror-reader'),
  @('mirror-reader-dispatch', 'id-mirror-reader'),
  @('mirror-production-demo', 'id-mirror-deploy-demo')
)
foreach ($pair in $pairs) {
  $name = $pair[0]
  $identity = $pair[1]
  $variables = @(gh variable list --env $name --repo $repo --json name,value | Out-String | ConvertFrom-Json)
  $variable = [string](($variables | ForEach-Object { $_ }) | Where-Object { $_.name -eq 'AZURE_CLIENT_ID' }).value
  $client = az identity show --name $identity --resource-group rg-demo-identities --subscription $sub --query clientId -o tsv
  $subjects = @(az identity federated-credential list --identity-name $identity --resource-group rg-demo-identities --subscription $sub --query "[].subject" -o tsv)
  $expected = "repo:themasterishome@49098959/demo-bicep-deploy@${repoId}:environment:${name}"
  $idOk = ($variable -eq $client)
  $subjectOk = ($subjects -contains $expected)
  Write-Host "$name -> $identity : client ID matches $idOk, credential for the environment $subjectOk"
}
```

The output is three lines, and both values on every line are `True`. Then check that no repository-level variable of the same name exists.

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy --json name | Out-String | ConvertFrom-Json | Where-Object { $_.name -eq 'AZURE_CLIENT_ID' }
```

The command prints nothing. If a line says `False`, or the second command prints a variable, correct the variable (step 3.18) or the credential (step 3.17) and run the check again. A client ID that does not match shows later as `AADSTS700213` or `AADSTS70021` at the sign-in (section 5).

### 3.20 Turn the pipeline on

1. Set the switch.

   ```powershell
   gh variable set MIRROR_PIPELINE_ENABLED --body true --repo themasterishome/demo-bicep-deploy
   ```

   Or open **Settings** > **Secrets and variables** > **Actions** > **Variables** > **New repository variable**, with the name `MIRROR_PIPELINE_ENABLED` and the value `true`.

2. Check it.

   ```powershell
   gh variable list --repo themasterishome/demo-bicep-deploy
   ```

   The output lists `MIRROR_PIPELINE_ENABLED` with the value `true`. Setting it starts no run by itself.

3. Project item 3 turns Dependabot on. The demo leaves `.github/dependabot.yml` with `open-pull-requests-limit: 0`, so no Dependabot pull request moves `master` during a demo. Dependabot's pull requests also run like a fork's and cannot sign in to Azure.

To stop every job again, set the variable to `false`.

### 3.21 First run: the validate workflow

1. Open a pull request that touches no unit, for example a one-line change to `README.md`.

   ```powershell
   git switch --create first-checks
   Add-Content -Path README.md -Value ''
   git commit --all --message "First run of the checks"
   git push -u origin first-checks
   gh pr create --repo themasterishome/demo-bicep-deploy --base master --head first-checks --title "First run of the checks" --body "Change: DEMO-0002"
   ```

2. Wait for the checks. On the small demo tree the run takes a few minutes. The five jobs of mirror-validate are green: `secret-scan`, `actionlint`, `workflow-hygiene`, `portability` and `preflight`. mirror-pr shows `plan`, no `whatif` job and a green `pr-gate`, because no unit is touched. If a job fails, read its first error.

3. Add the six required checks to the ruleset. Open **Settings** > **Rules** > **Rulesets** > `protect-master`. Turn on **Require status checks to pass before merging** if step 3.7 left it off, with **Require branches to be up to date before merging**. Under that rule, type each check name, select it with **+**, and keep the source **GitHub Actions**: `secret-scan`, `actionlint`, `workflow-hygiene`, `portability`, `preflight` and `pr-gate`. Select **Save changes**. The check names are the job IDs, because none of these six jobs has a `name:` key.

4. Close the pull request without merging, and keep its branch for step 3.22.

   ```powershell
   gh pr close first-checks --repo themasterishome/demo-bicep-deploy
   git switch master
   ```

Project step 3.21 also checks the push ruleset against a branch made at an older commit. The demo has no push ruleset, so that part does not apply.

### 3.22 First run: the drift workflow with no unit enabled

This run proves the reader's sign-in through `mirror-reader-dispatch`. With every unit disabled the drift check has nothing to check, so it fails on purpose.

1. Start it on `master`.

   ```powershell
   gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy
   ```

   Or open **Actions** > **mirror-drift** > **Run workflow**, keep the branch `master` and select **Run workflow**.

2. Open the finished run. The `azure/login` step is green. The step "Drift sweep (read-only)" fails, and its last line starts with `STOP: no enabled unit to check in deploy/units.json`. The upload of the `drift` artifact then warns that no files were found.

3. Check the branch rule. Start the workflow on the branch of step 3.21.

   ```powershell
   gh workflow run mirror-drift.yml --ref first-checks --repo themasterishome/demo-bicep-deploy
   ```

   The run fails before any step, with `Branch "first-checks" is not allowed to deploy to mirror-reader-dispatch due to environment protection rules`. If it signs in instead, `mirror-reader-dispatch` has no branch rule. Add it (step 3.11) and run this check again.

4. Delete the branch.

   ```powershell
   git push origin --delete first-checks
   git branch --delete --force first-checks
   ```

If the sign-in fails with `AADSTS70021`, the credential's subject does not match, or it was created only a minute ago (section 5).

### 3.23 First run: the pilot unit end to end

This is wave 0 of the demo run. Do it now, before the audience, or as the first part of the demo, [section 4.2](#42-wave-0-the-pilot).

### 3.24 The security alerts (not in the demo)

The project's alerts e-mail IT's security mailbox about every role assignment and federated credential change. The demo leaves them out. Add them only if the audience asks to see them, with the commands of PIPELINE.md step 3.24 and `rg-demo-identities` as the alert group.

## 4. The demo run

Each part says what to do and what the audience sees on screen. Nothing changes in Azure until the second account approves an apply job.

### 4.1 Before you start

Prepare two browser windows side by side, the repository in your own window and the same repository in the private window of the second account. Keep a PowerShell window at the root of the local repository, on `master`.

**Check before the demo:**
- [ ] Steps 3.1 to 3.22 are done, and the mirror-validate run of the step 3.21 pull request is green.
- [ ] `az account show` names the Visual Studio subscription.
- [ ] `gh auth status` shows `themasterishome` as the active account.
- [ ] The second account is signed in, in the private window.
- [ ] No run of mirror-deploy-unit waits for approval.
- [ ] You merge nothing else while a deployment waits. A merge moves `master`, and the waiting apply then refuses (project section 4.1).

Plan jobs take one to two minutes, and apply jobs about three.

### 4.2 Wave 0, the pilot

This is project step 3.23 and sections 4.2 to 4.8. Project section 4.6, the check of the deploy identity's roles, is step 3.15 item 4 here, done once at set-up, because the demo grants that identity no other role.

1. Create the three resource groups of the demo estate. The project creates only the pilot's group, because its other groups exist already. The demo makes its groups exist in the same way. Their name, region and tag match `infra/subscriptions/demo/main.bicep`.

   ```powershell
   foreach ($g in 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') {
     az group create --name $g --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy -o none
     az group show --name $g --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.provisioningState -o tsv
   }
   ```

   The output is `Succeeded` three times. The audience sees three empty groups in the portal.

2. Create a branch, then open `deploy/units.json` in an editor and set `"enabled": true` in the entry of `pilot-empty-rg`.

   ```powershell
   git switch --create enable-pilot
   ```

   Then commit, push and open the pull request.

   ```powershell
   git commit --all --message "Enable the pilot unit"
   git push -u origin enable-pilot
   gh pr create --repo themasterishome/demo-bicep-deploy --base master --head enable-pilot --title "Enable the pilot unit" --body "Change: DEMO-0003"
   ```

   On screen, the pull request runs mirror-validate and mirror-pr. mirror-pr has a job `whatif pilot-empty-rg`, the reader's first sign-in through `mirror-reader`. Its comment on the pull request shows the pilot's preview with the gate PASS and no records.

3. As the second account, approve the pull request (**Files changed** > **Review changes** > **Approve** > **Submit review**). Then, once every check is green, squash-merge it as yourself and update `master`. GitHub refuses the merge while a required check is still running.

   ```powershell
   gh pr merge enable-pilot --squash --delete-branch --repo themasterishome/demo-bicep-deploy
   git switch master
   git pull
   ```

4. Show the push run. Open **Actions** > **mirror-deploy-unit** and the newest run, named "Plan the units changed by the push" and the commit. Or list it.

   ```powershell
   gh run list --workflow mirror-deploy-unit.yml --branch master --limit 3 --repo themasterishome/demo-bicep-deploy
   ```

   On screen, `select` lists `pilot-empty-rg`, and the job `plan pilot-empty-rg` signs in as the reader through `mirror-reader-dispatch`. Its summary shows "Gate PASS, approvable", with PASS in bold, and ends with "A push publishes this plan and deploys nothing. The plan holds no effective change, so nothing waits for a reviewer. A change is applied with Run workflow, which names the ticket, the reason and the options." There is no apply job. The merge deployed nothing.

5. Start the deployment by hand.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot" -f apply=true --repo themasterishome/demo-bicep-deploy
   ```

   Or open **Actions** > **mirror-deploy-unit** > **Run workflow**, keep the branch `master`, fill in `unit`, `changeRef` and `reason`, tick `apply`, and select **Run workflow**. The run is named "Deploy pilot-empty-rg (DEMO-0003)".

6. Show the waiting apply. After `plan pilot-empty-rg` and `collect`, the job `apply pilot-empty-rg` shows **Waiting**, for the environment `mirror-production-demo`. The plan's summary says it holds no effective change. Show the audience that the plan summary and the artifact `reviewed-plan-pilot-empty-rg` can be read while it waits.

7. Show Prevent self-review. In your own window, open the run. You started it, so you cannot approve it. The **Review deployments** button is missing, or GitHub does not let you tick the environment. Do not use **Start all waiting jobs** here. It is the administrators' bypass of step 3.11, and it would skip Prevent self-review in front of the audience. With the one-account variant, skip this item.

8. Approve it as the second account. In the private window, open the run, select **Review deployments**, tick `mirror-production-demo`, write a comment that names `DEMO-0003`, and select **Approve and deploy**.

9. Watch the apply.

   ```powershell
   gh run watch --repo themasterishome/demo-bicep-deploy
   ```

   Choose the run when the GitHub CLI asks. On screen, the apply job checks that it is the first attempt, that `master` is still at the planned commit and that the plan is less than 24 hours old. It signs in as the deploy identity, compares a fresh preview with the plan and runs the gate step. Its summary ends with `Gate step exit: 0, deployed, and the second check passed.`

10. Download the evidence. The run's ID is the long number after `/actions/runs/` in the run's address, not the `#N` number.

    ```powershell
    gh run download RUN_ID --name evidence-deploy-pilot-empty-rg --dir C:\demo-setup\evidence-pilot --repo themasterishome/demo-bicep-deploy
    gh run download RUN_ID --name reviewed-plan-pilot-empty-rg --dir C:\demo-setup\evidence-pilot\reviewed-plan --repo themasterishome/demo-bicep-deploy
    ```

    Replace `RUN_ID` with the run's ID. The files sit under `C:\demo-setup\evidence-pilot`, in the folders the artifact itself holds. This command finds them.

    ```powershell
    Get-ChildItem -Path C:\demo-setup\evidence-pilot -Recurse -Include approval.txt, post-summary.txt | Select-Object -ExpandProperty FullName
    ```

    Open `approval.txt`, which has a `deployed=` line, and `post-summary.txt`, the second check. In the project this goes on the change ticket, with the reviewer's name and comment from the run's **Review deployments** history.

11. Show the plan-only route, as project step 3.23, item 5 does.

    ```powershell
    gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot, plan only" --repo themasterishome/demo-bicep-deploy
    ```

    The run ends after the plan, with the gate PASS and no waiting job.

### 4.3 Wave 1, the network

This is project sections 4.2 to 4.8 and 4.10, for a unit that creates resources.

1. Enable the network and routing units in one pull request. Create a branch, then set `"enabled": true` in the entries of `rg-demo-network` and `rg-demo-routing` in `deploy/units.json`.

   ```powershell
   git switch --create enable-waves
   ```

   Then commit, push and open the pull request.

   ```powershell
   git commit --all --message "Enable the network and routing units"
   git push -u origin enable-waves
   gh pr create --repo themasterishome/demo-bicep-deploy --base master --head enable-waves --title "Enable the network and routing units" --body "Change: DEMO-0004"
   ```

2. Show the preview on the pull request. mirror-pr runs `whatif rg-demo-network` and `whatif rg-demo-routing`. Each shows the gate FAIL with `Create=2`, marked for information. A new resource is a Create, and the gate refuses a Create that nobody named. `pr-gate` is green, because it fails only when a preview could not run.

3. Approve the pull request as the second account, then squash-merge it once every check is green.

   ```powershell
   gh pr merge enable-waves --squash --delete-branch --repo themasterishome/demo-bicep-deploy
   git switch master
   git pull
   ```

4. Show the push run. It plans both units and shows red. Each plan is not approvable, because it holds two Creates. The summary names the option that would accept them, `allowCreate`, and gives the ready `gh workflow run` command with the resource IDs. Nothing waits and nothing deploys.

5. Start the deployment of `rg-demo-network`, with the two resource IDs in `allowCreate`. Type it in PowerShell, or copy the command from the plan summary.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, create the network" -f apply=true -f allowCreate="/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/networkSecurityGroups/nsg-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/virtualNetworks/vnet-demo" --repo themasterishome/demo-bicep-deploy
   ```

   In the **Run workflow** form, paste the two IDs into `allowCreate`, separated by a comma and no space.

6. Show the plan. The summary of `plan rg-demo-network` shows the verdict approvable, the option `allowCreate` with both IDs, and the two Create records with their properties. `apply rg-demo-network` waits.

7. Approve it as the second account (**Review deployments**, tick `mirror-production-demo`, a comment naming `DEMO-0004`, **Approve and deploy**).

8. Watch the apply. The fresh preview matches the plan record for record, the gate step creates `nsg-demo` and `vnet-demo` with its subnet, and the second check shows both NoChange. The summary ends with `Gate step exit: 0, deployed, and the second check passed.` The audience can open the group in the portal and see the two resources.

9. Download the evidence as in wave 0, with `evidence-deploy-rg-demo-network` and `reviewed-plan-rg-demo-network`.

### 4.4 Wave 2, the routing

The unit is enabled already, so this wave needs no pull request.

1. Start the deployment of `rg-demo-routing`.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, create the routing" -f apply=true -f allowCreate="/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/applicationSecurityGroups/asg-demo" --repo themasterishome/demo-bicep-deploy
   ```

2. Approve it as the second account, watch the apply and download `evidence-deploy-rg-demo-routing`, as in wave 1. The second check shows `rt-demo` and `asg-demo` NoChange.

### 4.5 A change after the baseline

This is project section 4.9. The resources now exist, and a real change names its resource in `allowModify`.

1. Create a branch with `git switch --create nsg-rule`. Add one security rule to `nsg-demo` in `infra/subscriptions/demo/resource-groups/rg-demo-network.bicep`. Replace `securityRules: []` with the following block. It denies remote desktop from the internet, and nothing uses the network, so it changes no traffic.

   ```bicep
       securityRules: [
         {
           name: 'Deny-Internet-RDP'
           properties: {
             protocol: 'Tcp'
             sourcePortRange: '*'
             sourcePortRanges: []
             destinationPortRange: '3389'
             destinationPortRanges: []
             sourceAddressPrefix: 'Internet'
             sourceAddressPrefixes: []
             destinationAddressPrefix: 'VirtualNetwork'
             destinationAddressPrefixes: []
             access: 'Deny'
             priority: 100
             direction: 'Inbound'
           }
         }
       ]
   ```

2. Commit, push and open the pull request.

   ```powershell
   git commit --all --message "Deny remote desktop from the internet on nsg-demo"
   git push -u origin nsg-rule
   gh pr create --repo themasterishome/demo-bicep-deploy --base master --head nsg-rule --title "Deny remote desktop from the internet on nsg-demo" --body "Change: DEMO-0006"
   ```

   On screen, `whatif rg-demo-network` shows the gate FAIL with one Modify on `nsg-demo`, the new rule under `securityRules`, for information.

3. Approve it as the second account and squash-merge it once every check is green. The push run plans `rg-demo-network`, and the plan stops with a message that names the NSG's ID for `allowModify`. The merge deploys nothing.

4. Start the deployment with that ID in `allowModify`.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0006 -f reason="Deny remote desktop from the internet" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/networkSecurityGroups/nsg-demo --repo themasterishome/demo-bicep-deploy
   ```

5. On screen, the plan shows "Gate REVIEW, approvable", with REVIEW in bold, and each property change is marked "would be allowed with -AllowModify". Approve it as the second account. The gate step deploys only when its fresh preview shows exactly the planned property changes, and the second check shows `nsg-demo` NoChange.

### 4.6 Drift

This is project section 5.3, with the repair of REFERENCE.md section 5.2.

1. Run the drift check once with everything in line.

   ```powershell
   gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy
   ```

   The summary lists `pilot-empty-rg`, `rg-demo-network` and `rg-demo-routing` as clean, and the run is green.

2. Change something outside the code. In the portal, open the route table `rt-demo`. In its left menu open **Tags**, add the name `changedBy` with the value `portal`, and select **Apply**.

3. Run the drift check again with the same command. The run is red, and its summary lists `rg-demo-routing` as `DRIFT`, with a Modify on `rt-demo` that removes the tag `changedBy`. A failed run is the alert, and GitHub notifies the person who started it. The `drift` artifact holds each unit's evidence.

4. Repair it by putting the code's value back. Start a deployment of `rg-demo-routing` with `rt-demo` in `allowModify`.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0007 -f reason="Undo the drift on rt-demo" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo --repo themasterishome/demo-bicep-deploy
   ```

   The plan shows the tag going away. Approve it as the second account. After the deployment, run the drift check again. All three units are clean.

   The other repair is to keep the live value. You then copy the tag into `rg-demo-routing.bicep` through a code pull request, and the next drift check is clean with nothing deployed.

### 4.7 A rollback

This is REFERENCE.md section 4.1. It takes the rule of section 4.5 out again.

1. Find the squash commit of the rule's pull request and revert it on a branch.

   ```powershell
   git switch master
   git pull
   git log --oneline -5
   git switch --create revert-nsg-rule
   git revert --no-edit BAD_COMMIT
   git push -u origin revert-nsg-rule
   gh pr create --repo themasterishome/demo-bicep-deploy --base master --head revert-nsg-rule --title "Roll back the remote desktop rule on nsg-demo" --body "Change: DEMO-0008"
   ```

   Replace `BAD_COMMIT` with the ID of the commit "Deny remote desktop from the internet on nsg-demo" in the `git log` output. A squash merge is one ordinary commit, so `git revert` needs no `-m` option. The preview on the pull request shows a Modify on `nsg-demo` that removes the rule.

2. Approve it as the second account and squash-merge it once every check is green. The push run stops on the Modify, as in section 4.5.

3. Start the deployment with the NSG in `allowModify`, as in section 4.5, item 4, with `changeRef=DEMO-0008` and the reason `Roll back the remote desktop rule`.

4. Approve it as the second account. The rollback worked when the gate step exits 0, the second check shows `nsg-demo` NoChange, and a drift run is clean. In the portal, `nsg-demo` has no rule of its own again.

A rollback cannot remove a resource that a deployment created with `allowCreate`, because a deployment never deletes. Section 6 removes those by deleting the groups. The project can later let a deployment stack delete a resource that the code no longer declares (PIPELINE.md section 8.4). The demo does not use that option.

## 5. What can go wrong

| Symptom | Cause | Fix |
|---|---|---|
| A re-run of a failed deploy run is green, and nothing deployed | The apply job runs only on the first attempt (`github.run_attempt == '1'`). A skipped job counts as passed, so the run shows green | Read the apply job, not the run's color. To retry, start a new run with Run workflow |
| **Review deployments** shows nothing to tick | The button belongs to the run whose apply job waits. A failed or finished run of the same unit has nothing to approve | Open the newest run, named "Deploy UNIT (TICKET)", whose apply job shows **Waiting** |
| The person who started the run cannot approve it | Prevent self-review is on, which is the intended control | The second account approves. Alone, use the variant of section 3.0. An admin can also use **Start all waiting jobs**, with a comment |
| The first deployment of a new resource passes, and the second check shows a Modify on a value nobody set, with exit 3 | The code left out a value Azure sets on create, so live has it and the code does not. An earlier run of these steps hit this with `privateEndpointVNetPolicies` on a virtual network, which the demo now declares | Keep the resource. Declare the live value in the resource group file through a code pull request, then start a new run. Do not retry the same commit |
| A run started from Git Bash is refused, and the IDs read `C:/Program Files/Git/subscriptions/...` | Git Bash rewrites arguments that start with `/subscriptions/` into Windows paths | Run the command from PowerShell. In Git Bash, put `MSYS_NO_PATHCONV=1` in front of it |
| `az policy assignment create` fails with `InvalidAuthenticationTokenTenant` | With `--scope`, the command signs in with the CLI default subscription, which is in another tenant | Run `az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7` and try again (section 2) |
| A sign-in fails with `AADSTS70021` or `AADSTS700213` | The federated credential's subject does not match the job's, or the credential is only a few minutes old, or the environment's `AZURE_CLIENT_ID` names an identity whose credential does not name this repository and environment | Compare the subject the `azure/login` step prints with step 3.17's read-back, and run the check of step 3.19. If they match, wait a few minutes and start a new run |
| The `apply` job fails in the step `Check the environment has a client ID`, with `has no AZURE_CLIENT_ID variable` or `is not a client ID` | The environment `mirror-production-demo` has no `AZURE_CLIENT_ID`, or it is empty or is not a GUID. Nothing was signed in or deployed | Set it (step 3.18), check it (step 3.19) and start a new run |
| The gate step stops with exit 2 and `identity '...' (servicePrincipal) is neither in allowedPrincipals nor the client ID of this GitHub Actions job (MIRROR_CLIENT_ID)` | The identity that signed in is not the one in the job's `AZURE_CLIENT_ID`. This happens when a service principal signed in outside a GitHub Actions job | In a pipeline job, make sure the job signed in with `azure/login`. By hand, sign in as a person listed in `allowedPrincipals` |
| **Run workflow** is missing, or a run starts an old copy of the workflow | The workflow file is not on the default branch, or the default branch is not `master` and holds an older copy | Set the default branch as in step 3.5 |
| The apply refuses after the approval because `master` moved | Something was merged while the apply waited | Reject the old run under **Review deployments**, then start a new run and approve its plan |
| A drift run fails on resource groups the code does not declare | `demo-subscription` was enabled. Its drift check lists every live group in the Visual Studio subscription, and the demo declares only its own three | Keep `demo-subscription` disabled |
| `az policy assignment delete` fails with `ScopeLocked` | The CanNotDelete lock on `rg-demo-identities` covers the assignment | Remove the lock first, as section 6 does |

## 6. Clean up

Remove everything in the order Azure needs. Your CLI default is still the Visual Studio subscription.

1. Remove the lock. Nothing else in the identity group can be deleted while it is on.

   ```powershell
   az lock delete --name mirror-identities-no-delete --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   ```

2. Remove the policy assignment.

   ```powershell
   az policy assignment delete --name mirror-fic-trusted-owners --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-identities
   ```

3. Remove the three role assignments of the two identities.

   ```powershell
   foreach ($p in 'READER_PRINCIPAL', 'DEPLOY_PRINCIPAL') {
     $ids = az role assignment list --assignee-object-id $p --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].id" -o tsv
     foreach ($id in $ids) {
       az role assignment delete --ids $id --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
       Write-Host "removed $id"
     }
   }
   ```

   Replace `READER_PRINCIPAL` and `DEPLOY_PRINCIPAL` with the two `principalId` values. The output is three `removed` lines.

4. Remove the custom role. It can go only once nothing holds it.

   ```powershell
   az role definition delete --name WHATIF_ROLE_ID --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7
   ```

5. Delete the four resource groups. This removes the identities with their credentials, the network, the routing and the deployment history.

   ```powershell
   foreach ($g in 'rg-demo-identities', 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') {
     az group delete --name $g --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --yes
     Write-Host "$g exists: $(az group exists --name $g --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7)"
   }
   ```

   The output ends each group with `exists: false`.

6. Check that nothing is left.

   ```powershell
   az group list --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[?tags.purpose=='demo-bicep-deploy'].name" -o tsv
   az role definition list --custom-role-only true --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].roleName" -o tsv
   ```

   The first prints nothing. The second does not list Mirror What-If Reader. `NetworkWatcherRG` already exists in this subscription and holds Azure's network watchers, so leave it alone. To see that it is there, run `az group exists --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --name NetworkWatcherRG`, which only reads and prints `true`.

7. Delete the GitHub repository. The command needs the `delete_repo` scope, which the GitHub CLI asks for once.

   ```powershell
   gh auth refresh -h github.com -s delete_repo
   gh repo delete themasterishome/demo-bicep-deploy --yes
   ```

   Or open the repository's **Settings** > **General**, and at the end of the page select **Delete this repository**. Deleting it also removes the second account's access. To run the demo again, recreate it from step 3.3, because a new repository has a new ID and so new subjects.

8. Set the Azure CLI default back to the subscription you use day to day.

   ```powershell
   az account set --subscription SUBSCRIPTION_ID
   ```

   Replace `SUBSCRIPTION_ID` with that subscription. You can also delete `C:\demo-setup`, which holds the role file and the evidence you downloaded.
