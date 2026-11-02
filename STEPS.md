# Run the demo, step by step

The demo is a small copy of the production pipeline for Bicep. It runs in your own test tenant and in the Visual Studio subscription, against the test repository `themasterishome/demo-bicep-deploy-test` on GitHub. It shows how a code change gets a preview in a pull request, how a deployment is started with **Run workflow**, how a second person approves it, how the pipeline deploys and checks the result, and how a weekly drift check opens an issue when live Azure no longer matches the code. Two accounts take part. `themasterishome` owns the repository, writes the code, merges and starts every run. `klaudiomarashi` is the second account. It reviews pull requests and approves deployments, in a private browser window, because nobody can approve what they started. GUIDE.md has the full detail of every step, and the step numbers below carry the same numbers as GUIDE.md and PIPELINE.md of the project.

The steps are the ones the production setup follows, with the same commands and the same order. Production runs on GitHub Enterprise Cloud in a private repository of an organization. It adds four things this public repository on GitHub Free cannot show:

- teams as required reviewers, with a smaller team for the privileged environments
- the push ruleset that protects `.github`
- the organization's rulesets and settings
- the enterprise's own OpenID Connect issuer

Everything else in these steps works the same there:

- the environments and their branch rule
- the subject form `repo:OWNER@ID/REPOSITORY@ID:environment:NAME`
- the variables per environment
- the switch
- Run workflow per unit
- the plan, the approval with Prevent self-review, the apply and the second check

GUIDE.md section 1 has the full comparison.

## Before you start

Tick each box. The command after a box shows how to check it. Where a check shows something is missing, the step of GUIDE.md named next to it creates it. Run every command in a Windows PowerShell window in the demo folder, never in Git Bash. In this folder the remote of the test repository is named `test`, where GUIDE.md says `origin`, so the commands below use `test`.

- [ ] **The tools.** Windows PowerShell 5.1, Azure CLI, GitHub CLI and Git are installed (GUIDE.md section 2).

  ```powershell
  az version
  gh --version
  git --version
  python --version
  git remote -v
  ```

  The last command lists the remote `test` with the address `https://github.com/themasterishome/demo-bicep-deploy-test.git`.

- [ ] **The Azure sign-in.** The Azure CLI is signed in to the personal tenant, and the Visual Studio subscription is its default (GUIDE.md section 2).

  ```powershell
  az account show --query "{name:name, tenantId:tenantId, user:user.name}" -o json
  ```

  The output names the Visual Studio Enterprise Subscription and the tenant `d1a349ef-6ac8-4588-a88d-5dab272c700b`. If it does not, run `az login --tenant d1a349ef-6ac8-4588-a88d-5dab272c700b`, then `az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7`.

- [ ] **The GitHub sign-ins.** `themasterishome` is the active account of the GitHub CLI. `klaudiomarashi` is signed in to github.com in a private browser window.

  ```powershell
  gh auth status
  gh auth switch --hostname github.com --user themasterishome
  ```

  The active account is `themasterishome`, with the scopes `repo` and `workflow` among them.

- [ ] **The test repository exists, and the second account is a collaborator.**

  ```powershell
  gh api repos/themasterishome/demo-bicep-deploy-test/collaborators --jq ".[] | {login: .login, admin: .permissions.admin, push: .permissions.push}"
  ```

  The output lists `themasterishome` with `admin` true and `klaudiomarashi` with `push` true. If the repository is gone, do GUIDE.md section 3 from step 3.3.

- [ ] **The five environments exist, with reviewers and the branch rule `master`** (GUIDE.md step 3.11).

  ```powershell
  gh api repos/themasterishome/demo-bicep-deploy-test/environments --jq ".environments[].name"
  gh api repos/themasterishome/demo-bicep-deploy-test/environments/mirror-production-demo --jq ".protection_rules"
  ```

  The first command lists `mirror-reader`, `mirror-reader-dispatch`, `mirror-production-demo`, `mirror-privileged-demo` and `mirror-privileged-tenant`. The second shows a `required_reviewers` rule with `prevent_self_review` true and the second account.

- [ ] **The environment variables are set and match the identities** (GUIDE.md steps 3.18 and 3.19). Run the check script of step 3.19. Its output is five lines, and both values on every line are `True`.

- [ ] **The identity group, the vault and the four identities exist in Azure** (GUIDE.md steps 3.12 to 3.15).

  ```powershell
  az identity list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
  az lock list --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].{name:name, level:level}" -o table
  az role definition list --custom-role-only true --scope /subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7 --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].roleName" -o tsv
  ```

  The first command lists `id-mirror-reader`, `id-mirror-deploy-demo`, `id-mirror-govern-demo` and `id-mirror-govern-tenant`. The second lists the lock `mirror-identities-no-delete`. The third lists the Mirror roles of step 3.13. The role `Demo Reader Plus` appears only after wave 4.

