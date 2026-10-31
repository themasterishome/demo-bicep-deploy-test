# Set up and run the demo

This guide sets up the demo repository `themasterishome/demo-bicep-deploy-test` from nothing and runs it in front of an audience. It follows PIPELINE.md of the project step by step, with the same step numbers, so the people watching see the same process the project goes through, in both of its tiers. Only the estate is small, made up and free.

Contents:
1. [What the demo is](#1-what-the-demo-is)
2. [Prerequisites and sign-ins](#2-prerequisites-and-sign-ins)
3. [Set up once](#3-set-up-once)
4. [The demo run](#4-the-demo-run)
5. [What can go wrong](#5-what-can-go-wrong)
6. [Clean up](#6-clean-up)

## 1. What the demo is

The repository holds the project's four workflows, the helper script `.github/scripts/mirror-pipeline.ps1`, the gate script `scripts/deploy-unit.ps1` and the preflight, unchanged in what they do. The estate is seven units in the Visual Studio subscription, in the project's two tiers. A merge plans a unit and deploys nothing. **Run workflow** deploys it, and only after a reviewer who did not start the run reads the plan and approves it in GitHub. A production unit deploys with the deploy identity `id-mirror-deploy-demo`. A privileged unit changes who has access, so it deploys with a govern identity and waits in a privileged environment. The identity then takes a fresh preview, deploys and takes the second check, and the run keeps the evidence.

The scripts, the workflows and their comments are the production ones with only the names changed, so some comments speak of a team, IT or more subscriptions. The preflight differs in two checks only. Its layout rules accept a deploy-excluded file that `main.bicep` calls behind a switch, and accept `parameters.verify.bicepparam`, because the demo keeps its identity group in one folder with its resource group files, where the project keeps it in a subscription folder of its own.

The units, in the order they deploy:

| Wave | Unit | Tier | Resource group or scope | What it deploys |
|---|---|---|---|---|
| 0 | `pilot-empty-rg` | Production | `rg-demo-pilot` | An empty template. It proves the identities, the approval, the gate and the evidence without touching a resource. |
| 1 | `rg-demo-network` | Production | `rg-demo-network` | The network security group `nsg-demo`, the virtual network `vnet-demo` (10.250.0.0/24) and its subnet `snet-default` (10.250.0.0/26), linked to that network security group. Also the lock `lock-rg-demo-network` (CanNotDelete), the policy assignment of the built-in policy "Audit resource location matches resource group location" with the effect Audit, and a Reader role assignment for the reader identity, and the private endpoint `pe-kv-demo-mirror-secrets` of the secrets vault with the zone `privatelink.vaultcore.azure.net`, its link to `vnet-demo` and the endpoint's zone group. |
| 2 | `rg-demo-routing` | Production | `rg-demo-routing` | The route table `rt-demo` with no routes, the application security group `asg-demo`, and the Automation account `aa-demo-secrets` with the credential `demo-cred`, whose password the unit reads from the secrets vault with `getSecret`. |
| none | `demo-subscription` | Production | The subscription | The four resource groups (the identity group among them) and the Defender plan for virtual machines, declared in `infra/subscriptions/demo/main.bicep`. The identity group's contents are in `resource-groups/rg-demo-identities.deploy-excluded.bicep`, which `main.bicep` calls only when `deployIdentityGroup` is on. `parameters.bicepparam` leaves it off and `parameters.verify.bicepparam` turns it on for a preview. |
| 4 | `demo-privileged` | Privileged | The subscription | The Owner role assignment on `rg-demo-network` and the custom role definition `Demo Reader Plus`. |
| 5 | `demo-tenant-management-group` | Privileged | The Tenant Root Group | Declares the management group `mg-demo` under the Tenant Root Group, which step 3.15 item 8 creates once by hand. |
| 6 | `demo-tenant-governance` | Privileged | The management group `mg-demo` | A Reader role assignment made on `mg-demo`. |

Every resource the demo creates is free. That covers the resource groups, the virtual network and subnet, the network security group, the route table, the application security group, the four managed identities and their federated credentials, the custom roles, the role assignments, the lock, the policy assignments and the management group. Standard GitHub-hosted runners and artifact storage are free in a public repository.

### The two tiers

This follows project section 1.4. Every unit in `deploy/units.json` has a tier. The field `tier` is absent for the production tier and is `privileged` for the privileged tier. The tier decides which identity signs in, which environment the apply job waits in and which reviewer approves it.

| Tier | Units | Identity | Environment | Reviewer |
|---|---|---|---|---|
| Production | `pilot-empty-rg`, `rg-demo-network`, `rg-demo-routing` and `demo-subscription` | `id-mirror-deploy-demo` | `mirror-production-demo` | The second account |
| Privileged | `demo-privileged` | `id-mirror-govern-demo` | `mirror-privileged-demo` | The second account |
| Privileged | `demo-tenant-management-group` and `demo-tenant-governance` | `id-mirror-govern-tenant` | `mirror-privileged-tenant` | The second account |

A privileged unit holds the role assignments of Owner, User Access Administrator and Role Based Access Control Administrator and the custom role definitions. A production unit holds everything else, the Reader assignment, the lock and the policy assignment of `rg-demo-network` among it. The `preflight` job of mirror-validate fails a change that puts a role definition or an assignment of one of those three roles into a production unit. A tenant-kind unit names its `managementGroup` in `units.json` and deploys with `az deployment mg` against it. The Tenant Root Group's name is the tenant ID, `d1a349ef-6ac8-4588-a88d-5dab272c700b`, and the other group is `mg-demo`. Nothing is assigned or deployed at the scope `/`.

The project has one unit the pipeline cannot preview, `fdm-rsg-uks-003-hash-excluded`, because it holds a certificate whose name contains `#`. The demo has no such unit.

### How the identities are protected

This follows project section 1.5. The pipeline signs in to Azure as user-assigned managed identities, through OpenID Connect workload identity federation. GitHub gives the job a short-lived token, and Azure accepts it only when its subject names the expected repository and environment. No secret exists anywhere.

| Identity | Roles | Signs in for |
|---|---|---|
| `id-mirror-reader` | Reader and Mirror What-If Reader on the subscription, and Reader and Mirror What-If Reader Tenant on the Tenant Root Group | Every preview. It writes nothing. |
| `id-mirror-deploy-demo` | On `rg-demo-pilot`, `rg-demo-network` and `rg-demo-routing`: Contributor and Mirror Lock Writer. On the subscription: Resource Policy Contributor, Mirror Platform Deployment and Role Based Access Control Administrator with a condition. Nothing on `rg-demo-identities` | The production units |
| `id-mirror-govern-demo` | On the subscription: User Access Administrator with a condition, and Mirror Deployment Operator | `demo-privileged` |
| `id-mirror-govern-tenant` | On the Tenant Root Group: User Access Administrator, Management Group Contributor and Mirror Deployment Operator Tenant | The two tenant units |

The condition on the deploy identity's Role Based Access Control Administrator assignment is Microsoft's "allow all except specific roles". It lets the identity assign any role except Owner, Role Based Access Control Administrator and User Access Administrator, and the list of this identity adds the Key Vault and managed identity roles that step 3.15 names. Azure then refuses the identity any write or delete of an assignment of those three roles, even an unchanged record. This is why those records live in the privileged units. Step 3.15 gives the condition.

The govern identity's User Access Administrator assignment carries a condition too. It lets the identity assign Owner, User Access Administrator and Role Based Access Control Administrator, which the privileged unit needs, and refuses it any write or delete of an assignment of the eight Key Vault and managed identity roles. So even the privileged tier cannot grant itself or anyone else a read of the secrets vault or the use of another identity. Step 3.15 gives this condition as well.

The privileged units have their own identities because User Access Administrator together with Contributor is in effect Owner of the subscription. An identity with both could raise its own rights through a change to the code. So the everyday identity can never grant Owner, because of the condition. The govern identity can write those assignments but holds no Contributor, so it can write nothing else. The right to start a deployment comes from the custom role Mirror Deployment Operator, which carries `Microsoft.Resources/deployments/*` and nothing else. The tenant units work at management group scope, and `id-mirror-govern-tenant` holds its three roles on the Tenant Root Group only, with a copy of Mirror Deployment Operator whose assignable scope is the Tenant Root Group.

All the pipeline's identities hold their roles all the time. Privileged Identity Management is meant for people, and Azure cannot give a managed identity an eligible role. The demo uses no PIM.

Five things protect a deploy or govern identity:
- The reviewer. The apply job waits in its environment until the second account reads the plan and approves. Prevent self-review is on, so the person who started the run cannot approve it. The job does not start, and the identity cannot sign in, before that.
- The environment's branch rule, which lets only `master` use the environment.
- The federated credential, bound to that one environment. A pull request, another branch or another environment presents another subject, and Azure refuses it.
- No secret. Nobody can add a client secret to a managed identity.
- The gate step and the tier check. The gate step refuses a deployment whose fresh preview shows anything the reviewed plan and the run's options do not name. Each apply job accepts only a plan of its own tier.

A deploy identity can still assign any role except the three the condition excludes, and Contributor can grant access to data through a resource's own settings. So the reviewer reads a role assignment in a production unit's plan as an access change. The demo's production units declare one, the Reader assignment of `rg-demo-network`, and no data access grants.

Nobody can deploy alone in the normal flow. The person who starts a run cannot approve it. The break-glass is the environment setting **Allow administrators to bypass configured protection rules**, which stays on (step 3.11).

### Demo and project side by side

| Item | Demo | Project |
|---|---|---|
| Tenant | `d1a349ef-6ac8-4588-a88d-5dab272c700b`, the personal tenant | The production tenant |
| Subscriptions | One, the Visual Studio Enterprise Subscription `77488719-1168-4d53-af9a-f5c3bc9291d7`, folder `demo` | Eleven, plus a separate subscription for the identities |
| Where the identities live | `rg-demo-identities`, in the same subscription the units deploy to. The deploy identity holds its roles on the workload groups only, so it cannot write in that group | `rg-mirror-identities` in the platform subscription FDM - Infrastructure, where its deploy identity is kept away from the group in the same way |
| Repository | `themasterishome/demo-bicep-deploy-test`, public, personal account | A private repository in a GitHub Enterprise Cloud organization |
| GitHub plan | Free. Every environment control works on Free for a public repository | Enterprise Cloud, which a private repository needs for required reviewers |
| Reviewers | The second account `klaudiomarashi`, as a user, with Prevent self-review on. A personal repository has no teams | Two approvers teams, `technology-services-platforms` for the production environments and `mirror-privileged-approvers` for the 12 privileged ones, with Prevent self-review on |
| Code owners | `@themasterishome`, plus the second account | The approvers team |
| Units | 7 pipeline units, 4 production and 3 privileged. all seven enabled | 67 pipeline units, 53 production and 14 privileged |
| Identities | 4, with 5 federated credentials | 24, with 25 federated credentials |
| Environments | 5, `mirror-reader`, `mirror-reader-dispatch`, `mirror-production-demo`, `mirror-privileged-demo` and `mirror-privileged-tenant` | 25 |
| Custom roles | 7, which are Mirror What-If Reader, Mirror What-If Reader Tenant, Mirror Lock Writer, Mirror Deployment Operator, Mirror Deployment Operator Tenant, Mirror Key Vault Deployment and Mirror Platform Deployment | 9 |
| Tenant units | Two, against the Tenant Root Group and `mg-demo` | Three, against the Tenant Root Group and `FDMGroupResources` |
| Rulesets | `protect-master` and `protect-tags` | `protect-master`, `protect-github-folder` and `protect-tags`, next to the organization ruleset |
| Retention | 90 days, the longest for a public repository | 365 days |
| Change tickets | Made-up numbers such as `DEMO-0001` | IT's change tickets |

What stays identical:
- the four workflows `mirror-validate`, `mirror-pr`, `mirror-deploy-unit` and `mirror-drift`, with their jobs, inputs and required checks, among them the two apply jobs `apply` and `apply-privileged`
- the helper script and its checks (Select, InputCheck, CheckApply, ComparePlan and the others), and the gate script with its exit codes
- the switch `MIRROR_PIPELINE_ENABLED`, the variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` per environment, and the optional `MIRROR_RUNNER` and `MIRROR_MAX_PLAN_AGE_HOURS`
- the environment names `mirror-reader`, `mirror-reader-dispatch`, `mirror-production-<folder>` and `mirror-privileged-<folder>`, which here are `mirror-production-demo` and `mirror-privileged-demo`, and `mirror-privileged-tenant`, all with the branch rule `master`
- the identities and their roles, with the condition on the deploy identity's Role Based Access Control Administrator assignment
- the OpenID Connect subjects, in the form `repo:OWNER@OWNER_ID/REPOSITORY@REPOSITORY_ID:environment:ENVIRONMENT`, and the lock on the identity group
- the flow, which is a code pull request with a preview, a merge that plans, Run workflow with the options, the approval, the apply, the second check, the evidence and the drift check

What the demo cannot show:
- a team as reviewer and as code owner, and a second, smaller team for the privileged environments, because a personal account has no teams. Here the same second account approves both tiers
- the organization settings, which are the organization ruleset, the restriction on forking, the two-factor requirement, the organization owners and the audit log
- the push ruleset `protect-github-folder` (project step 3.8), because push rulesets exist only for private and internal repositories
- the enterprise issuer of step 3.16, item 3
- PIM, because the demo needs no eligible roles. Owner on the Visual Studio subscription does the set-up, and the demo account already holds User Access Administrator at the Tenant Root Group, so the elevated access of step 3.13 is not needed
- the 16 VPN shared keys that the project's vault holds first. The demo's vault holds one made-up secret, `demo-automation-password`, and the Automation credential reads it. The demo has no Log Analytics workspace of its own, so the vault has no audit log
- a platform subscription of its own. The demo has one subscription, so the identity group sits next to the units and the deploy identity is kept out of it by holding Contributor on the three workload groups only
- the custom roles Mirror Container Writer, Mirror Network Peering and Mirror Budget Writer, which the demo units do not need
- the security alerts of step 3.24, which the demo leaves out
- a private repository. In a public repository anyone can read the runs, the plans and the evidence. The demo estate is made up, so this is safe

The sweep scripts `scripts/whatif-rg-sweep.sh` and `scripts/whatif-sub-sweep.sh` are not part of the demo. The pipeline does not use them.

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
- Owner on the Visual Studio subscription, for the custom roles, the role assignments and the lock
- User Access Administrator at the Tenant Root Group, which the demo account holds already, for the two tenant roles and the role assignments there
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

   The command writes a credential helper for github.com into your global git configuration. That is fine on your own machine. To see what it wrote, run `git config --global --get-regexp "credential.*helper"`. Section 6 removes it.

Every `gh` command in this guide runs as `themasterishome`. The second account works in the browser only, so open a private browser window and sign it in there.

## 3. Set up once

Do the steps in order, because each one needs the steps before it. Each step has the number it has in PIPELINE.md section 3, so you can show the project step next to the demo step. Every Azure command names `--subscription 77488719-1168-4d53-af9a-f5c3bc9291d7`, apart from the `az policy assignment` commands, `az role definition list` and `delete`, and the role assignments and management group commands at the Tenant Root Group. Those take `--scope` or a name and rely on the default subscription set in section 2.

The placeholders used in this section:
- `SECOND_LOGIN` is the second GitHub account's login, `klaudiomarashi`.
- `SECOND_ID` is that account's numeric user ID, from step 3.2.
- `REPOSITORY_ID` is the repository's numeric ID, from step 3.3.
- `WHATIF_ROLE_ID`, `WHATIF_TENANT_ROLE_ID`, `LOCK_ROLE_ID`, `OPERATOR_ROLE_ID`, `OPERATOR_TENANT_ROLE_ID` and `KEYVAULT_ROLE_ID` are the IDs of the custom roles, from step 3.13.
- `READER_CLIENT`, `READER_PRINCIPAL`, `DEPLOY_CLIENT`, `DEPLOY_PRINCIPAL`, `GOVERN_CLIENT`, `GOVERN_PRINCIPAL`, `TENANT_CLIENT` and `TENANT_PRINCIPAL` are the `clientId` and `principalId` of the four identities, from steps 3.14 and 3.15.

The owner ID of `themasterishome` is `49098959`. Step 3.2 reads it again, so you can show where it comes from.

The steps fall into the same groups as the project's:
- 3.1 to 3.11 in GitHub
- 3.12 to 3.17 in Azure and GitHub
- 3.18 and 3.19 in GitHub
- 3.20 turns the pipeline on
- 3.21 to 3.23 are the first runs
- 3.24 is left out

### 3.0 If you run the demo alone

With one account, nobody can approve what that account started while Prevent self-review is on. The apply job would wait and fail after 30 days. A pull request author cannot approve their own pull request either. So the one-account demo changes three settings, and shows Prevent self-review only by explaining it:
- Step 3.4 leaves CODEOWNERS as it is.
- Step 3.7 sets **Required approvals** to 0 and leaves **Require review from Code Owners** off. A pull request is still required, and so are the six checks.
- Step 3.11 lists only you as reviewer of `mirror-production-demo`, `mirror-privileged-demo` and `mirror-privileged-tenant`, with Prevent self-review off. You then start every run and approve it yourself.

Skip every item that says to approve the pull request as the second account (4.2 item 3, 4.3 item 3, 4.5 item 3, 4.6 item 3, 4.7 item 3, 4.8 item 3 and 4.10 item 2), and merge the pull request yourself. Where an item says to approve a deployment as the second account, you approve it yourself.

Everything else is the same. An earlier run of these steps used exactly this variant.

### 3.1 Check the plan

The project checks that the organization is on Enterprise Cloud. The demo needs no paid plan, because GitHub offers environments, required reviewers, Prevent self-review, deployment branch rules, rulesets and code owners on Free for a public repository.

```powershell
gh api user --jq "{login: .login, plan: .plan.name}"
```

The output names `themasterishome` and its plan, for example `free`. Any plan works for a public repository.

### 3.2 Check the approvers

The project checks that its two approvers teams have at least two IT people each, and creates the second team, `mirror-privileged-approvers`, in item 7. A personal repository has no teams, so the demo's reviewer for both tiers is the second account, as a user.

1. Read the numeric IDs of both accounts. The environments and the policy need them.

   ```powershell
   gh api users/themasterishome --jq .id
   gh api users/SECOND_LOGIN --jq .id
   ```

   Replace `SECOND_LOGIN` with the second account's login. The first command prints `49098959`. Keep the second number as `SECOND_ID`. There is no browser route for this step, so use the commands.

2. Check that you know who will act as which person in the demo. You, `themasterishome`, write the code, merge and start every run. The second account reviews pull requests and approves deployments.

### 3.3 Create the repository

1. Create an empty public repository, with no README, license or `.gitignore`, so the first push is not refused.

   ```powershell
   gh repo create themasterishome/demo-bicep-deploy-test --public
   ```

   The output ends with `https://github.com/themasterishome/demo-bicep-deploy-test`. The project creates a private repository in the organization.

2. Invite the second account as a collaborator. In your own browser window, open the repository `https://github.com/themasterishome/demo-bicep-deploy-test`. Select **Settings** > **Collaborators** (under **Access**) > **Add people**, type `SECOND_LOGIN`, and select **Add SECOND_LOGIN to this repository**. The invitation is sent by e-mail. In the private browser window, open the e-mail's link, or `https://github.com/themasterishome/demo-bicep-deploy-test/invitations`, and select **Accept invitation**. A collaborator on a personal repository has write access, which a code owner and a pull request reviewer need. The project gives the approvers team write access instead.

3. Project items 3 and 4 (forking off, two-factor requirement) are organization settings. A personal account has neither. Forks of a public repository cannot be switched off, so step 3.6 limits what a fork's pull request can run.

Check the repository and keep its ID.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test --jq "{private: .private, id: .id, owner_id: .owner.id}"
```

The output is a line like `{"id":123456789,"owner_id":49098959,"private":false}`. Keep `id` as `REPOSITORY_ID`. Step 3.16 needs it.

After the invitation is accepted, check who holds which access.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/collaborators --jq ".[] | {login: .login, admin: .permissions.admin, push: .permissions.push}"
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
   git remote add origin https://github.com/themasterishome/demo-bicep-deploy-test.git
   git push -u origin master
   ```

2. Check that the remote has the branch.

   ```powershell
   git ls-remote origin master
   ```

   The output is one line, the commit ID then `refs/heads/master`.

3. Check the default branch. An empty repository takes its default branch name from your personal setting, which is `main` unless you changed it under your profile's **Settings** > **Repositories**. It can still show `main` after the push of `master`.

   ```powershell
   gh api repos/themasterishome/demo-bicep-deploy-test --jq .default_branch
   ```

   The output must be `master`. If it is not, set it and run the check again. An earlier run of these steps showed `main` after the first push, and this command fixed it.

   ```powershell
   gh api --method PATCH repos/themasterishome/demo-bicep-deploy-test -f default_branch=master --jq .default_branch
   ```

   To show it in the browser, open the repository and select **Settings** > **General**. Under **Default branch**, select the switch icon to the right of the branch name. In the dropdown, select `master` and select **Update**. Read the warning, then select **I understand, update the default branch.** GitHub offers this switch only when the repository has more than one branch. At this step the repository has one, so the command above is the route, and the browser route works once a second branch exists.

   Do this now, before step 3.7. **Run workflow** lists only workflows that exist on the default branch, and once the ruleset blocks force pushes, an administrator cannot change the default branch without a bypass.

The push starts mirror-validate and mirror-deploy-unit. Every job of both shows as skipped, because the switch is not set yet (step 3.20). No runner starts and nothing signs in to Azure.

### 3.6 Set the Actions settings

In the repository, select **Settings**. In the left sidebar select **Actions**, then **General**. The page has one section per setting below, and each section has its own **Save** button. Set the following.

| Setting | Value | Why |
|---|---|---|
| Actions permissions | **Allow themasterishome, and select non-themasterishome, actions and reusable workflows**, with **Allow actions created by GitHub** ticked and `azure/login@*` in **Allow or block specified actions and reusable workflows** | The workflows use only `actions/checkout`, `actions/upload-artifact`, `actions/download-artifact` and `azure/login`. |
| Require actions to be pinned to a full-length commit SHA | On | An action's owner can move a tag, not a commit SHA. The four pins are full SHAs. |
| Check, workflow run, status, artifact and log retention | **90** days | Check that it shows 90, which is the default and the maximum for a public repository. The project sets 365, which a private repository allows. |
| Approval for running fork pull request workflows from contributors | **Require approval for all external contributors** | A public repository can always be forked. The project switches forking off instead. A fork's pull request also gets a read-only token and no `id-token: write`, so it cannot sign in to Azure. |
| Workflow permissions | **Read repository contents and packages permissions** | Each job asks for its few extra rights itself. |
| Allow GitHub Actions to create and approve pull requests | Off | A workflow must never approve or merge a pull request. It is off by default on a personal repository. |

Under **Actions permissions**, select the option shown in the table. It adds the choices **Allow actions created by GitHub** and **Allow or block specified actions and reusable workflows**. Tick the first, type `azure/login@*` in the box of the second, and select **Save**. Separate several patterns with a comma. The setting **Require actions to be pinned to a full-length commit SHA** sits in the same section. The retention box is labeled **Check, workflow run, status, artifact and log retention**.

Select **Save** under each section you change. To check, reload the page and confirm each value. A run of these steps checked the same values through the REST API on a public Free repository, and all of them held.

### 3.7 Create the branch ruleset protect-master

The project's organization ruleset already blocks force pushes and branch deletion, so its repository ruleset adds only the code owner review and the checks. The demo has no organization ruleset, so its ruleset carries everything.

1. In the repository, select **Settings**. In the left sidebar, under "Code, planning, and automation", click **Rulesets**, then click **Rulesets**. If the sidebar shows **Rules** instead, expand it and select **Rulesets**. Select **New ruleset**, then **New branch ruleset**.
2. Set the following. The page follows this order: the name, the enforcement status, the bypass list, the target branches, then the branch rules.

   | Setting | Value |
   |---|---|
   | Ruleset name | `protect-master` |
   | Enforcement status | **Active**. A new ruleset starts as **Disabled**, so select **Disabled** and then **Active** |
   | Bypass list | Empty |
   | Target branches | **Add a target** > **Include default branch** |
   | Restrict deletions | On (on by default) |
   | Block force pushes | On (on by default) |
   | Require a pull request before merging | On, with **Required approvals** 1, or 0 when you run alone |
   | Require review from Code Owners | On, or off when you run alone. It is one of the options under the pull request rule |
   | Allowed merge methods | **Squash** only. It is also an option under the pull request rule. The push run and the change ticket lookup expect one commit per pull request |
   | Require status checks to pass before merging | On, with **Require branches to be up to date before merging** |

   The run of these steps on a public Free repository ended with the rules deletion, non-fast-forward and pull request (squash only) on the branch ruleset.

3. Select **Create**. A ruleset in **Active** status takes effect at once.

Leave the list of status checks empty for now. A check name is offered only after its job has run once, and step 3.21 adds the six names. Until step 3.20 every job is skipped, and GitHub treats a skipped required check as passed. So until then only the review holds a merge back, as in the project.

If the page refuses to save while **Require status checks to pass before merging** is on and no check is listed, turn that rule off, save, and turn it on at step 3.21.

Check the ruleset.

```powershell
gh api repos/themasterishome/demo-bicep-deploy-test/rulesets --jq ".[] | {name, target, enforcement}"
```

The output has a line for `protect-master` with `"target":"branch"` and `"enforcement":"active"`.

### 3.8 The push ruleset (not in the demo)

The project's push ruleset `protect-github-folder` lets only the approvers team push a change under `.github/`. Push rulesets exist only for private and internal repositories, so the demo has none. In the demo, `.github/` is protected by `protect-master` and the code owner review only. Tell the audience that this is the one project control the demo leaves out.

### 3.9 Create the tag ruleset protect-tags

This stops anyone creating a tag that looks like a deployable reference, as in the project.

1. Go back to **Settings** > **Rulesets** > **Rulesets** and select **New ruleset** > **New tag ruleset**.
2. Name it `protect-tags` and set **Enforcement status** to **Active**.
3. Leave the bypass list empty.
4. Under "Target tags", select **Add a target** > **Include all tags**.
5. Turn on **Restrict creations**, **Restrict updates** and **Restrict deletions**, and select **Create**.

Check that `gh api repos/themasterishome/demo-bicep-deploy-test/rulesets --jq ".[].name"` lists `protect-master` and `protect-tags`.

### 3.10 Turn on push protection

Secret scanning already runs on every public repository for free. Push protection for the repository is off by default. In the repository, select **Settings**. In the left sidebar, in the section "Security and quality" ("Security" in older layouts), select **Advanced Security**. If **Secret Protection** is not enabled yet, select **Enable** to the right of it first. In the Secret Protection section, select **Enable** to the right of **Push protection**. The run of these steps confirmed that push protection was on afterwards. The project needs GitHub Secret Protection in its plan for the same switch. In both, the Gitleaks scan of mirror-validate catches what push protection misses.

### 3.11 Create the 5 environments

The project has 25 environments, one per identity that deploys, two for the reader, and a production and a privileged one for each of its 11 subscriptions. The demo has one subscription and one tenant, so it has five.

| Environment | Reviewers | Deployment branches | Used by |
|---|---|---|---|
| `mirror-reader` | None | No restriction, because the previews run on pull request branches | mirror-pr `whatif` |
| `mirror-reader-dispatch` | None | **Selected branches and tags**, one branch rule `master` | mirror-deploy-unit `plan`, mirror-drift `drift` |
| `mirror-production-demo` | The second account, with **Prevent self-review** on | **Selected branches and tags**, one branch rule `master` | mirror-deploy-unit `apply` |
| `mirror-privileged-demo` | The second account, with **Prevent self-review** on | **Selected branches and tags**, one branch rule `master` | mirror-deploy-unit `apply-privileged` for `demo-privileged` |
| `mirror-privileged-tenant` | The second account, with **Prevent self-review** on | **Selected branches and tags**, one branch rule `master` | mirror-deploy-unit `apply-privileged` for the two tenant units |

The project lists the approvers team as reviewers of the production environments and a second, smaller team, `mirror-privileged-approvers`, as reviewers of the privileged ones. A personal repository has no teams, so the demo lists the second account, as a user, in all three. Say so to the audience, because it is the one place where the two tiers share a reviewer.

Create all five before the switch. A workflow that names an environment that does not exist creates it without reviewers or branch rule. There is one environment per identity, because a federated credential is bound to one environment name.

Create them in a PowerShell window. The commands are the main route. To show one environment in the browser, select **Settings** > **Environments** > **New environment**, type the name and select **Configure environment**. For `mirror-production-demo`, tick **Required reviewers**, search for and select the second account, tick **Prevent self-review** and select **Save protection rules**. In the **Deployment branches** dropdown, select **Selected branches and tags**, select **Add deployment branch or tag rule**, keep the ref type **Branch**, type `master` and select **Add rule**.

```powershell
$repo = 'themasterishome/demo-bicep-deploy-test'
$branchPolicy = @{ protected_branches = $false; custom_branch_policies = $true }
gh api --method PUT "repos/$repo/environments/mirror-reader" | Out-Null
@{ deployment_branch_policy = $branchPolicy } | ConvertTo-Json -Depth 4 |
  gh api --method PUT "repos/$repo/environments/mirror-reader-dispatch" --input - | Out-Null
gh api --method POST "repos/$repo/environments/mirror-reader-dispatch/deployment-branch-policies" -f name=master -f type=branch | Out-Null
Write-Host 'created mirror-reader-dispatch'
foreach ($e in 'mirror-production-demo', 'mirror-privileged-demo', 'mirror-privileged-tenant') {
  @{ wait_timer = 0; prevent_self_review = $true
     reviewers = @(@{ type = 'User'; id = SECOND_ID })
     deployment_branch_policy = $branchPolicy } |
    ConvertTo-Json -Depth 5 | gh api --method PUT "repos/$repo/environments/$e" --input - | Out-Null
  gh api --method POST "repos/$repo/environments/$e/deployment-branch-policies" -f name=master -f type=branch | Out-Null
  Write-Host "created $e"
}
```

Replace `SECOND_ID` with the number from step 3.2. If you run alone, use `prevent_self_review = $false` and `id = 49098959`. The project lists the teams (`type = 'Team'`). The output is four lines, `created mirror-reader-dispatch`, `created mirror-production-demo`, `created mirror-privileged-demo` and `created mirror-privileged-tenant`.

Check the five environments.

```powershell
$repo = 'themasterishome/demo-bicep-deploy-test'
gh api "repos/$repo/environments" --jq ".environments[].name"
gh api "repos/$repo/environments/mirror-production-demo" --jq ".protection_rules"
gh api "repos/$repo/environments/mirror-privileged-demo" --jq ".protection_rules"
gh api "repos/$repo/environments/mirror-privileged-tenant/deployment-branch-policies" --jq ".branch_policies[].name"
gh api "repos/$repo/environments/mirror-production-demo/deployment-branch-policies" --jq ".branch_policies[].name"
gh api "repos/$repo/environments/mirror-reader-dispatch/deployment-branch-policies" --jq ".branch_policies[].name"
```

The first command lists the five names. The second and the third each show a `required_reviewers` rule with `prevent_self_review` true and the second account, and a `branch_policy` rule. The last three print `master`. Run the branch check for `mirror-privileged-demo` the same way. If a branch check prints nothing, add the rule with the `gh api --method POST` line of the script for that environment.

Never add another rule to `mirror-reader-dispatch` or to a production or privileged environment. A rule such as `refs/pull/*/merge` on one of them would let a pull request deploy.

Keep **Allow administrators to bypass configured protection rules** on, as GitHub's default and as the project does. It is the break-glass route. You, as the repository's admin, can then use **Start all waiting jobs** on a waiting run, after a comment. The REST call has no field for it, so it is a setting under **Settings** > **Environments** > `mirror-production-demo` only. Check that the box **Allow administrators to bypass configured protection rules** is ticked, and leave it.

### 3.12 Create the resource group for the identities

The project puts the identities in a group of the platform subscription. The demo has one subscription, so the group sits next to the units (section 1). Your CLI default is already the Visual Studio subscription (section 2).

1. Create the group.

   ```powershell
   az group create --name rg-demo-identities --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy
   ```

   The output is the group in JSON, with `"provisioningState": "Succeeded"`.

2. Lock the group against deletion. The lock stops anyone deleting the identities or their credentials.

   ```powershell
   az lock create --name mirror-identities-no-delete --lock-type CanNotDelete --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   ```

   The output is the lock in JSON, with `"level": "CanNotDelete"`. The portal shows this lock type as **Delete**.

3. Project item 3 assigns a built-in policy that audits federated credentials against a list of trusted GitHub owners. The demo skips it. The demo has one owner, a personal account, and its five credentials are the only ones in the group, so the policy has nothing to separate. The group is still protected the way the project's is, because no pipeline identity can write in it. Steps 3.17 items 3 to 5 and section 6 item 2 skip the policy as well.

4. Project item 4 (an eligible PIM assignment of Managed Identity Contributor) is left out. Your Owner on the subscription covers the demo.

5. Create the secrets vault, as project item 5 does with `kv-mirror-secrets`. The demo's vault is `kv-demo-mirror-secrets`, because `kv-demo-secrets` was taken by another tenant. It has Azure role-based access, soft delete for 90 days, purge protection, access for template deployments, and a firewall that denies every address except Azure's trusted services. It is created with public network access disabled from the start.

   ```powershell
   az keyvault create --name kv-demo-mirror-secrets --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth --sku standard `
     --enable-rbac-authorization true --retention-days 90 --enable-purge-protection true --enabled-for-template-deployment true `
     --public-network-access Disabled --default-action Deny --bypass AzureServices --tags purpose=demo-bicep-deploy
   ```

   The output is the vault in JSON, with `"publicNetworkAccess": "Disabled"`. A vault name is global, so a name that is taken fails with `VaultAlreadyExists`. Pick another and use it everywhere below.

   The private endpoint, the zone and the zone group come with the unit `rg-demo-network` (wave 1), which declares them. The vault must exist before that unit runs, because the endpoint points at it. The audit log of the project's vault goes to a Log Analytics workspace, and the demo subscription has none of its own, so the demo vault has no audit setting.

   Give your own account the role Key Vault Secrets Officer on the vault, so you can write a secret. Replace `YOUR_OBJECT_ID` with the object ID of your signed-in account.

   ```powershell
   az role assignment create --assignee-object-id YOUR_OBJECT_ID --assignee-principal-type User --role "Key Vault Secrets Officer" --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-identities/providers/Microsoft.KeyVault/vaults/kv-demo-mirror-secrets
   ```

   The output is the assignment in JSON. The project writes secrets through the vault's private endpoint from a machine on the network. The demo has no such machine, so the one secret is written through a temporary opening. Open the vault to your address, write the secret from a file so the value never appears on a command line, and close the vault again.

   ```powershell
   $kv = 'kv-demo-mirror-secrets'
   $rg = 'rg-demo-identities'
   $sub = '77488719-1168-4d53-af9a-f5c3bc9291d7'
   $myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org').Trim()
   az keyvault update --name $kv --resource-group $rg --subscription $sub --public-network-access Enabled --default-action Deny --bypass AzureServices -o none
   az keyvault network-rule add --name $kv --resource-group $rg --subscription $sub --ip-address $myIp -o none
   $tmp = Join-Path $env:TEMP 'demo-secret.txt'
   [IO.File]::WriteAllText($tmp, [guid]::NewGuid().ToString('N') + 'Aa1!')
   Start-Sleep -Seconds 60
   az keyvault secret set --vault-name $kv --subscription $sub --name demo-automation-password --file $tmp --encoding utf-8 --content-type demo-password --query "{name:name, enabled:attributes.enabled}" -o json
   Remove-Item $tmp -Force
   az keyvault network-rule remove --name $kv --resource-group $rg --subscription $sub --ip-address $myIp -o none
   az keyvault update --name $kv --resource-group $rg --subscription $sub --public-network-access Disabled --query "{publicAccess:properties.publicNetworkAccess, defaultAction:properties.networkAcls.defaultAction, bypass:properties.networkAcls.bypass}" -o json
   ```

   The first output names the secret with `"enabled": true`. The last one prints `Disabled`, `Deny` and `AzureServices`. A firewall change takes up to a minute to apply, which is why the block waits before the write. If the write answers Forbidden, wait and run it again. Nothing prints the value.

Check the lock.

```powershell
az lock list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, level:level}" -o table
```

The output lists `mirror-identities-no-delete` with `CanNotDelete`.

The group is also written down as code, in `infra/subscriptions/demo/resource-groups/rg-demo-identities.deploy-excluded.bicep`. It declares the four identities with their federated credentials, the vault and the two role assignments on it, as they are live. `main.bicep` calls the file only when `deployIdentityGroup` is true. `parameters.bicepparam` leaves it false, so the unit `demo-subscription` never writes the group's contents, and the deploy identity could not anyway. `parameters.verify.bicepparam` sets it true, so a preview shows the contents. Check them against live after steps 3.12 to 3.17, read-only.

```powershell
az deployment sub what-if --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth --template-file infra/subscriptions/demo/main.bicep --parameters infra/subscriptions/demo/parameters.verify.bicepparam --no-pretty-print -o json
```

The preview reports `NoChange` for the four identities, their five credentials, the vault and its two role assignments. Never deploy with the verify file. The lock of item 2 is not declared in the file, because the demo sets it by hand.

### 3.13 Create the custom roles

The project needs nine custom roles, and the demo needs seven. Each carries only the actions its identity needs, so no pipeline identity holds more than its units use.

| Role | Actions | Held by |
|---|---|---|
| Mirror What-If Reader | `Microsoft.Resources/deployments/whatIf/action` | The reader |
| Mirror What-If Reader Tenant | The same action, assignable at the Tenant Root Group only | The reader |
| Mirror Lock Writer | `Microsoft.Authorization/locks/*` | The deploy identity |
| Mirror Deployment Operator | `Microsoft.Resources/deployments/*` and `Microsoft.Resources/subscriptions/resourceGroups/read` | The govern identity |
| Mirror Deployment Operator Tenant | The same actions, plus `Microsoft.Management/managementGroups/read` and `Microsoft.Management/managementGroups/subscriptions/read`, assignable at the Tenant Root Group only | `id-mirror-govern-tenant` |
| Mirror Key Vault Deployment | `Microsoft.KeyVault/vaults/deploy/action` and `Microsoft.KeyVault/vaults/PrivateEndpointConnectionsApproval/action` | The deploy identity, on the vault `kv-demo-mirror-secrets` only |
| Mirror Platform Deployment | `Microsoft.Resources/deployments/*`, `Microsoft.Resources/subscriptions/resourceGroups/read`, `Microsoft.Resources/subscriptions/resourceGroups/write`, `Microsoft.Security/pricings/read` and `Microsoft.Security/pricings/write` | The deploy identity, at the subscription |

The reasons are these:
- Mirror What-If Reader adds the one action Reader lacks for a preview at the validation level `ProviderNoRbac`, which every preview in this folder uses. The Tenant Root Group needs its own copy, because a custom role on a management group may name only one scope, and it cannot mix scopes. The project lists 11 subscriptions as the scopes of the first, and the demo one.
- Mirror Lock Writer exists because only Owner and User Access Administrator carry `Microsoft.Authorization/locks/*`, and the deploy identity holds neither. The production unit `rg-demo-network` writes a lock.
- Mirror Deployment Operator exists because User Access Administrator lacks the deployment actions, so the govern identity needs a role to start a deployment. It carries nothing else. The tenant copy adds the two read actions on management groups that a deployment at management group scope needs.
- Mirror Key Vault Deployment carries two rights, both on the vault only. The first lets a template read a secret through a reference. It does not let the identity read the secret itself, because Azure Resource Manager does that. The second is what Azure checks when a deployment writes a private endpoint that points at the vault, because the endpoint's connection is approved on the vault's side. Without it Azure refuses the write of `pe-kv-demo-mirror-secrets` with `LinkedAuthorizationFailed`, although the identity may write endpoints in its own group, and a preview does not show the refusal.
- Mirror Platform Deployment exists because the deploy identity holds Contributor on the workload groups only. A subscription-scope deployment needs `Microsoft.Resources/deployments/*` at the subscription, a resource group declared in `main.bicep` needs the write on resource groups, and the Defender plan needs the write on pricings. It never deletes or moves a group.

1. Create the seven roles. This needs Owner or User Access Administrator on the subscription and on the identity resource group. The two roles whose scope is the Tenant Root Group need the same right there, and the demo account holds User Access Administrator at the Tenant Root Group already, so no elevated access is needed. If a command prints `AuthorizationFailed` for one of those two roles, the signed-in account lacks that right, and project step 3.13 shows the elevated access that gives it.

   ```powershell
   $folder = 'C:\demo-setup\roles'
   New-Item -ItemType Directory -Force -Path $folder | Out-Null
   $sub = '/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7'
   $root = '/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'
   $vaultGroup = "$sub/resourceGroups/rg-demo-identities"
   $roles = @(
     @{ Name = 'Mirror What-If Reader'; Description = 'Preview deployments with what-if. Changes no resource.'
        Actions = @('Microsoft.Resources/deployments/whatIf/action'); Scopes = @($sub) },
     @{ Name = 'Mirror What-If Reader Tenant'; Description = 'Preview deployments with what-if at the Tenant Root Group. Changes no resource.'
        Actions = @('Microsoft.Resources/deployments/whatIf/action'); Scopes = @($root) },
     @{ Name = 'Mirror Lock Writer'; Description = 'Create, change and delete resource locks. Changes nothing else.'
        Actions = @('Microsoft.Authorization/locks/*'); Scopes = @($sub) },
     @{ Name = 'Mirror Deployment Operator'; Description = 'Start and read deployments. Changes nothing else.'
        Actions = @('Microsoft.Resources/deployments/*', 'Microsoft.Resources/subscriptions/resourceGroups/read'); Scopes = @($sub) },
     @{ Name = 'Mirror Deployment Operator Tenant'; Description = 'Start and read deployments at the Tenant Root Group. Changes nothing else.'
        Actions = @('Microsoft.Resources/deployments/*', 'Microsoft.Resources/subscriptions/resourceGroups/read',
                    'Microsoft.Management/managementGroups/read', 'Microsoft.Management/managementGroups/subscriptions/read'); Scopes = @($root) },
     @{ Name = 'Mirror Key Vault Deployment'; Description = 'Let a template deployment read secrets of this vault through a reference, and let a private endpoint in another group connect to it.'
        Actions = @('Microsoft.KeyVault/vaults/deploy/action', 'Microsoft.KeyVault/vaults/PrivateEndpointConnectionsApproval/action'); Scopes = @($vaultGroup) },
     @{ Name = 'Mirror Platform Deployment'; Description = 'Deploy at subscription scope, write resource groups and the Defender plans. Changes nothing else.'
        Actions = @('Microsoft.Resources/deployments/*', 'Microsoft.Resources/subscriptions/resourceGroups/read', 'Microsoft.Resources/subscriptions/resourceGroups/write',
                    'Microsoft.Security/pricings/read', 'Microsoft.Security/pricings/write'); Scopes = @($sub) }
   )
   foreach ($r in $roles) {
     $file = Join-Path $folder ("$($r.Name -replace '[^A-Za-z0-9]+', '-').json")
     $json = [ordered]@{ Name = $r.Name; IsCustom = $true; Description = $r.Description; Actions = @($r.Actions); NotActions = @(); AssignableScopes = @($r.Scopes) } |
       ConvertTo-Json -Depth 4
     [System.IO.File]::WriteAllText($file, $json)
     az role definition create --role-definition $file --only-show-errors -o none
     Write-Host "created $($r.Name)"
   }
   ```

   The command writes one JSON file per role under `C:\demo-setup\roles`, outside the repository. The output is seven lines, `created Mirror What-If Reader` to `created Mirror Platform Deployment`. If a command fails because a role of that name exists, an earlier demo left it behind. Delete it as section 6 shows, or use it.

2. Check that each role exists with the scope you expect.

   ```powershell
   az role definition list --custom-role-only true --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[?starts_with(roleName, 'Mirror')].{role:roleName, scopes:assignableScopes}" -o json
   ```

   The output lists the roles that include the subscription, which are Mirror What-If Reader, Mirror Lock Writer, Mirror Deployment Operator and Mirror Platform Deployment. Check the other three by name with `az role definition list --name "ROLE_NAME"`, adding `--scope` with the Tenant Root Group path for the two tenant roles and the identity resource group for Mirror Key Vault Deployment. A new role takes a short while to replicate. If a command prints nothing, wait a minute and run it again.

3. Read the ID of each role. The set-up commands assign every role by its ID, not its name, because a name can match a second role and an ID cannot.

   ```powershell
   az role definition list --name "ROLE_NAME" --scope SCOPE --query "[0].name" -o tsv
   ```

   Replace `ROLE_NAME` with a role's name and `SCOPE` with one of its assignable scopes, for example `/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7`. The output is one GUID, new each time the role is created. Keep one per role as `WHATIF_ROLE_ID`, `WHATIF_TENANT_ROLE_ID`, `LOCK_ROLE_ID`, `OPERATOR_ROLE_ID`, `OPERATOR_TENANT_ROLE_ID` and `KEYVAULT_ROLE_ID`.

4. Project item 4 gives the approvers team these roles too, because a writer can read the previews. In a public repository anyone can read them, so the demo skips it.

### 3.14 Create the reader identity and grant its roles

The reader identity runs every pipeline preview: pull request previews, the plan of every deployment and the drift check. It holds Reader and Mirror What-If Reader on the subscription and on the Tenant Root Group at all times, and no write right. It is a user-assigned managed identity, because nobody can add a client secret to one.

1. Create the identity.

   ```powershell
   az identity create --name id-mirror-reader --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth
   ```

   The output is the identity in JSON. Keep `clientId` as `READER_CLIENT` and `principalId` as `READER_PRINCIPAL`. The output IDs replace the value of `readerPrincipalId` in `rg-demo-network.bicepparam` and `governance.mg-demo.bicepparam` only if they differ.
2. Grant Reader and Mirror What-If Reader on the subscription, and the same two on the Tenant Root Group, with the Tenant Root Group copy of Mirror What-If Reader.

   ```powershell
   $sub = '/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7'
   $root = '/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'
   foreach ($roleId in 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'WHATIF_ROLE_ID') {
     az role assignment create --assignee-object-id READER_PRINCIPAL --assignee-principal-type ServicePrincipal `
       --role $roleId --scope $sub --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o none
   }
   foreach ($roleId in 'acdd72a7-3385-48ef-bd42-f606fba81ae7', 'WHATIF_TENANT_ROLE_ID') {
     az role assignment create --assignee-object-id READER_PRINCIPAL --assignee-principal-type ServicePrincipal `
       --role $roleId --scope $root -o none
   }
   ```

   Replace `READER_PRINCIPAL`, `WHATIF_ROLE_ID` and `WHATIF_TENANT_ROLE_ID`. `acdd72a7-3385-48ef-bd42-f606fba81ae7` is the built-in Reader role. Each command prints nothing when it succeeds. If one says the role does not exist, the new role has not replicated yet. Wait a minute and run it again. The reader then previews the two tenant units, which have no subscription.

3. Check the assignments.

   ```powershell
   az role assignment list --assignee-object-id READER_PRINCIPAL --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, role:roleDefinitionName, scope:scope}" -o table
   az role assignment list --assignee-object-id READER_PRINCIPAL --scope /providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b --query "[?scope=='/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'].{role:roleDefinitionName, scope:scope}" -o table
   ```

   The first output has two rows, Reader and Mirror What-If Reader, on `/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7`. The second lists Reader and Mirror What-If Reader Tenant on the Tenant Root Group. A new role assignment can take about 10 minutes to take effect.

4. Project item 4 declares these assignments in the code after the pilot. The demo leaves it out, because `demo-privileged` declares only the Owner assignment and the role `Demo Reader Plus`, to show what a privileged unit holds.

### 3.15 Create the deploy and govern identities

The project creates two identities per subscription, because every subscription has units of both tiers, and one more for the tenant units. That makes 23 beside the reader. The demo has one subscription, so it creates three.
- `id-mirror-deploy-demo`, for the production units
- `id-mirror-govern-demo`, for `demo-privileged`
- `id-mirror-govern-tenant`, for the two tenant units

Each identity holds its standing roles on its own scope only. Never give a deploy identity User Access Administrator or Owner, and never give a govern identity Contributor. The gate step's identity check reads the subscriptions the sign-in can see, and a role at subscription scope keeps the demo subscription in that list. So the deploy identity holds some of its roles on the subscription and its Contributor on the workload groups only.

1. Create the identities.

   ```powershell
   foreach ($n in 'id-mirror-deploy-demo', 'id-mirror-govern-demo', 'id-mirror-govern-tenant') {
     az identity create --name $n --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --location uksouth --query "{name:name, clientId:clientId, principalId:principalId}" -o json
   }
   ```

   Keep the IDs as `DEPLOY_CLIENT`, `DEPLOY_PRINCIPAL`, `GOVERN_CLIENT`, `GOVERN_PRINCIPAL`, `TENANT_CLIENT` and `TENANT_PRINCIPAL`. The parameter files already hold the `principalId` values of identities created earlier, which are current. If the output differs from them, put the output values into `rg-demo-network.bicepparam`, `privileged.bicepparam` and `governance.mg-demo.bicepparam`. The reader's `principalId` is `readerPrincipalId` in the first and third, and `id-mirror-govern-demo`'s is `ownerPrincipalId` in the second.

2. Give the deploy identity its roles. Contributor and Mirror Lock Writer go on each of the three workload groups and never on the subscription or on `rg-demo-identities`, so the lock on the identity group holds against this identity and it cannot grant itself a read of anything stored there. Azure cannot carve one group out of a subscription-scope role, which is why these two are given per group. A group added later needs the same two assignments. Resource Policy Contributor writes the policy assignment of `rg-demo-network` and Mirror Platform Deployment lets a subscription-scope deployment run and write the declared groups and the Defender plan, both at the subscription. Role Based Access Control Administrator writes the Reader assignment, also at the subscription. It carries the condition of project section 1.5, "allow all except specific roles", with Owner (`8e3af657-a8ff-443c-a75c-2fe8c4bcb635`), Role Based Access Control Administrator (`f58310d9-a9f6-439a-9e8d-f62e7b41a168`) and User Access Administrator (`18d7d88d-d35e-4fb5-a5c3-7773c20a72d9`) excluded. For this identity the list holds eight more roles that the demo declares nowhere, which are Key Vault Administrator (`00482a5a-887f-4fb3-b363-3b7fe8e74483`), Key Vault Secrets Officer (`b86a8fe4-44ce-4948-aee5-eccb2c155cd7`), Key Vault Secrets User (`4633458b-17de-408a-b874-0445c86b69e6`), Key Vault Certificate User (`db79e9a7-68ee-4b58-9aeb-b90e7c24fcba`), Key Vault Data Access Administrator (`8b54135c-b56d-4d72-a534-26097cfdc8d8`), Key Vault Contributor (`f25e0fa2-a7c8-4377-a976-54943a77a395`), Managed Identity Contributor (`e40ec5ca-96e0-45a2-b4ff-59039f2c2b59`) and Managed Identity Operator (`f1a07417-d97a-45cb-824c-7a7467783830`). Without them a deploy identity could grant itself access to a secrets vault or act as another identity.

   ```powershell
   $sub = '/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7'
   $condition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, 00482a5a-887f-4fb3-b363-3b7fe8e74483, b86a8fe4-44ce-4948-aee5-eccb2c155cd7, 4633458b-17de-408a-b874-0445c86b69e6, db79e9a7-68ee-4b58-9aeb-b90e7c24fcba, 8b54135c-b56d-4d72-a534-26097cfdc8d8, f25e0fa2-a7c8-4377-a976-54943a77a395, e40ec5ca-96e0-45a2-b4ff-59039f2c2b59, f1a07417-d97a-45cb-824c-7a7467783830})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {8e3af657-a8ff-443c-a75c-2fe8c4bcb635, f58310d9-a9f6-439a-9e8d-f62e7b41a168, 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9, 00482a5a-887f-4fb3-b363-3b7fe8e74483, b86a8fe4-44ce-4948-aee5-eccb2c155cd7, 4633458b-17de-408a-b874-0445c86b69e6, db79e9a7-68ee-4b58-9aeb-b90e7c24fcba, 8b54135c-b56d-4d72-a534-26097cfdc8d8, f25e0fa2-a7c8-4377-a976-54943a77a395, e40ec5ca-96e0-45a2-b4ff-59039f2c2b59, f1a07417-d97a-45cb-824c-7a7467783830}))"
   foreach ($group in 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') {
     foreach ($roleId in 'b24988ac-6180-42a0-ab88-20f7382dd24c', 'LOCK_ROLE_ID') {
       az role assignment create --assignee-object-id DEPLOY_PRINCIPAL --assignee-principal-type ServicePrincipal `
         --role $roleId --scope "$sub/resourceGroups/$group" --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o none
     }
   }
   foreach ($roleId in '36243c78-bf99-498c-9df9-86d9f8d28608', 'PLATFORM_ROLE_ID') {
     az role assignment create --assignee-object-id DEPLOY_PRINCIPAL --assignee-principal-type ServicePrincipal `
       --role $roleId --scope $sub --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o none
   }
   az role assignment create --assignee-object-id DEPLOY_PRINCIPAL --assignee-principal-type ServicePrincipal `
     --role f58310d9-a9f6-439a-9e8d-f62e7b41a168 --scope $sub --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
     --condition $condition --condition-version 2.0 -o none
   ```

   Replace `DEPLOY_PRINCIPAL`, `LOCK_ROLE_ID` and `PLATFORM_ROLE_ID`. `b24988ac-6180-42a0-ab88-20f7382dd24c` is the built-in Contributor role and `36243c78-bf99-498c-9df9-86d9f8d28608` is Resource Policy Contributor. Each command prints nothing when it succeeds. Check the conditioned assignment afterwards. The command prints the condition and its version `2.0`.

   ```powershell
   az role assignment list --assignee-object-id DEPLOY_PRINCIPAL --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
     --query "[?roleDefinitionName=='Role Based Access Control Administrator'].{role:roleDefinitionName, version:conditionVersion, condition:condition}" -o json
   ```

3. Give the govern identity User Access Administrator and Mirror Deployment Operator on the subscription. The User Access Administrator assignment carries a condition that excludes the eight Key Vault and managed identity roles of item 2, and nothing else. The govern identity must still be able to write Owner, User Access Administrator and Role Based Access Control Administrator, because the privileged unit declares them. Microsoft's condition for User Access Administrator uses the same two halves as the one of item 2, one for the write and one for the delete of a role assignment.

   ```powershell
   $govern = "00482a5a-887f-4fb3-b363-3b7fe8e74483, b86a8fe4-44ce-4948-aee5-eccb2c155cd7, 4633458b-17de-408a-b874-0445c86b69e6, db79e9a7-68ee-4b58-9aeb-b90e7c24fcba, 8b54135c-b56d-4d72-a534-26097cfdc8d8, f25e0fa2-a7c8-4377-a976-54943a77a395, e40ec5ca-96e0-45a2-b4ff-59039f2c2b59, f1a07417-d97a-45cb-824c-7a7467783830"
   $conditionGovern = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {$govern})) AND ((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAllValues:GuidNotEquals {$govern}))"
   az role assignment create --assignee-object-id GOVERN_PRINCIPAL --assignee-principal-type ServicePrincipal `
     --role 18d7d88d-d35e-4fb5-a5c3-7773c20a72d9 --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
     --condition $conditionGovern --condition-version 2.0 -o none
   az role assignment create --assignee-object-id GOVERN_PRINCIPAL --assignee-principal-type ServicePrincipal `
     --role OPERATOR_ROLE_ID --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 -o none
   ```

   Replace `GOVERN_PRINCIPAL` and `OPERATOR_ROLE_ID`. The commands print nothing when they succeed. The condition is written to the assignment, so check it in item 6.

4. Give `id-mirror-govern-tenant` User Access Administrator, Management Group Contributor (`5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c`) and Mirror Deployment Operator Tenant on the Tenant Root Group. Granting a role there needs Owner or User Access Administrator at the Tenant Root Group, which the demo account holds already, so there is no elevated access to turn on or remove.

   ```powershell
   $root = '/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'
   foreach ($roleId in '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9', '5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c', 'OPERATOR_TENANT_ROLE_ID') {
     az role assignment create --assignee-object-id TENANT_PRINCIPAL --assignee-principal-type ServicePrincipal `
       --role $roleId --scope $root -o none
   }
   ```

   Replace `TENANT_PRINCIPAL` and `OPERATOR_TENANT_ROLE_ID`. The command prints nothing when it succeeds.

5. The project's item 3 gives the deploy identities extra rights on linked resources, which are Mirror Network Peering, Mirror Key Vault Deployment and Mirror Container Writer. Only Mirror Key Vault Deployment applies to the demo, because it has no peering and no data export. Give the deploy identity the role on the vault. A missing right on a linked resource would show up late, because Azure checks it on the write and not in the preview.

   ```powershell
   az role assignment create --assignee-object-id DEPLOY_PRINCIPAL --assignee-principal-type ServicePrincipal --role KEYVAULT_ROLE_ID --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-identities/providers/Microsoft.KeyVault/vaults/kv-demo-mirror-secrets
   ```

   Replace `DEPLOY_PRINCIPAL` with the deploy identity's `principalId` and `KEYVAULT_ROLE_ID` with the ID of Mirror Key Vault Deployment from step 3.13. The output is the assignment in JSON.

6. Check the assignments.

   ```powershell
   foreach ($p in 'DEPLOY_PRINCIPAL', 'GOVERN_PRINCIPAL') {
     az role assignment list --assignee-object-id $p --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{role:roleDefinitionName, scope:scope}" -o table
   }
   az role assignment list --assignee-object-id TENANT_PRINCIPAL --scope /providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b --query "[?scope=='/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'].{role:roleDefinitionName, scope:scope}" -o table
   ```

   The deploy identity lists Contributor and Mirror Lock Writer on each of the three workload groups, and Resource Policy Contributor, Mirror Platform Deployment and Role Based Access Control Administrator on the subscription. It lists nothing on `rg-demo-identities`. The govern identity lists User Access Administrator and Mirror Deployment Operator, and its User Access Administrator row carries the condition. Read it with `az role assignment list --assignee-object-id GOVERN_PRINCIPAL --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{role:roleDefinitionName, version:conditionVersion}" -o table`, which shows version `2.0` on that row. The tenant identity lists its three roles on the Tenant Root Group. Nothing else is listed. A new role assignment can take about 10 minutes to take effect, so wait that long before the first deployment.

7. The project's item 5 declares these standing assignments in the privileged units after the pilot. The demo leaves it out.

8. Create the management group `mg-demo` once by hand, like `rg-demo-pilot`. A preview cannot run for a management group that does not exist yet, and Azure answers `AuthorizationFailed` on the group's own scope "or the scope is invalid". Once the group exists, `demo-tenant-management-group` previews and deploys as NoChange. The project's group `FDMGroupResources` exists in the same way. The demo account needs Management Group Contributor at the Tenant Root Group for this one command. Grant it, create the group and remove the grant.

   ```powershell
   $root = '/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'
   $me = az ad signed-in-user show --query id -o tsv
   az role assignment create --assignee-object-id $me --assignee-principal-type User --role 5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c --scope $root -o none
   az account management-group create --name mg-demo --display-name Demo --parent d1a349ef-6ac8-4588-a88d-5dab272c700b
   az role assignment delete --assignee $me --role 5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c --scope $root
   ```

   The create command prints the group in JSON, with the display name `Demo`. A new role assignment can take a few minutes to take effect, so wait if the create command is refused and run it again. In the browser, search for **Management groups**, select **Create**, type `mg-demo` as the ID and `Demo` as the display name, and select **Submit**.

The demo run proved every grant of this step. A missing role shows first in the fresh preview of an apply job, as `AuthorizationFailed` for `Microsoft.Resources/deployments/whatIf/action` (section 5).

Check that both lists of identities are complete.

```powershell
az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
```

The output lists `id-mirror-deploy-demo`, `id-mirror-govern-demo`, `id-mirror-govern-tenant` and `id-mirror-reader`, in no fixed order. To read an identity's IDs again later, run `az identity show --name IDENTITY_NAME --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "{clientId:clientId, principalId:principalId}" -o json`.

### 3.16 Read the subject the workflows present

A federated credential trusts one exact subject. Azure accepts a wrong subject when you create the credential, and the sign-in fails later. Repositories created after 15 July 2026 use a subject with the owner ID and the repository ID, so the demo repository does.

1. Read the subject settings.

   ```powershell
   gh api repos/themasterishome/demo-bicep-deploy-test/actions/oidc/customization/sub
   ```

   The output is similar to the following.

   ```text
   {"use_default":true,"use_immutable_subject":true,"sub_claim_prefix":"repo:themasterishome@49098959/demo-bicep-deploy-test@123456789"}
   ```

   The number after `demo-bicep-deploy-test@` is `REPOSITORY_ID` from step 3.3. If the output has no `sub_claim_prefix`, build the prefix from the two IDs yourself.

2. Build the five subjects, the prefix, then `:environment:`, then the environment's name. The reader identity needs two. Every other identity needs one, for its own environment.

   ```text
   repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID:environment:mirror-reader
   repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID:environment:mirror-reader-dispatch
   repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID:environment:mirror-production-demo
   repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID:environment:mirror-privileged-demo
   repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID:environment:mirror-privileged-tenant
   ```

   Every job of these workflows names an environment, so it presents this environment form, even when a pull request starts it.

3. Confirm the issuer. `gh api users/themasterishome --jq .html_url` prints `https://github.com/themasterishome`. A personal account on github.com uses the issuer `https://token.actions.githubusercontent.com`. The project also asks an enterprise owner about the enterprise's own issuer URL, which a personal account does not have.

### 3.17 Create the federated credentials

Each environment gets one credential, on the identity that environment uses.

| Identity | Environments | Credentials |
|---|---|---|
| `id-mirror-reader` | `mirror-reader` and `mirror-reader-dispatch` | 2 |
| `id-mirror-deploy-demo` | `mirror-production-demo` | 1 |
| `id-mirror-govern-demo` | `mirror-privileged-demo` | 1 |
| `id-mirror-govern-tenant` | `mirror-privileged-tenant` | 1 |

That makes five credentials, one for each environment. Create them one at a time, because Azure refuses concurrent changes to one identity's credentials. Use the CLI and the exact subjects of step 3.16. The portal's scenario **GitHub Actions deploying Azure resources** fills in the subject from the names, and Microsoft does not say that it adds the IDs. If you use the portal, choose **Other issuer** and paste the exact subject.

1. Create the five credentials.

   ```powershell
   $prefix = 'repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID:environment:'
   $pairs = @(
     @('id-mirror-reader', 'mirror-reader'),
     @('id-mirror-reader', 'mirror-reader-dispatch'),
     @('id-mirror-deploy-demo', 'mirror-production-demo'),
     @('id-mirror-govern-demo', 'mirror-privileged-demo'),
     @('id-mirror-govern-tenant', 'mirror-privileged-tenant')
   )
   foreach ($p in $pairs) {
     az identity federated-credential create --name "github-$($p[1])" --identity-name $p[0] `
       --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
       --issuer https://token.actions.githubusercontent.com --subject "$prefix$($p[1])" --audiences api://AzureADTokenExchange -o none
     Write-Host "github-$($p[1]) on $($p[0])"
   }
   ```

   Replace `REPOSITORY_ID` in the prefix. The output is five lines, one per credential.

2. Read them back. A wrong subject, issuer or audience shows no error until the sign-in fails.

   ```powershell
   foreach ($i in 'id-mirror-reader', 'id-mirror-deploy-demo', 'id-mirror-govern-demo', 'id-mirror-govern-tenant') {
     az identity federated-credential list --identity-name $i --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 `
       --query "[].{name:name, subject:subject, issuer:issuer, audience:audiences[0]}" -o table
   }
   ```

   The output is two rows for the reader and one for each of the other three identities, each with its subject, the issuer and the audience `api://AzureADTokenExchange`. If a value differs, run that credential's `create` command of item 1 again, with the same `--name` and the right value. It replaces the credential in place. Do not delete it, because the lock of step 3.12 refuses the delete.

   In the portal, search for **Managed Identities** and select it. Select `id-mirror-reader`, then, in the left menu under **Settings**, select **Federated credentials**. The list shows the credentials of that identity with their subject.

3. Project items 3 to 5 check the trusted-owners policy, switch it to Deny and show a credential for another owner being refused. The demo has no such policy (step 3.12, item 3), so these items are skipped.

Wait a few minutes before the first run. A token request right after a credential is created can fail with `AADSTS70021`.

### 3.18 Set the environment variables

Each environment holds two variables. Neither is secret.

| Variable | Value |
|---|---|
| `AZURE_CLIENT_ID` | The `clientId` of the environment's identity. That is the reader's in `mirror-reader` and `mirror-reader-dispatch`, the deploy identity's in `mirror-production-demo`, `id-mirror-govern-demo`'s in `mirror-privileged-demo` and `id-mirror-govern-tenant`'s in `mirror-privileged-tenant`. |
| `AZURE_TENANT_ID` | `d1a349ef-6ac8-4588-a88d-5dab272c700b`, the tenant in `deploy/units.json` |

```powershell
$repo = 'themasterishome/demo-bicep-deploy-test'
$clients = @{
  'mirror-reader' = 'READER_CLIENT'; 'mirror-reader-dispatch' = 'READER_CLIENT'
  'mirror-production-demo' = 'DEPLOY_CLIENT'; 'mirror-privileged-demo' = 'GOVERN_CLIENT'; 'mirror-privileged-tenant' = 'TENANT_CLIENT'
}
foreach ($e in $clients.Keys) {
  gh variable set AZURE_CLIENT_ID --env $e --body $clients[$e] --repo $repo
  gh variable set AZURE_TENANT_ID --env $e --body d1a349ef-6ac8-4588-a88d-5dab272c700b --repo $repo
  Write-Host "$e set"
}
```

Replace `READER_CLIENT`, `DEPLOY_CLIENT`, `GOVERN_CLIENT` and `TENANT_CLIENT` with the client IDs from steps 3.14 and 3.15. The output is five lines. Set them per environment, never at repository or organization level. A value there reaches every job whose environment has none, and the apply job's check cannot tell it from the environment's own, so one identity's client ID would show up where it does not belong.

Check each environment, for example with `gh variable list --env mirror-reader-dispatch --repo themasterishome/demo-bicep-deploy-test`. Each lists `AZURE_CLIENT_ID` and `AZURE_TENANT_ID`.

To show it in the browser, select **Settings** > **Environments** and the environment's name. Under **Environment variables**, select **Add variable**, type the name and the value, and select **Add variable** again. GitHub cannot store a variable with an empty value, so it refuses an empty one with the message "Variable value cannot be empty".

Leave `MIRROR_RUNNER` and `MIRROR_MAX_PLAN_AGE_HOURS` unset. Every job then runs on `windows-2025`, apart from `portability`, which runs on `ubuntu-24.04`. A plan may wait 24 hours for its approval. The switch `MIRROR_PIPELINE_ENABLED` waits for step 3.20.

### 3.19 Check the client IDs of the environments

The client IDs of the pipeline's identities live in one place, the `AZURE_CLIENT_ID` variable of each environment (step 3.18). `deploy/units.json` does not hold them. `deploy-unit.ps1` accepts a service principal in a GitHub Actions job when its name equals the client ID that the workflow passes in `MIRROR_CLIENT_ID`, which is the environment's `AZURE_CLIENT_ID`. `allowedPrincipals` lists only the people who run the scripts by hand, so the file has one entry, of `"type": "user"`. Leave its name empty, because you run no script by hand in this demo.

The check in the script is a guard against mistakes. The boundary is Entra and the identity's roles. Entra issues a token to a job only when the job's subject matches a federated credential of the identity, and the subject names one repository and one environment. If someone changes a variable to another identity's client ID, the sign-in fails unless that identity trusts the environment. A changed workflow could pass the script any client ID, so what stops it is the ruleset on `master` (step 3.7) and the rule of each environment that only `master` may use it (step 3.11). Both apply jobs, `apply` and `apply-privileged`, also stop in the step before the sign-in when no `AZURE_CLIENT_ID` reaches the job or the value is not a GUID. That step cannot tell a repository or organization value from the environment's own, so the variable is set on the environments only (step 3.18).

Entra is the boundary that holds when that check is passed. In an earlier run of these steps, the reader's client ID was put into the deploy environment on purpose. It passed the GUID check, and `azure/login` then failed with the following message.

```text
AADSTS700213: No matching federated identity record found for presented assertion subject 'repo:OWNER@OWNER_ID/REPO@REPO_ID:environment:mirror-production-demo'
```

The reader's identity trusts only the two reader environments, so Entra refused the deploy environment's token. The same holds between the two tiers. The deploy identity trusts only `mirror-production-demo`, so it cannot sign in from a privileged environment.

Nothing is edited in the code. Run this check once after step 3.18, and again after any change to an identity. It compares each environment's variable with the identity's client ID, and checks that the identity has a federated credential for exactly that environment.

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

The output is five lines, and both values on every line are `True`. Then check that no repository-level variable of the same name exists.

```powershell
gh variable list --repo themasterishome/demo-bicep-deploy-test --json name | Out-String | ConvertFrom-Json | Where-Object { $_.name -eq 'AZURE_CLIENT_ID' }
```

The command prints nothing. If a line says `False`, or the second command prints a variable, correct the variable (step 3.18) or the credential (step 3.17) and run the check again. A client ID that does not match shows later as `AADSTS700213` or `AADSTS70021` at the sign-in (section 5).

### 3.20 Turn the pipeline on

1. Set the switch.

   ```powershell
   gh variable set MIRROR_PIPELINE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
   ```

   In the browser, select **Settings**. In the left sidebar, select **Secrets and variables**, then **Actions**. Select the **Variables** tab and **New repository variable**. Type the name `MIRROR_PIPELINE_ENABLED` and the value `true`, and select **Add variable**.

2. Check it.

   ```powershell
   gh variable list --repo themasterishome/demo-bicep-deploy-test
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
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head first-checks --title "First run of the checks" --body "Change: DEMO-0002"
   ```

2. Wait for the checks. To watch them, open the repository's **Pull requests** tab and select the pull request. The checks are listed at the bottom of the **Conversation** tab, and **Details** next to a check opens its run. On the small demo tree the run takes a few minutes. The five jobs of mirror-validate are green: `secret-scan`, `actionlint`, `workflow-hygiene`, `portability` and `preflight`. mirror-pr shows `plan`, no `whatif` job and a green `pr-gate`, because no unit is touched. If a job fails, read its first error.

3. Add the six required checks to the ruleset. Select **Settings** > **Rulesets** > **Rulesets** and then `protect-master`. Turn on **Require status checks to pass before merging** if step 3.7 left it off, with **Require branches to be up to date before merging**. Under that rule, in the **Additional settings** section, type each check name and select the **+** button to add it. Keep the source **GitHub Actions**. The six names are `secret-scan`, `actionlint`, `workflow-hygiene`, `portability`, `preflight` and `pr-gate`. A name is offered only because its job has run once. Select **Save changes**. The check names are the job IDs, because none of these six jobs has a `name:` key. Without a check listed, the up-to-date box has no effect, so add the six first.

4. Close the pull request without merging, and keep its branch for step 3.22.

   ```powershell
   gh pr close first-checks --repo themasterishome/demo-bicep-deploy-test
   git switch master
   ```

Project step 3.21 also checks the push ruleset against a branch made at an older commit. The demo has no push ruleset, so that part does not apply.

### 3.22 First run: the drift workflow with no unit enabled

This run proves the reader's sign-in through `mirror-reader-dispatch`. With every unit disabled the drift check has nothing to check, so it fails on purpose.

1. Start it on `master`.

   ```powershell
   gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
   ```

   In the browser, open the repository's **Actions** tab, select **mirror-drift** in the left sidebar and select the **Run workflow** button above the list of runs. In the **Branch** dropdown keep `master`, and select **Run workflow** in the pop-up. The workflow has no input boxes.

2. Open the finished run by selecting its name in the list. The `azure/login` step is green. The step "Drift sweep (read-only)" fails, and its last line starts with `STOP: no enabled unit to check in deploy/units.json`. The upload of the `drift` artifact then warns that no files were found.

3. Check the branch rule. Start the workflow on the branch of step 3.21.

   ```powershell
   gh workflow run mirror-drift.yml --ref first-checks --repo themasterishome/demo-bicep-deploy-test
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

Project item 8 proves the privileged tier with a plan only. The demo goes further. It deploys its three privileged units in [sections 4.5 to 4.7](#45-wave-4-the-privileged-unit), each behind the approval of a privileged environment.

### 3.24 The security alerts (not in the demo)

The project's alerts e-mail IT's security mailbox about every role assignment and federated credential change. The demo leaves them out. Add them only if the audience asks to see them, with the commands of PIPELINE.md step 3.24 and `rg-demo-identities` as the alert group.

## 4. The demo run

Each part says what to do and what the audience sees on screen. Nothing changes in Azure until the second account approves an apply job. The order is the one the project follows, from the pilot to the units that change who has access:
1. the pilot, an empty template (4.2)
2. `rg-demo-network`, a production unit with a lock, a policy assignment and a Reader assignment (4.3), and `rg-demo-routing` (4.4)
3. `demo-privileged`, a privileged unit with the Owner assignment and the role definition (4.5)
4. `demo-tenant-management-group` and then `demo-tenant-governance`, the privileged tenant units (4.6 and 4.7)
5. a change after the baseline, the drift check and a rollback (4.8 to 4.10)

### 4.1 Before you start

Prepare two browser windows side by side, the repository in your own window and the same repository in the private window of the second account. Keep a PowerShell window at the root of the local repository, on `master`.

Do section 3 the day before, or at least two hours before the audience arrives. The policy of step 3.17 takes over an hour to show its first compliance result, and the Deny check needs its wait.

**Check before the demo:**
- [ ] Steps 3.1 to 3.22 are done, and the mirror-validate run of the step 3.21 pull request is green.
- [ ] `az account show` names the Visual Studio subscription.
- [ ] `gh auth status` shows `themasterishome` as the active account.
- [ ] The second account is signed in, in the private window.
- [ ] No run of mirror-deploy-unit waits for approval.
- [ ] You merge nothing else while a deployment waits. A merge moves `master`, and the waiting apply then refuses (project section 4.1).

Plan jobs take one to two minutes, and apply jobs about three.
### 4.2 Wave 0, the pilot

This is project step 3.23 and sections 4.2 to 4.8. Project section 4.6, the check of the deploy identity's roles, is step 3.15 item 6 here, done once at set-up.

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
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-pilot --title "Enable the pilot unit" --body "Change: DEMO-0003"
   ```

   On screen, open the repository's **Pull requests** tab and select the pull request. The checks at the bottom of the **Conversation** tab show mirror-validate and mirror-pr. mirror-pr has a job `whatif pilot-empty-rg`, the reader's first sign-in through `mirror-reader`. Its comment on the pull request shows the pilot's preview with the gate PASS and no records. The comment says `Identity: not checked (offline)`.

3. As the second account, approve the pull request. In the private window, open the pull request, select the **Files changed** tab, select **Review changes**, select **Approve** and select **Submit review**. Then, once every check is green, select **Squash and merge** on the **Conversation** tab as yourself, then **Confirm squash and merge**, and update `master`. GitHub refuses the merge while a required check is still running.

   ```powershell
   gh pr merge enable-pilot --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
   git switch master
   git pull
   ```

4. Show the push run. Open the repository's **Actions** tab, select **mirror-deploy-unit** in the left sidebar and select the newest run, named "Plan the units changed by the push" and the commit. Or list it.

   ```powershell
   gh run list --workflow mirror-deploy-unit.yml --branch master --limit 3 --repo themasterishome/demo-bicep-deploy-test
   ```

   On screen, `select` lists `pilot-empty-rg`, and the job `plan pilot-empty-rg` signs in as the reader through `mirror-reader-dispatch`. Its summary shows "Gate PASS, approvable", with PASS in bold, and ends with "A push publishes this plan and deploys nothing. The plan holds no effective change, so nothing waits for a reviewer. A change is applied with Run workflow, which names the ticket, the reason and the options." The apply job is skipped. The merge deployed nothing. The summary is on the run's page, under the job list.

5. Start the deployment by hand.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot" -f apply=true --repo themasterishome/demo-bicep-deploy-test
   ```

   In the browser, open the **Actions** tab, select **mirror-deploy-unit** in the left sidebar and select the **Run workflow** button above the list of runs. In the **Branch** dropdown keep `master`. Fill in the boxes as the table shows, and select **Run workflow** in the pop-up. The run is named "Deploy pilot-empty-rg (DEMO-0003)". The inputs `acknowledgeReview`, `allowCreate`, `allowModify` and `allowHeld` stay empty or unticked here. The form labels each box with the input's description from the workflow file, so check the labels on screen once before the audience.

   | Input | What the form shows | What you enter |
   | --- | --- | --- |
   | `unit` | Deployment unit (name from deploy/units.json) | `pilot-empty-rg` |
   | `changeRef` | Change ticket number | `DEMO-0003` |
   | `reason` | What this deployment is for | `Pilot` |
   | `apply` | Deploy after a reviewer approves the plan. Leave off for a plan only | tick |
   | `acknowledgeReview` | Accept the review items (review boundaries and review records) after reading them in a plan | leave unticked |
   | `allowCreate` | Resource IDs that may show as Create, separated by commas | leave empty |
   | `allowModify` | Resource IDs whose changes the plan shows and the deployment may write, separated by commas | leave empty |
   | `allowHeld` | Held resource IDs to lift the hold for, separated by commas | leave empty |

6. Show the waiting apply. Open the run from the **Actions** tab. After `plan pilot-empty-rg` and `collect`, the job `apply pilot-empty-rg` shows **Waiting**, for the environment `mirror-production-demo`. The plan's summary says it holds no effective change. Show the audience that the plan summary and the artifact `reviewed-plan-pilot-empty-rg` can be read while it waits. The artifacts are listed in the "Artifacts" section at the bottom of the run's page, and selecting a name downloads it as a zip file.

7. Show Prevent self-review. In your own window, open the run. You started it, so GitHub does not let you approve it. The text of the refusal was not recorded in the run of these steps, so read what the page says and tell the audience that. Most likely the **Review deployments** button is missing, or GitHub does not let you tick the environment. Do not use **Start all waiting jobs** here. It is the administrators' bypass of step 3.11, and it would skip Prevent self-review in front of the audience. With the one-account variant, skip this item.

8. Approve it as the second account. In the private window, open the repository's **Actions** tab and the run. The page shows a notice that the run is waiting for review. Select **Review deployments**, tick `mirror-production-demo`, write a comment that names `DEMO-0003`, and select **Approve and deploy**. The apply job then starts.

9. Watch the apply.

   ```powershell
   gh run watch --repo themasterishome/demo-bicep-deploy-test
   ```

   Choose the run when the GitHub CLI asks. On screen, the apply job checks that it is the first attempt, that `master` is still at the planned commit and that the plan is less than 24 hours old. It signs in as the deploy identity, compares a fresh preview with the plan and runs the gate step. The log shows `Identity ok: *** (servicePrincipal)`, because `azure/login` masks the client ID. The ID itself is visible in the inputs of the `azure/login` step, in the environment of the step "Check the environment has a client ID", and in `approval.txt` and `post-summary.txt` as `identity=<client ID> (servicePrincipal)`. Its summary ends with `Gate step exit: 0, deployed, and the second check passed.`

10. Download the evidence. The run's ID is the long number after `/actions/runs/` in the run's address, not the `#N` number. In the browser, scroll to the "Artifacts" section of the run's page and select `evidence-deploy-pilot-empty-rg` to download it as a zip file. The commands below do the same and unpack the files.

    ```powershell
    gh run download RUN_ID --name evidence-deploy-pilot-empty-rg --dir C:\demo-setup\evidence-pilot --repo themasterishome/demo-bicep-deploy-test
    gh run download RUN_ID --name reviewed-plan-pilot-empty-rg --dir C:\demo-setup\evidence-pilot\reviewed-plan --repo themasterishome/demo-bicep-deploy-test
    ```

    Replace `RUN_ID` with the run's ID. The files sit under `C:\demo-setup\evidence-pilot`, in the folders the artifact itself holds. This command finds them.

    ```powershell
    Get-ChildItem -Path C:\demo-setup\evidence-pilot -Recurse -Include approval.txt, post-summary.txt | Select-Object -ExpandProperty FullName
    ```

    Open `approval.txt`, which has a `deployed=` line, and `post-summary.txt`, the second check, which says Gate PASS. In the project this goes on the change ticket, with the reviewer's name and comment from the run's **Review deployments** history.

11. Show the plan-only route, as project step 3.23, item 5 does.

    ```powershell
    gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot, plan only" --repo themasterishome/demo-bicep-deploy-test
    ```

    The run ends after the plan, with the gate PASS and no waiting job.

### 4.3 Wave 1, the network

This is project sections 4.2 to 4.8 and 4.10, for a production unit that creates resources. `rg-demo-network` also holds a lock, a policy assignment and a Reader role assignment, so the audience sees what the deploy identity may write. The lock needs Mirror Lock Writer, the policy assignment needs Resource Policy Contributor and the Reader assignment needs the conditioned Role Based Access Control Administrator (step 3.15).

1. Enable the network and routing units in one pull request. Create a branch.

   ```powershell
   git switch --create enable-waves
   ```

   Open `deploy/units.json` in an editor and set `"enabled": true` in the entries of `rg-demo-network` and `rg-demo-routing`. `readerPrincipalId` in `infra/subscriptions/demo/resource-groups/rg-demo-network.bicepparam` already holds the reader's `principalId`, so the Reader assignment needs no edit. Then commit, push and open the pull request.

   ```powershell
   git commit --all --message "Enable the network and routing units"
   git push -u origin enable-waves
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-waves --title "Enable the network and routing units" --body "Change: DEMO-0004"
   ```

2. Show the preview on the pull request. mirror-pr runs `whatif rg-demo-network` and `whatif rg-demo-routing`. The first shows the gate FAIL with `Create=9`, which are the network security group, the virtual network, the lock, the policy assignment, the role assignment, the private DNS zone, its link, the private endpoint and the endpoint's zone group. The second shows `Create=4`, which are the route table, the application security group, the Automation account and its credential. Both are marked for information. The comments are on the **Conversation** tab of the pull request. A new resource is a Create, and the gate refuses a Create that nobody named. The check `pr-gate` is still green, because it fails only when a preview could not run.

3. Approve the pull request as the second account, then, once every check is green, select **Squash and merge** and **Confirm squash and merge**.

   ```powershell
   gh pr merge enable-waves --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
   git switch master
   git pull
   ```

4. Show the push run, as in 4.2 item 4. It plans both units and the plan jobs show red. Each plan is not approvable, because it holds Creates nobody named. The summary names the option that would accept them, `allowCreate`, and gives the ready `gh workflow run` command with the resource IDs. Nothing waits and nothing deploys.

5. Start the deployment of `rg-demo-network`, with the nine resource IDs in `allowCreate`. Copy the command from the plan summary, because it holds the IDs of the policy assignment and the role assignment, whose names are GUIDs that Bicep builds. The IDs are these.

   ```text
   /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/networkSecurityGroups/nsg-demo
   /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/virtualNetworks/vnet-demo
   /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Authorization/locks/lock-rg-demo-network
   /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Authorization/policyAssignments/POLICY_ASSIGNMENT_NAME
   /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Authorization/roleAssignments/ROLE_ASSIGNMENT_NAME
/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net
/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net/virtualNetworkLinks/link-vnet-demo
/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/privateEndpoints/pe-kv-demo-mirror-secrets
/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/privateEndpoints/pe-kv-demo-mirror-secrets/privateDnsZoneGroups/default
   ```

   Type it in PowerShell with the nine IDs joined by commas and no space.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, create the network" -f apply=true -f allowCreate="ID1,ID2,ID3,ID4,ID5,ID6,ID7,ID8,ID9" --repo themasterishome/demo-bicep-deploy-test
   ```

   Replace `ID1` to `ID9` with the nine IDs. In the **Run workflow** form of the **Actions** tab, fill in **Deployment unit (name from deploy/units.json)** (`unit`) with `rg-demo-network`, **Change ticket number** (`changeRef`) with `DEMO-0004` and **What this deployment is for** (`reason`), tick **Deploy after a reviewer approves the plan. Leave off for a plan only** (`apply`), and paste the IDs into **Resource IDs that may show as Create, separated by commas** (`allowCreate`), separated by a comma and no space.

6. Show the plan. The summary of `plan rg-demo-network` shows the verdict approvable, the option `allowCreate` with all nine IDs, and the nine Create records with their properties. `apply rg-demo-network` waits. Point at the role assignment record. A reviewer reads every role assignment in a production unit's plan as an access change (project section 1.5), and this one grants Reader only.

7. Approve it as the second account. In the private window, open the run, select **Review deployments**, tick `mirror-production-demo`, write a comment naming `DEMO-0004`, and select **Approve and deploy**.

8. Watch the apply. The fresh preview matches the plan record for record, the gate step creates the nine resources, and the second check ends with `NoChange=8`, one `Ignore` and one `Modify`. The `Ignore` is the network card Azure creates for the private endpoint, which `deploy/boundaries.json` lists as expected. The `Modify` is the endpoint's zone group, whose provider-set fields (`id`, `etag`, `type` and `provisioningState` of the zone configuration) the code cannot carry, and `deploy/boundaries.json` lists them as inert, so the gate passes it. The policy assignment declares `definitionVersion: '2.*.*'`, because Azure sets that value on the write, and a file that left it out would show one Modify in the second check. The summary ends with `Gate step exit: 0, deployed, and the second check passed.` The audience can open the group in the portal. In the Azure portal, search for **Resource groups**, select `rg-demo-network` and read the list on the **Overview** page, which holds `nsg-demo` and `vnet-demo`. Select **Locks** in the left menu to see `lock-rg-demo-network`, and **Access control (IAM)** > **Role assignments** to see the Reader row for `id-mirror-reader`. The lock matters at the end, because section 6 must remove it before it can delete the group.

9. Download the evidence as in wave 0, with `evidence-deploy-rg-demo-network` and `reviewed-plan-rg-demo-network`.

### 4.4 Wave 2, the routing

The unit is enabled already, so this wave needs no pull request.

1. Start the deployment of `rg-demo-routing`.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, create the routing" -f apply=true -f allowCreate="/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/applicationSecurityGroups/asg-demo" --repo themasterishome/demo-bicep-deploy-test
   ```

2. Approve it as the second account, watch the apply and download `evidence-deploy-rg-demo-routing`, as in wave 1. The second check shows `rt-demo`, `asg-demo`, `aa-demo-secrets` and `demo-cred` NoChange.

   The unit deploys the Automation account's credential with a password that no file in the repository holds. `rg-demo-routing.bicepparam` reads it from the vault with `az.getSecret`, the deploy identity holds Mirror Key Vault Deployment on the vault, and Azure Resource Manager reads the secret as a trusted service, although the vault's public network access is disabled. `parameters.json` in the evidence shows `<secure input, not recorded>` for the password. A preview does not evaluate the secret, so only the deployment proves it. Start the same unit again with no `allowCreate`. Both checks show `NoChange=4`, and nothing is deployed that changes a value.

   Two units that depend on each other deploy one after the other, as the project's two VPN gateway units do. Start `rg-demo-routing` only after the run of `rg-demo-network` has finished, and approve each run on its own.

### 4.5 Wave 4, the privileged unit

This is project step 3.23 item 8 and sections 4.2 to 4.8, for a privileged unit. `demo-privileged` holds the Owner role assignment on `rg-demo-network` and the custom role `Demo Reader Plus`. A production unit may not hold either. The `preflight` job of mirror-validate fails a change that puts them there, and the deploy identity could not write them in any case, because its condition excludes Owner. The unit waits in `mirror-privileged-demo` and deploys with `id-mirror-govern-demo`.

1. Enable the unit in a pull request. In the demo the privileged identity `id-mirror-govern-demo` is itself the Owner target, because the estate has no other principal. The project's Owner records belong to IT's people and groups. Create a branch.

   ```powershell
   git switch --create enable-privileged
   ```

   Open `deploy/units.json` and set `"enabled": true` in the entry of `demo-privileged`. `ownerPrincipalId` in `infra/subscriptions/demo/privileged.bicepparam` already holds its `principalId`. Then commit, push and open the pull request.

   ```powershell
   git commit --all --message "Enable the privileged unit"
   git push -u origin enable-privileged
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-privileged --title "Enable the privileged unit" --body "Change: DEMO-0006"
   ```

2. Show the preview on the pull request. mirror-pr runs `whatif demo-privileged` with the reader, which has no right to write. It shows the gate FAIL with `Create=2`, the Owner role assignment on `rg-demo-network` and the role definition `Demo Reader Plus`, marked for information.

3. Approve the pull request as the second account, then, once every check is green, select **Squash and merge** and **Confirm squash and merge**.

   ```powershell
   gh pr merge enable-privileged --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
   git switch master
   git pull
   ```

4. Show the push run, as in 4.2 item 4. The plan of `demo-privileged` is not approvable and names `allowCreate`. Nothing waits and nothing deploys.

5. Start the deployment with the two IDs in `allowCreate`. Copy the command from the plan summary. The IDs have this form.

   ```text
   /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Authorization/roleAssignments/ROLE_ASSIGNMENT_NAME
   /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/providers/Microsoft.Authorization/roleDefinitions/ROLE_DEFINITION_NAME
   ```

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, the privileged unit" -f apply=true -f allowCreate="ID1,ID2" --repo themasterishome/demo-bicep-deploy-test
   ```

   Replace `ID1` and `ID2` with the two IDs. The **Run workflow** form is the same as for `rg-demo-network`, with `demo-privileged` as the unit.

6. Show the waiting apply. After `plan demo-privileged` and `collect`, the job `apply-privileged demo-privileged` shows **Waiting**, for the environment `mirror-privileged-demo`. It is not the job `apply` and not the environment `mirror-production-demo`. The tier decided that. In the project, a smaller team approves here.

7. Approve it as the second account. Read the plan first, as project section 4.5 asks for a privileged unit. Every role assignment and role definition is named, the ticket says who gains Owner and why, and nothing grants Owner, User Access Administrator or Role Based Access Control Administrator to more than the ticket states. Then select **Review deployments**, tick `mirror-privileged-demo`, write a comment naming `DEMO-0006`, and select **Approve and deploy**.

8. Watch the apply. It signs in as `id-mirror-govern-demo` through the federated credential of `mirror-privileged-demo`, takes a fresh preview, deploys and takes the second check, which ends with `NoChange=2`. In the Azure portal, open `rg-demo-network`, select **Access control (IAM)** > **Role assignments** and read the Owner row for `id-mirror-govern-demo`. To see the role, search for **Subscriptions**, select the Visual Studio subscription, select **Access control (IAM)** > **Roles**, and filter the type to custom roles. The list holds `Demo Reader Plus`.

9. Download the evidence as in wave 0, with `evidence-deploy-demo-privileged` and `reviewed-plan-demo-privileged`.

### 4.6 Wave 5, the management group

This is the first tenant unit. It deploys at management group scope against the Tenant Root Group, whose name is the tenant ID, and it declares the management group `mg-demo` with `scope: tenant()`. A preview cannot run for a management group that does not exist yet, so `mg-demo` was created once by hand in step 3.15 item 8, and this unit previews and deploys it as NoChange. The project's group `FDMGroupResources` exists in the same way. The reader previews it with Reader and Mirror What-If Reader Tenant on the Tenant Root Group (step 3.14). `id-mirror-govern-tenant` deploys it, with User Access Administrator, Management Group Contributor and Mirror Deployment Operator Tenant there (step 3.15), after the approval in `mirror-privileged-tenant`.

1. Enable the unit in a pull request. Create a branch, set `"enabled": true` in the entry of `demo-tenant-management-group` in `deploy/units.json`, then commit, push and open the pull request.

   ```powershell
   git switch --create enable-tenant-mg
   git commit --all --message "Enable the management group unit"
   git push -u origin enable-tenant-mg
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-mg --title "Enable the management group unit" --body "Change: DEMO-0007"
   ```

2. Show the preview on the pull request. `whatif demo-tenant-management-group` shows the gate PASS with `NoChange=1`, the management group `mg-demo`, because the group exists already.

3. Approve the pull request as the second account, then, once every check is green, select **Squash and merge** and **Confirm squash and merge**.

   ```powershell
   gh pr merge enable-tenant-mg --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
   git switch master
   git pull
   ```

4. Show the push run. The plan passes with no effective change, and nothing waits.

5. Start the deployment. It needs no option, because the plan holds no Create.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-management-group -f changeRef=DEMO-0007 -f reason="Wave 5, the management group" -f apply=true --repo themasterishome/demo-bicep-deploy-test
   ```

6. Show the waiting apply, `apply-privileged demo-tenant-management-group`, for the environment `mirror-privileged-tenant`. Approve it as the second account with **Review deployments**, ticking `mirror-privileged-tenant`, and a comment naming `DEMO-0007`.

7. Watch the apply. It signs in as `id-mirror-govern-tenant` and the gate step runs `az deployment mg` against the Tenant Root Group. The second check ends with `NoChange=1`. In the Azure portal, search for **Management groups**. The Tenant Root Group holds the group `Demo` (`mg-demo`) from step 3.15 item 8, unchanged.

8. Download the evidence, `evidence-deploy-demo-tenant-management-group` and `reviewed-plan-demo-tenant-management-group`.

### 4.7 Wave 6, the role assignment on the management group

This unit runs against `mg-demo`, which step 3.15 item 8 created. Its preview and its plan need the group to exist. It has its own pull request, so each tenant unit shows its own preview and approval.

1. Enable the unit in a pull request. Create a branch and set `"enabled": true` in the entry of `demo-tenant-governance` in `deploy/units.json`. `readerPrincipalId` in `infra/tenant/governance.mg-demo.bicepparam` already holds the reader's `principalId`. Then commit, push and open the pull request.

   ```powershell
   git switch --create enable-tenant-governance
   git commit --all --message "Enable the management group governance unit"
   git push -u origin enable-tenant-governance
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-governance --title "Enable the management group governance unit" --body "Change: DEMO-0008"
   ```

2. Show the preview. `whatif demo-tenant-governance` shows the gate FAIL with `Create=1`, a Reader role assignment on `mg-demo`, marked for information.

3. Approve the pull request as the second account, then, once every check is green, select **Squash and merge** and **Confirm squash and merge**.

   ```powershell
   gh pr merge enable-tenant-governance --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
   git switch master
   git pull
   ```

4. Start the deployment with the assignment's ID in `allowCreate`. The plan summary gives the ready command. The ID has this form.

   ```text
   /providers/Microsoft.Management/managementGroups/mg-demo/providers/Microsoft.Authorization/roleAssignments/ROLE_ASSIGNMENT_NAME
   ```

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, Reader on the management group" -f apply=true -f allowCreate=ID --repo themasterishome/demo-bicep-deploy-test
   ```

   Replace `ID` with the assignment's ID.

5. Approve it as the second account in `mirror-privileged-tenant`, with a comment naming `DEMO-0008`. The second check ends with `NoChange=1`. In the Azure portal, search for **Management groups**, select `Demo`, then **Access control (IAM)** > **Role assignments**. The Reader row for `id-mirror-reader` is there.

6. Download the evidence, `evidence-deploy-demo-tenant-governance` and `reviewed-plan-demo-tenant-governance`.

### 4.8 A change after the baseline

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
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head nsg-rule --title "Deny remote desktop from the internet on nsg-demo" --body "Change: DEMO-0009"
   ```

   On screen, `whatif rg-demo-network` shows the gate FAIL with `Modify=1` on `nsg-demo`, the new rule under `securityRules`, for information. The comment is on the **Conversation** tab of the pull request.

3. Approve it as the second account and, once every check is green, select **Squash and merge** and **Confirm squash and merge**. The push run plans `rg-demo-network`, and the plan stops with a message that names the NSG's ID for `allowModify`. The merge deploys nothing.

4. Start the deployment with that ID in `allowModify`. In the **Run workflow** form, fill in **Deployment unit (name from deploy/units.json)** (`unit`) with `rg-demo-network`, **Change ticket number** (`changeRef`) with `DEMO-0009` and **What this deployment is for** (`reason`), tick **Deploy after a reviewer approves the plan. Leave off for a plan only** (`apply`), and paste the ID into **Resource IDs whose changes the plan shows and the deployment may write, separated by commas** (`allowModify`).

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0009 -f reason="Deny remote desktop from the internet" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-network/providers/Microsoft.Network/networkSecurityGroups/nsg-demo --repo themasterishome/demo-bicep-deploy-test
   ```

5. On screen, the plan shows "Gate REVIEW, approvable", with REVIEW in bold, and each property change is marked "would be allowed with -AllowModify". Approve it as the second account with **Review deployments**, as in 4.2 item 8. The gate step deploys only when its fresh preview shows exactly the planned property changes, and the second check ends with `NoChange=2`, with `nsg-demo` among them. To show the rule in the Azure portal, search for **Network security groups**, select `nsg-demo` and select **Inbound security rules**. The list shows `Deny-Internet-RDP` with the priority 100, besides the default rules.

### 4.9 Drift

This is project section 5.3, with the repair of REFERENCE.md section 5.2.

1. Run the drift check once with everything in line.

   ```powershell
   gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
   ```

   The summary lists every enabled unit as clean, which are `pilot-empty-rg`, `rg-demo-network`, `rg-demo-routing`, `demo-privileged` and the two tenant units, and the run is green. The drift check runs with the reader identity for every tier. Run it once before the audience arrives, because the privileged units add records the first three do not have.

2. Change something outside the code. In the Azure portal, search for **Route tables** and select `rt-demo`. In its left menu select **Tags**, type the name `changedBy` and the value `portal`, and select **Apply**.

3. Run the drift check again with the same command. The run is red, and its summary lists `rg-demo-routing` as `DRIFT`, with a Modify on `rt-demo` that removes the tag `changedBy`. In the log of the drift step, the line reads `FAIL Modify .../rt-demo` and the next line reads `unclassified delta tags.changedBy (Delete)`. A failed run is the alert, and GitHub notifies the person who started it. The `drift` artifact holds each unit's evidence.

4. Repair it by putting the code's value back. Start a deployment of `rg-demo-routing` with `rt-demo` in `allowModify`.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0010 -f reason="Undo the drift on rt-demo" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo --repo themasterishome/demo-bicep-deploy-test
   ```

   The plan shows the tag going away. Approve it as the second account with **Review deployments**. After the deployment, run the drift check again. Every enabled unit is clean, and the log says "No drift found" for each.

   The other repair is to keep the live value. You then copy the tag into `rg-demo-routing.bicep` through a code pull request, and the next drift check is clean with nothing deployed.

### 4.10 A rollback

This is REFERENCE.md section 4.1. It takes the rule of section 4.8 out again.

1. Find the squash commit of the rule's pull request and revert it on a branch.

   ```powershell
   git switch master
   git pull
   git log --oneline -5
   git switch --create revert-nsg-rule
   git revert --no-edit BAD_COMMIT
   git push -u origin revert-nsg-rule
   gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head revert-nsg-rule --title "Roll back the remote desktop rule on nsg-demo" --body "Change: DEMO-0011"
   ```

   Replace `BAD_COMMIT` with the ID of the commit "Deny remote desktop from the internet on nsg-demo" in the `git log` output. A squash merge is one ordinary commit, so `git revert` needs no `-m` option. The preview on the pull request shows a Modify on `nsg-demo` that removes the rule.

2. Approve it as the second account and, once every check is green, select **Squash and merge** and **Confirm squash and merge**. The push run stops on the Modify, as in section 4.8.

3. Start the deployment with the NSG in `allowModify`, as in section 4.8, item 4, with `changeRef=DEMO-0011` and the reason `Roll back the remote desktop rule`.

4. Approve it as the second account with **Review deployments**. The rollback worked when the gate step exits 0, the second check shows `nsg-demo` NoChange, and a drift run is clean with "No drift found" for every enabled unit. In the Azure portal, open `nsg-demo` and select **Inbound security rules**. The list holds only the default rules again.

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
| The `apply` or `apply-privileged` job fails in the step `Check the environment has a client ID`, with one of the two messages after this table | No `AZURE_CLIENT_ID` reaches the job from its environment, the repository or the organization, or its value is not a GUID. GitHub cannot store an empty value (HTTP 422, "Variable value cannot be empty"), so a variable is either missing or holds some text. Nothing was signed in or deployed | Set it (step 3.18), check it (step 3.19) and start a new run |
| The gate step stops with exit 2 and `identity '...' (servicePrincipal) is neither in allowedPrincipals nor the client ID of this GitHub Actions job (MIRROR_CLIENT_ID)` | The identity that signed in is not the one in the job's `AZURE_CLIENT_ID`. This happens when a service principal signed in outside a GitHub Actions job | In a pipeline job, make sure the job signed in with `azure/login`. By hand, sign in as a person listed in `allowedPrincipals` |
| **Run workflow** is missing, or a run starts an old copy of the workflow | The workflow file is not on the default branch, or the default branch is not `master` and holds an older copy | Set the default branch as in step 3.5 |
| The apply refuses after the approval because `master` moved | Something was merged while the apply waited | Reject the old run under **Review deployments**, then start a new run and approve its plan |
| A drift run fails on a resource group the code does not declare | The Visual Studio subscription holds groups that are not part of the demo, and the drift check of `demo-subscription` lists every live group in it | Keep the demo's own groups the only ones the unit declares, and read the drift summary for the names it reports |
| A plan of a tenant unit fails with `AuthorizationFailed` | The reader lacks Reader or Mirror What-If Reader Tenant on the Tenant Root Group, or the roles have not taken effect yet | Run the second check of step 3.14 item 3, wait about 10 minutes and start a new run |
| A role assignment fails with `PrincipalNotFound` | A parameter file holds a `principalId` that differs from the identity's, for example after the identity was created again | Put the identity's `principalId` into `rg-demo-network.bicepparam`, `privileged.bicepparam` and `governance.mg-demo.bicepparam` through a code pull request |
| A tenant unit cannot be previewed, with `AuthorizationFailed` on the group's own scope "or the scope is invalid" | The management group `mg-demo` does not exist, because step 3.15 item 8 was not done. A preview cannot run against a group that is not there | Create the group as step 3.15 item 8 shows |
| A plan or the apply job fails with `AuthorizationFailed` for `Microsoft.Resources/deployments/whatIf/action` | The identity that signs in lacks a role. The fresh preview of the apply job shows a missing grant first | Compare the identity's roles with step 3.15 and the role table of step 3.13, grant the missing one and wait about 10 minutes |
| A write of an Owner, User Access Administrator or Role Based Access Control Administrator assignment is refused, or `preflight` fails | The record sits in a production unit. The deploy identity's condition refuses it, and the preflight keeps it out of the production tier | Move it into a privileged unit, as `privileged.bicep` does for the Owner assignment |
| `az policy assignment delete` fails with `ScopeLocked`, or a resource group cannot be deleted | The CanNotDelete lock on `rg-demo-identities` covers the assignment, and `lock-rg-demo-network` covers its group | Remove the locks first, as section 6 does |
| The policy compliance list stays empty after step 3.17 | The first evaluation of a new assignment can take over an hour | Run `az policy state trigger-scan` with `--no-wait` as step 3.17 shows, and use the Deny check as the quicker proof |

The apply job logs the two messages of the client ID check as follows.

```text
the environment mirror-production-demo has no AZURE_CLIENT_ID variable, so the apply cannot sign in. Set it as PIPELINE.md step 3.18 says and run the workflow again
the AZURE_CLIENT_ID variable of the environment mirror-production-demo is not a client ID. It must be the GUID alone, with no spaces or other text. Correct it as PIPELINE.md step 3.18 says and run the workflow again
```

## 6. Clean up

Remove everything in the order Azure needs. Your CLI default is still the Visual Studio subscription.

1. Remove the two locks. A group with a lock cannot be deleted while its lock is on.

   ```powershell
   az lock delete --name mirror-identities-no-delete --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   az lock delete --name lock-rg-demo-network --resource-group rg-demo-network --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
   ```

2. The project removes the trusted-owners policy assignment here. The demo has none, so go on.

3. Remove the management group `mg-demo`. It holds no subscription, and its Reader assignment goes with it.

   ```powershell
   az account management-group delete --name mg-demo
   ```

4. Remove the role assignments of the four identities, on the subscription and on the Tenant Root Group.

   ```powershell
   $root = '/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'
   foreach ($p in 'READER_PRINCIPAL', 'DEPLOY_PRINCIPAL', 'GOVERN_PRINCIPAL', 'TENANT_PRINCIPAL') {
     $ids = @(az role assignment list --assignee-object-id $p --all --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].id" -o tsv)
     $ids += @(az role assignment list --assignee-object-id $p --scope $root --query "[?scope=='$root'].id" -o tsv)
     foreach ($id in $ids) {
       if ($id) {
         az role assignment delete --ids $id
         Write-Host "removed $id"
       }
     }
   }
   ```

   Replace the four placeholders with the `principalId` values. The output is one `removed` line for each assignment. The Owner assignment of `id-mirror-govern-demo` sits on `rg-demo-network` and goes with that group.

5. Remove the custom roles. A role can go only once nothing holds it, and a new removal can take a minute to show.

   ```powershell
   $sub = '/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7'
   $root = '/providers/Microsoft.Management/managementGroups/d1a349ef-6ac8-4588-a88d-5dab272c700b'
   foreach ($r in 'Mirror What-If Reader', 'Mirror Lock Writer', 'Mirror Deployment Operator', 'Mirror Platform Deployment', 'Demo Reader Plus') {
     az role definition delete --name $r --scope $sub
     Write-Host "removed $r"
   }
   foreach ($r in 'Mirror What-If Reader Tenant', 'Mirror Deployment Operator Tenant') {
     az role definition delete --name $r --scope $root
     Write-Host "removed $r"
   }
   az role definition delete --name "Mirror Key Vault Deployment" --scope "$sub/resourceGroups/rg-demo-identities"
   ```

6. Delete the four resource groups. This removes the identities with their credentials, the network, the routing and the deployment history.

   ```powershell
   foreach ($g in 'rg-demo-identities', 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') {
     az group delete --name $g --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --yes
     Write-Host "$g exists: $(az group exists --name $g --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7)"
   }
   ```

   The output ends each group with `exists: false`.

   The vault `kv-demo-mirror-secrets` is not gone for good. It has purge protection, so Azure keeps it soft-deleted for 90 days and nobody can purge it earlier, even the owner. Its name stays reserved for that time, which is why a second run of the demo needs another vault name. The vault costs nothing while it waits. List it with `az keyvault list-deleted --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7`.

7. Check that nothing is left.

   ```powershell
   az group list --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[?tags.purpose=='demo-bicep-deploy'].name" -o tsv
   az role definition list --custom-role-only true --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].roleName" -o tsv
   az account management-group show --name mg-demo
   ```

   The first prints nothing. The second lists neither a Mirror role nor Demo Reader Plus. The third fails because the group no longer exists. `NetworkWatcherRG` already exists in this subscription and holds Azure's network watchers, so leave it alone. To see that it is there, run `az group exists --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --name NetworkWatcherRG`, which only reads and prints `true`.

8. Delete the GitHub repository. The command needs the `delete_repo` scope, which the GitHub CLI asks for once.

   ```powershell
   gh auth refresh -h github.com -s delete_repo
   gh repo delete themasterishome/demo-bicep-deploy-test --yes
   ```

   In the browser, open the repository's **Settings** > **General**, scroll to the "Danger Zone" and select **Delete this repository**. Then select **I want to delete this repository** and **I have read and understand these effects**, type the repository name and select **Delete this repository**. Deleting it also removes the second account's access. To run the demo again, recreate it from step 3.3, because a new repository has a new ID and so new subjects.

9. Set the Azure CLI default back to the subscription you use day to day.

   ```powershell
   az account set --subscription SUBSCRIPTION_ID
   ```

   Replace `SUBSCRIPTION_ID` with that subscription. You can also delete `C:\demo-setup`, which holds the role files and the evidence you downloaded.

10. Remove the git credential helper that the command `gh auth setup-git` wrote in section 2. Skip this item if you want to keep using the GitHub CLI's sign-in for git. First read what it wrote.

   ```powershell
   git config --global --get-all credential.https://github.com.helper
   ```

   The output shows the helper values of that key, one of which names `gh auth git-credential`. To remove them, run the following. The command removes every value of that key from your global git configuration, so do not run it if you set another helper for github.com yourself.

   ```powershell
   git config --global --unset-all credential.https://github.com.helper
   ```

   Run the first command again. It prints nothing and exits with code 1. If the earlier `--get-regexp` check of section 2 listed a helper for another host, such as `gist.github.com`, remove that key in the same way.