- [ ] **The federated credentials carry the subject GitHub presents** (GUIDE.md steps 3.16 and 3.17). A wrong subject shows no error until the first sign-in fails.

  ```powershell
  gh api repos/themasterishome/demo-bicep-deploy-test/actions/oidc/customization/sub
  foreach ($i in 'id-mirror-reader', 'id-mirror-deploy-demo', 'id-mirror-govern-demo', 'id-mirror-govern-tenant') {
    az identity federated-credential list --identity-name $i --resource-group rg-demo-identities --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].subject" -o tsv
  }
  ```

  The first command prints a `sub_claim_prefix` of the form `repo:themasterishome@49098959/demo-bicep-deploy-test@REPOSITORY_ID`. The loop prints five subjects, two for the reader, each that prefix followed by `:environment:` and the name of one of the five environments. If a subject differs, GUIDE.md step 3.17, item 2, replaces it in place.

- [ ] **The management group `mg-demo` exists** (GUIDE.md step 3.15, item 8).

  ```powershell
  az account management-group show --name mg-demo
  ```

  The output names the group. An error that the group is not found, or `AuthorizationFailed`, means it is missing.

- [ ] **The Azure side of the earlier runs.** The earlier test runs left the identities, the roles, the groups, `mg-demo` and the lock on `rg-demo-network` in the subscription. Whether the resources of the units are still there depends on whether the demo was removed since. Check.

  ```powershell
  az group list --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[?tags.purpose=='demo-bicep-deploy'].name" -o tsv
  az resource list --resource-group rg-demo-network --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
  az resource list --resource-group rg-demo-routing --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query "[].name" -o tsv
  ```

  The first command lists the groups `rg-demo-identities`, `rg-demo-pilot`, `rg-demo-network` and `rg-demo-routing`. If the two other commands print resource names, the units are deployed already. Their plans then show NoChange, and a deployment needs no `allowCreate`. That is the second-run proof of GUIDE.md section 4.4, but it does not show the Creates. To show the Creates, remove the demo with GUIDE.md section 6 and set it up again with section 3. If the commands print nothing, the groups are empty and the waves below create the resources.

- [ ] **The switch is off, and the units are disabled.**

  ```powershell
  gh variable list --repo themasterishome/demo-bicep-deploy-test
  Select-String -Path deploy\units.json -Pattern '"enabled"'
  ```

  The variable list shows no `MIRROR_PIPELINE_ENABLED` and no `MIRROR_DRIFT_SCHEDULE_ENABLED`, or shows them as `false`. The `Select-String` output shows seven lines with `true`, because the committed `deploy/units.json` still has the seven units enabled from the earlier runs. Step 2 disables them before anything runs, and the pull requests of steps 6, 11, 13, 14 and 15 enable six of them one at a time. `demo-subscription` stays disabled in these steps.

- [ ] **The Issues feature is on in the repository** (GUIDE.md step 3.22), because the drift report writes an issue.

  ```powershell
  gh api repos/themasterishome/demo-bicep-deploy-test --jq .has_issues
  ```

  The output is `true`.

- [ ] **No drift issue is open.** The `report` job keeps one drift issue. If one is still open from an earlier run, step 5 adds a comment to it instead of opening a new one, and the lines printed at steps 5 and 16 differ from the ones below.

  ```powershell
  gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
  ```

  The output is empty. If it lists the issue "The drift check found a difference between live Azure and the code, or a unit it could not check", close it with its number.

  ```powershell
  gh issue close ISSUE_NUMBER --comment "Closed before a new run of the demo" --repo themasterishome/demo-bicep-deploy-test
  ```

- [ ] **The second account watches the repository** (GUIDE.md step 3.22), because the demo shows who is notified when the drift issue opens. In the private browser window as `klaudiomarashi`, open the repository, select **Watch** > **Custom**, tick **Issues** and select **Apply**. At step 5 and at step 16, that account gets a notification when the issue is opened and when a comment is added to it. It gets none when only the run link in the issue changes.

- [ ] **The rulesets.** Look at which rulesets the repository has, because a ruleset on `master` decides how step 2 pushes.

  ```powershell
  gh api repos/themasterishome/demo-bicep-deploy-test/rulesets --jq ".[].name"
  ```

  The names `protect-master` and `protect-tags` mean the rulesets of GUIDE.md steps 3.7 and 3.9 exist. A ruleset that requires a pull request refuses a direct push to `master`, and step 2 says what to do then. An empty output (`[]` without the `--jq` filter) means the repository has no ruleset. Then a pull request merges without the six checks and without the second account's approval, and only the environments still ask for an approval. To show the checks and the pull request approval, create both rulesets with GUIDE.md steps 3.7 and 3.9 after step 2 and before step 4.

## The steps

### 1. Sign in and start from `master`

**What.** Make sure the Azure CLI and the GitHub CLI use the right accounts, and that the local folder is on `master`.

**Where.** A PowerShell window in the demo folder `C:\Users\labserver\Downloads\demo-bicep-deploy`.

**Do.**

```powershell
az account set --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7
gh auth switch --hostname github.com --user themasterishome
git switch master
git status --short
git log --oneline -3
```

**You should see.** `git status` prints nothing, or only a file you changed on purpose. The log shows the newest commit at the top.

**If not.** A failed `git switch master` prints its reason, so read it. GUIDE.md section 2 has the sign-in commands.

### 2. Disable the units and push the folder (steps 3.5 and 3.20 of GUIDE.md)

**What.** Put the latest commits of the folder into the test repository, with every unit disabled, while the switch is still off so that nothing runs.

**Where.** The PowerShell window in the demo folder.

**Do.** First disable the seven units in `deploy/units.json`, and commit only that file.

```powershell
(Get-Content deploy\units.json -Raw) -replace '"enabled": true', '"enabled": false' | Set-Content deploy\units.json -NoNewline
Select-String -Path deploy\units.json -Pattern '"enabled"'
git add deploy/units.json
git commit -m "Disable every unit for the next demo"
```

Then push.

```powershell
git push test HEAD:master
```

**You should see.** The `Select-String` output lists seven lines with `false`. The push prints the new commit range. On GitHub, the **Actions** tab shows a run of mirror-validate with every job skipped, because the switch is off. mirror-deploy-unit shows no run, because it starts only with **Run workflow**.

**If not.** The message `Repository rule violations found` means the ruleset `protect-master` refuses a direct push. Push a branch and open a pull request instead, then approve it as `klaudiomarashi` and squash-merge it.

```powershell
git push test HEAD:refs/heads/sync-demo
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head sync-demo --title "Bring the demo up to date" --body "Bring the demo up to date"
```

The pull request body is only a description. The change ticket goes in the `changeRef` input of Run workflow, so nothing reads the body.

After the second account has approved the pull request and you have squash-merged it, make the local `master` the merged one. The squash merge is a new commit, so without this every later `git pull test master` stops on branches that have diverged.

```powershell
gh pr merge sync-demo --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
git fetch test
git switch master
git reset --hard test/master
git log --oneline -1
```

A refusal of the token scope means `gh auth refresh -h github.com -s workflow`. A refusal that names the account means `gh auth switch --hostname github.com --user themasterishome`, then `gh auth setup-git`.

### 3. Turn the pipeline on (step 3.20 of GUIDE.md)

**What.** Set the switch `MIRROR_PIPELINE_ENABLED` to `true`. Until then every job of every workflow is skipped.

**Where.** The PowerShell window.

**Do.**

```powershell
gh variable set MIRROR_PIPELINE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

Or, in the browser, select **Settings** > **Secrets and variables** > **Actions**, open the **Variables** tab, select **New repository variable**, enter the name `MIRROR_PIPELINE_ENABLED` and the value `true`, and select **Add variable**. Use one route only.

**You should see.** The list shows `MIRROR_PIPELINE_ENABLED` with the value `true`. Setting it starts no run by itself.

**If not.** A refusal means the active account is not `themasterishome`. Switch it as in step 1. To stop every job again, set the value to `false`.

### 4. The first validate run (step 3.21 of GUIDE.md)

**What.** Open a pull request that touches no unit, so that the five checks of mirror-validate run and prove themselves, without signing in to Azure.

**Where.** The PowerShell window, then GitHub.

**Do.**

```powershell
git switch --create first-checks
Add-Content -Path README.md -Value ''
git commit --all --message "First run of the checks"
git push -u test first-checks
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head first-checks --title "First run of the checks" --body "First run of the checks"
```

Then open the repository's **Pull requests** tab, select the pull request and watch the checks at the bottom of the **Conversation** tab.

**You should see.** The five jobs of mirror-validate turn green after a few minutes. They are `secret-scan`, `actionlint`, `workflow-hygiene`, `portability` and `preflight`. mirror-pr shows `plan` and a green `pr-gate`, with no `whatif` job, because the pull request touches no unit. No Azure sign-in happens.

**Then.** Close the pull request without merging, and go back to `master`. Keep the branch `first-checks`, because step 5 uses it.

```powershell
gh pr close first-checks --repo themasterishome/demo-bicep-deploy-test
git switch master
```

**If not.** Open the failed job and read its first error. GUIDE.md section 5 lists the common causes. If the ruleset `protect-master` does not list the six checks yet, add them as GUIDE.md step 3.21, item 3 shows.

### 5. The first drift run (step 3.22 of GUIDE.md)

**What.** Run the read-only drift check once, to prove the reader identity's sign-in and the drift issue.

**Where.** The PowerShell window, then GitHub.

**Do.**

```powershell
gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
```

Or, in the browser, open the **Actions** tab, select **mirror-drift** in the left sidebar, then **Run workflow**, keep the branch `master` and select **Run workflow** in the pop-up. Use one route only, because a second start while the first runs is queued behind it. Open the finished run when it ends.

**You should see.** With every unit disabled, the `azure/login` step is green. The step "Drift sweep (read-only)" fails on purpose, and its last line starts with `STOP: no enabled unit to check in deploy/units.json`. The `report` job is green and prints `Drift report: issue #N is opened (error).` The **Issues** tab holds one open issue titled "The drift check found a difference between live Azure and the code, or a unit it could not check".

**Then.** Read the issue, then close it. With every unit disabled no run is clean, so no run closes it for you.

```powershell
gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
gh issue close ISSUE_NUMBER --repo themasterishome/demo-bicep-deploy-test
```

Replace `ISSUE_NUMBER` with the number the first command prints. Then check the branch rule. Start the workflow on the branch of step 4. The first command returns at once, so wait about 30 seconds and run the second one again until the top run shows `failure`.

```powershell
gh workflow run mirror-drift.yml --ref first-checks --repo themasterishome/demo-bicep-deploy-test
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

The run fails before any step, with `Branch "first-checks" is not allowed to deploy to mirror-reader-dispatch due to environment protection rules`, and the `report` job is skipped because the run is not on `master`. Then delete the branch.

```powershell
git push test --delete first-checks
git branch --delete --force first-checks
```

**If not.** A failed sign-in with `AADSTS70021` means the federated credential's subject does not match, or the credential is only a minute old. Wait a few minutes and run it again, or compare with the read-back of step 3.17. A `report` job that fails means Issues are off, so turn them on under **Settings** > **General** > **Features** and run it again. A `report` job that prints `is updated` instead of `is opened` means a drift issue was still open, so close it as the box "No drift issue is open" shows. If the run on `first-checks` signs in instead of failing, `mirror-reader-dispatch` has no branch rule, and step 3.11 of GUIDE.md adds it.

### 6. A pull request and its preview (section 4.2, items 1 and 2, of GUIDE.md)

**What.** Enable the pilot unit in a pull request, and read the preview mirror-pr puts on it.

**Where.** The PowerShell window, then GitHub.

**Do.** Create the resource groups of the demo if they do not exist. The command is safe to run again.

```powershell
foreach ($g in 'rg-demo-pilot', 'rg-demo-network', 'rg-demo-routing') {
  az group create --name $g --location uksouth --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --tags purpose=demo-bicep-deploy -o none
  az group show --name $g --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.provisioningState -o tsv
}
```

Then create the branch.

```powershell
git switch --create enable-pilot
```

Open `deploy/units.json` in an editor, set `"enabled": true` in the entry of `pilot-empty-rg` and save the file. Then commit, push and open the pull request.

```powershell
git commit --all --message "Enable the pilot unit"
git push -u test enable-pilot
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-pilot --title "Enable the pilot unit" --body "Enable the pilot unit"
```

**You should see.** The output of the first command is `Succeeded` three times. The checks of the pull request show mirror-validate and mirror-pr. mirror-pr has a job `whatif pilot-empty-rg`, the reader's first sign-in through `mirror-reader`. Its comment on the **Conversation** tab shows the pilot's preview with the gate PASS and no records.

**If not.** A `whatif` job that fails with `ResourceGroupNotFound` means `rg-demo-pilot` is missing, so run the first command again. A refused push means the token lacks the `workflow` scope or the active account is wrong (step 1).

### 7. Approve and merge, and see that the merge starts nothing (section 4.2, items 3 and 4)

**What.** Approve the pull request as the second account, merge it, and show that the merge starts no deployment.

**Where.** The private browser window as `klaudiomarashi`, then the PowerShell window.

**Do.** In the private window, open the pull request and select the **Files changed** tab. Select **Review changes**, **Approve** and **Submit review**. Back in your own window, once every check is green, select **Squash and merge** on the **Conversation** tab, then **Confirm squash and merge**. Or merge from PowerShell.

```powershell
gh pr merge enable-pilot --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
git switch master
git pull test master
gh run list --workflow mirror-deploy-unit.yml --branch master --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

**You should see.** No run of mirror-deploy-unit began at the merge. If the list is empty, that is the answer. The workflow starts only with **Run workflow**, because a deployment needs a change ticket, a reason and a reviewer. The preview of step 6 was the look at the change.

**If not.** GitHub refuses the merge while a required check still runs, or while the up-to-date rule is not met. Wait for the checks, or select **Update branch**. If you run alone, merge your own pull request and see GUIDE.md section 3.0. If a run did start, read its trigger on the run's page and check that `mirror-deploy-unit.yml` has only the trigger `workflow_dispatch`.

### 8. A plan only (section 4.2, item 11)

**What.** Start the pilot with `apply` left off. The pipeline plans and deploys nothing.

**Where.** The PowerShell window, then the **Actions** tab.

**Do.**

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot, plan only" --repo themasterishome/demo-bicep-deploy-test
```

Or, in the browser, select **Actions**, **mirror-deploy-unit**, **Run workflow**, keep `master`, fill in `unit`, `changeRef` and `reason`, leave `apply` unticked and select **Run workflow**. Open the run named "Deploy pilot-empty-rg (DEMO-0003)".

**You should see.** The jobs `select`, `plan pilot-empty-rg` and `collect` run. The `plan` job signs in as the reader through `mirror-reader-dispatch`. The summary shows "Gate PASS, approvable" and ends with "This run was started as a plan only (apply is off). Nothing waits for a reviewer." No apply job waits.

**If not.** A run that fails in `select` names the input it refused, such as a unit that is disabled. Enable the unit (step 6) and start again.

### 9. Deploy the pilot with an approval (section 4.2, items 5 to 9)

**What.** Start the deployment with `apply` on. The apply job waits until the second account approves it.

**Where.** The PowerShell window, then GitHub in your window and in the private window.

**Do.**

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=pilot-empty-rg -f changeRef=DEMO-0003 -f reason="Pilot" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Open the run from the **Actions** tab. After `plan pilot-empty-rg` and `collect`, the job `apply pilot-empty-rg` shows **Waiting** for the environment `mirror-production-demo`. In your own window, open the run. You started it, so GitHub does not let you approve it. In the private window, open the run, select **Review deployments**, tick `mirror-production-demo`, write a comment that names `DEMO-0003`, and select **Approve and deploy**. Then watch.

```powershell
gh run list --workflow mirror-deploy-unit.yml --limit 1 --repo themasterishome/demo-bicep-deploy-test
gh run watch RUN_ID --repo themasterishome/demo-bicep-deploy-test
```

Replace `RUN_ID` with the number in the first column of the list.

**You should see.** The apply job starts after the approval. It checks that `master` has not moved and that the plan is less than 24 hours old, signs in as `id-mirror-deploy-demo`, compares a fresh preview with the plan, deploys and takes the second check. The summary ends with `Gate step exit: 0, deployed, and the second check passed.` The run keeps the artifacts `reviewed-plan-pilot-empty-rg` and `evidence-deploy-pilot-empty-rg`.

**If not.** **Review deployments** shows nothing to tick when the run is an old or a finished one, so open the newest run. An apply job that ran at once with no pause means the environment has no reviewer, so check it as step 3.11 shows. A failed apply is read in the section "Reading a failed run" below.

### 10. Download the evidence (section 4.2, item 10)

**What.** Fetch the evidence of the deployment, which in the project goes on the change ticket.

**Where.** The PowerShell window.

**Do.** List the artifacts of the run. The run's ID is the long number after `/actions/runs/` in the run's address.

```powershell
gh api "repos/themasterishome/demo-bicep-deploy-test/actions/runs/RUN_ID/artifacts" --jq ".artifacts[] | [.id, .name] | @tsv"
```

Then fetch and unpack one artifact, with its ID and name from the list.

```powershell
New-Item -ItemType Directory -Force C:\demo-setup\evidence-pilot | Out-Null
cmd /c "gh api repos/themasterishome/demo-bicep-deploy-test/actions/artifacts/ARTIFACT_ID/zip > C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip"
python -I -c "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" C:\demo-setup\evidence-pilot\ARTIFACT_NAME.zip C:\demo-setup\evidence-pilot\ARTIFACT_NAME
Get-ChildItem -Path C:\demo-setup\evidence-pilot -Recurse -Include approval.txt, post-summary.txt | Select-Object -ExpandProperty FullName
```

**You should see.** The last command prints the paths of `approval.txt`, which has a `deployed=` line, and `post-summary.txt`, the second check, which says Gate PASS.

**If not.** `gh run download` fails on these artifacts on Windows because a zip holds the same entry twice, which is why the commands fetch the zip through `gh api` and unpack it with Python. The command goes through `cmd /c` because Windows PowerShell 5.1 would change the bytes of a redirected zip.

### 11. Wave 1, the network (section 4.3)

**What.** Enable `rg-demo-network` and `rg-demo-routing` in one pull request, then deploy the network with the Create records named in `allowCreate`.

**Where.** The PowerShell window, then GitHub in both windows.

**Do.** Create a branch.

```powershell
git switch --create enable-waves
```

Open `deploy/units.json` in an editor, set `"enabled": true` in the entries of `rg-demo-network` and `rg-demo-routing` and save the file. Then commit, push and open the pull request.

```powershell
git commit --all --message "Enable the network and routing units"
git push -u test enable-waves
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-waves --title "Enable the network and routing units" --body "Enable the network and routing units"
```

Approve the pull request as the second account as in step 7, then merge it once every check is green.

```powershell
gh pr merge enable-waves --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
git switch master
git pull test master
```

The merge starts no run. Read what the deployment needs from a plan only.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

Open that run. The plan is red, because it holds Creates nobody named. Its summary gives the ready command with the nine resource IDs. Copy it, replace `<ticket>` with `DEMO-0004` and `<why>` with `Wave 1, create the network`, add `--repo themasterishome/demo-bicep-deploy-test`, and run it. It has this shape, and GUIDE.md section 4.3, item 5, lists the nine IDs. Nine is the count in an empty group. If the lock, the policy assignment or the role assignment of the group is live already, the plan shows fewer Creates, and the ready command lists exactly those.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-network -f changeRef=DEMO-0004 -f reason="Wave 1, create the network" -f apply=true -f allowCreate="ID1,ID2,ID3,ID4,ID5,ID6,ID7,ID8,ID9" --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting apply as in step 9, and download the evidence as in step 10 with `evidence-deploy-rg-demo-network`.

**You should see.** The plan of the deployment shows the verdict approvable, the option `allowCreate` with all nine IDs, and nine Create records. After the approval, the second check ends with `NoChange=8`, one `Ignore` and one `Modify`, and the summary ends with `Gate step exit: 0, deployed, and the second check passed.` In the portal, the group `rg-demo-network` holds `nsg-demo` and `vnet-demo`, and the lock `lock-rg-demo-network` shows under **Locks**.

**If not.** If the resources exist already (see "Before you start"), the plan shows NoChange and passes with no option. That is the second-run proof, and the apply still waits for the reviewer. A plan that is red with exit code 2 names a set-up problem, so read GUIDE.md section 5.

### 12. Wave 2, the routing (section 4.4)

**What.** Deploy `rg-demo-routing`, which needs no pull request because step 11 enabled it.

**Where.** The PowerShell window, then the private window for the approval.

**Do.** Start it only after the run of step 11 has finished. First start a plan only, which names every Create the deployment needs.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

Open that run. When the group is empty, the plan is red with four Creates, which are `rt-demo`, `asg-demo`, the Automation account `aa-demo-secrets` and its credential `demo-cred`, and its summary gives the ready command with the four IDs. Copy it, replace `<ticket>` with `DEMO-0005` and `<why>` with `Wave 2, create the routing`, add `--repo themasterishome/demo-bicep-deploy-test`, and run it. It has this shape.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, create the routing" -f apply=true -f allowCreate="/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/applicationSecurityGroups/asg-demo,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets,/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Automation/automationAccounts/aa-demo-secrets/credentials/demo-cred" --repo themasterishome/demo-bicep-deploy-test
```

If the resources exist already (see "Before you start"), the plan only is green with no Create, and the deployment needs no `allowCreate`. Approve the waiting apply as in step 9.

**You should see.** The second check shows `rt-demo`, `asg-demo`, `aa-demo-secrets` and `demo-cred` as NoChange. The password of `demo-cred` comes from the vault through `az.getSecret`, and the evidence shows `<secure input, not recorded>` for it.

**Then.** Show that a second deployment of the same commit changes nothing. Start the same unit again with no `allowCreate`, and approve it as in step 9.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0005 -f reason="Wave 2, the second deployment of the same commit" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

The plan, the first check and the second check all show `NoChange=4`, and the gate step exits 0.

**If not.** A failure that names the vault means the deploy identity lacks Mirror Key Vault Deployment on the vault, so check step 3.15. GUIDE.md section 4.4 explains the proof.

### 13. Wave 4, the privileged unit (section 4.5)

**What.** Deploy `demo-privileged`, which holds the Owner role assignment on `rg-demo-network` and the custom role `Demo Reader Plus`. It waits in `mirror-privileged-demo` and deploys with `id-mirror-govern-demo`.

**Where.** The PowerShell window, then GitHub in both windows.

**Do.** Create a branch.

```powershell
git switch --create enable-privileged
```

Open `deploy/units.json` in an editor, set `"enabled": true` in the entry of `demo-privileged` and save the file. Then commit, push and open the pull request.

```powershell
git commit --all --message "Enable the privileged unit"
git push -u test enable-privileged
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-privileged --title "Enable the privileged unit" --body "Enable the privileged unit"
```

Approve the pull request as the second account as in step 7, then merge it once every check is green.

```powershell
gh pr merge enable-privileged --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
git switch master
git pull test master
```

Start a plan only. Its summary gives the ready command with the two IDs, the Owner role assignment on `rg-demo-network` and the role definition `Demo Reader Plus`.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

Copy the ready command, replace `<ticket>` with `DEMO-0006` and `<why>` with `Wave 4, the privileged unit`, add `--repo themasterishome/demo-bicep-deploy-test`, and run it. It has this shape.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-privileged -f changeRef=DEMO-0006 -f reason="Wave 4, the privileged unit" -f apply=true -f allowCreate="ID1,ID2" --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting job `apply privileged demo-privileged` in the environment `mirror-privileged-demo` as the second account, with a comment that names `DEMO-0006`.

**You should see.** The job that waits is `apply privileged demo-privileged`, not `apply demo-privileged`, and it is in `mirror-privileged-demo`. Read the plan before you approve. Every role assignment and role definition is named, and nothing grants Owner that the ticket does not say.

**If not.** A production unit that declares an Owner assignment fails the `preflight` job of mirror-validate. Keep such records in the privileged unit.

### 14. Wave 5, the management group (section 4.6)

**What.** Deploy `demo-tenant-management-group`, which creates `mg-demo` under the Tenant Root Group.

**Where.** The PowerShell window, then GitHub in both windows.

**Do.** Create a branch.

```powershell
git switch --create enable-tenant-mg
```

Open `deploy/units.json` in an editor, set `"enabled": true` in the entry of `demo-tenant-management-group` and save the file. Then commit, push and open the pull request.

```powershell
git commit --all --message "Enable the management group unit"
git push -u test enable-tenant-mg
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-mg --title "Enable the management group unit" --body "Enable the management group unit"
```

Approve the pull request as the second account as in step 7, then merge it once every check is green.

```powershell
gh pr merge enable-tenant-mg --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
git switch master
git pull test master
```

Start the deployment. It needs no option, because `mg-demo` exists already and the plan holds no Create.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-management-group -f changeRef=DEMO-0007 -f reason="Wave 5, the management group" -f apply=true --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting job `apply privileged demo-tenant-management-group` in the environment `mirror-privileged-tenant` as the second account, with a comment that names `DEMO-0007`.

**You should see.** The apply job signs in as `id-mirror-govern-tenant` and the second check passes with `NoChange=1`.

**If not.** `AuthorizationFailed` on a tenant unit means the reader lacks Reader or Mirror What-If Reader Tenant on the Tenant Root Group. Run the second check of step 3.14, item 3.

### 15. Wave 6, the role assignment on the management group (section 4.7)

**What.** Deploy `demo-tenant-governance`, a Reader role assignment on `mg-demo`.

**Where.** The PowerShell window, then GitHub in both windows.

**Do.** Create a branch.

```powershell
git switch --create enable-tenant-governance
```

Open `deploy/units.json` in an editor, set `"enabled": true` in the entry of `demo-tenant-governance` and save the file. Then commit, push and open the pull request.

```powershell
git commit --all --message "Enable the management group governance unit"
git push -u test enable-tenant-governance
gh pr create --repo themasterishome/demo-bicep-deploy-test --base master --head enable-tenant-governance --title "Enable the management group governance unit" --body "Enable the management group governance unit"
```

Approve the pull request as the second account as in step 7, then merge it once every check is green.

```powershell
gh pr merge enable-tenant-governance --squash --delete-branch --repo themasterishome/demo-bicep-deploy-test
git switch master
git pull test master
```

Start a plan only. Its summary gives the ready command with the ID of the Reader role assignment on `mg-demo`.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, read the plan" --repo themasterishome/demo-bicep-deploy-test
```

Copy the ready command, replace `<ticket>` with `DEMO-0008` and `<why>` with `Wave 6, Reader on the management group`, add `--repo themasterishome/demo-bicep-deploy-test`, and run it. It has this shape.

```powershell
gh workflow run mirror-deploy-unit.yml --ref master -f unit=demo-tenant-governance -f changeRef=DEMO-0008 -f reason="Wave 6, Reader on the management group" -f apply=true -f allowCreate=ID --repo themasterishome/demo-bicep-deploy-test
```

Approve the waiting job `apply privileged demo-tenant-governance` in `mirror-privileged-tenant` as the second account, with a comment that names `DEMO-0008`.

**You should see.** The plan holds one Create, and the second check passes with `NoChange=1`.

**If not.** The plan of a tenant unit needs `mg-demo` to exist, so do step 14 first.

### 16. The drift check by hand, and the drift issue (section 4.9)

**What.** Run the drift check, change a tag outside the code, run it again and watch the `report` job open and keep the one drift issue.

**Where.** The PowerShell window, the Azure portal and GitHub.

**Do.** Wait for each run to finish before the next action, because a run started while another waits replaces the waiting one. To see the state of the runs, use this command.

```powershell
gh run list --workflow mirror-drift.yml --limit 3 --repo themasterishome/demo-bicep-deploy-test
```

1. Run the check once with everything in line.

   ```powershell
   gh workflow run mirror-drift.yml --ref master --repo themasterishome/demo-bicep-deploy-test
   ```

2. In the Azure portal, search for **Route tables**, select `rt-demo`, select **Tags** in its left menu, type the name `changedBy` and the value `portal`, and select **Apply**.
3. Run the check again with the command of action 1.
4. Open the **Issues** tab.
5. Run it a third time without any change.
6. Repair the drift by deploying the code's value back. Approve it as the second account, and wait for it to end.

   ```powershell
   gh workflow run mirror-deploy-unit.yml --ref master -f unit=rg-demo-routing -f changeRef=DEMO-0010 -f reason="Undo the drift on rt-demo" -f apply=true -f allowModify=/subscriptions/77488719-1168-4d53-af9a-f5c3bc9291d7/resourceGroups/rg-demo-routing/providers/Microsoft.Network/routeTables/rt-demo --repo themasterishome/demo-bicep-deploy-test
   ```

7. Run the check once more with the command of action 1.

**You should see.** After action 1, the run is green, and the `report` job prints `Drift report: every checked unit is clean, and no drift issue is open.` After action 3, the run is red, with `rg-demo-routing` as `DRIFT` and a Modify on `rt-demo` that removes the tag `changedBy`, and the `report` job prints `Drift report: issue #N is opened (drift).` The issue lists `rg-demo-routing` and links the run. After action 5, the `report` job prints `Drift report: issue #N is updated with this run, and its findings are the same (drift).` and adds no comment. After action 7, the run is green, and the `report` job prints `Drift report: every checked unit is clean, so issue #N is closed.` The issue is closed with a comment.

**If not.** A run that lists `demo-subscription` as `DRIFT` with NoRecord lines means that unit is enabled. The Visual Studio subscription also holds resource groups that are not part of the demo, for example WinServ2022, Automation, coach01 to coach29 and consultant01 to consultant13, and the demo code does not declare them. Leave those groups alone, and keep `demo-subscription` disabled as step 2 left it. A drift run that reports a resource group the code does not declare means the subscription holds another group. Read the summary for its name. A `report` job that fails means Issues are off (step 5). The second account gets a notification only when it watches the repository (the box under "Before you start").

### 17. Turn on the weekly start

**What.** Let mirror-drift start by itself every Monday at 05:00 UTC.

**Where.** The PowerShell window.

**Do.** Set the variable only when at least one unit is enabled, because a run with every unit disabled fails on purpose.

```powershell
gh variable set MIRROR_DRIFT_SCHEDULE_ENABLED --body true --repo themasterishome/demo-bicep-deploy-test
gh variable list --repo themasterishome/demo-bicep-deploy-test
```

**You should see.** The list shows `MIRROR_DRIFT_SCHEDULE_ENABLED` with the value `true`. The next Monday at 05:00 UTC the runs list of mirror-drift shows a run with the event `schedule`. The demo does not wait for it, because **Run workflow** runs the same two jobs.

**If not.** A weekly run that skipped every job means the variable is not `true` or the switch `MIRROR_PIPELINE_ENABLED` is off.

### 18. A change after the baseline, and a rollback (optional, sections 4.8 and 4.10)

**What.** Change a resource through a pull request, deploy it with `allowModify`, and roll it back.

**Where.** As in the steps above.

**Do.** Follow GUIDE.md section 4.8 and then 4.10. The merge of each pull request starts no run. The IDs for `allowModify` are in the preview's comment.

**You should see.** The second check ends with `NoChange=2` after the rule, and `nsg-demo` is NoChange again after the rollback.

**If not.** GUIDE.md section 5 lists the causes.

## Reading a failed run

1. In GitHub, open **Actions**, **mirror-deploy-unit**, the run, then the apply job. The gate step's log prints its exit code and the last lines of the deploy script. The codes are 0 for deployed and checked, 1 for refused by the gate, 2 for a set-up or identity problem and 3 for a deployment that ran and failed or whose second check failed. The job summary holds the plan verdict. The artifacts `evidence-deploy-UNIT` and `reviewed-plan-UNIT` hold the previews as JSON.
2. In Azure, open the deployment record `mirror-UNIT-COMMIT`. In the portal that is the subscription or the resource group, **Deployments**, the failed record, **Operation details**, which names the resource and the error code. From the CLI it is the first command below for a subscription unit, or the second for a resource group unit.

   ```powershell
   az deployment sub show --name mirror-UNIT-COMMIT --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.error
   az deployment group show --name mirror-UNIT-COMMIT --resource-group RESOURCE_GROUP --subscription 77488719-1168-4d53-af9a-f5c3bc9291d7 --query properties.error
   ```

3. The project's PIPELINE.md section 7 maps each message to its cause and fix, and REFERENCE.md section 4 is the rollback after exit 3. GUIDE.md section 5 lists the causes seen in the demo.
   A deployment can fail in Azure with `ResourceNotFound` although its plan showed NoChange. A preview never checks that the resource a setting points at still exists, such as the scale set of an autoscale setting. The other resources of that deployment keep their live values, and nothing is deleted. The fix is in the code. The resource whose target is gone becomes an existing reference, and the unit is planned and deployed again at the new commit.
4. A retry is a new run at the fixed commit. A re-run of the failed run never deploys.
5. For the drift check, open the **Issues** tab and the run the issue links. The `drift` artifact holds each unit's evidence.

## Removing an identity and its roles

Do it in this order, each delete by ID, so that nothing else is touched.

1. Take the lock off the identity group.
2. Delete each role assignment of the identity.
3. Delete the identity.
4. Delete the role definitions the set-up created.
5. Delete the policy assignment on the group.
6. Put the lock back.

On the GitHub side, delete the environment's variables, then the environment with its branch rule. GUIDE.md section 6 has the demo's commands, and PIPELINE.md 7.1 has the project's.

## Turning the demo off

1. Set the switch to `false`, so every job of every workflow is skipped.

   ```powershell
   gh variable set MIRROR_PIPELINE_ENABLED --body false --repo themasterishome/demo-bicep-deploy-test
   ```

2. Unset the weekly start, so the Monday run does not start when the switch is turned on again.

   ```powershell
   gh variable delete MIRROR_DRIFT_SCHEDULE_ENABLED --repo themasterishome/demo-bicep-deploy-test
   ```

3. Close any drift issue that is still open.

   ```powershell
   gh issue list --state open --repo themasterishome/demo-bicep-deploy-test
   ```

4. Switch the GitHub CLI back to `klaudiomarashi`.

   ```powershell
   gh auth switch --hostname github.com --user klaudiomarashi
   ```

5. Set the Azure CLI default back to the subscription you use day to day, and leave the resources of the demo in place unless you remove them with GUIDE.md section 6.

   ```powershell
   az account set --subscription SUBSCRIPTION_ID
   ```
