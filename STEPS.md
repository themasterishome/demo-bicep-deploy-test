# The set-up and the first deployments, step by step

This is the order in which the pipeline is set up and a unit is deployed for the first time, with the demo step next to the project step. GUIDE.md holds the demo's commands, PIPELINE.md of the project holds IT's. The numbers are the same in both, so you can practise a step here and then do it there. Every step below works as written in both documents, in this order, with the same commands.

## What the demo and the real set-up share

- The four workflows, the helper script and the gate script are the same files. Only the names of the units, the environments and the identities differ.
- The subject a workflow presents to Azure has the form `repo:OWNER@ID/REPOSITORY@ID:environment:NAME` for a repository created after GitHub's cut-off, and every federated credential names one environment. Step 3.16 reads the prefix, step 3.17 uses it, and the first sign-in proves it.
- The validate workflow signs in to Azure nowhere. Its first run needs no identity, so it is the first thing that runs after the switch.
- A Run workflow with `apply` on pauses between its plan and its write only because the environment has required reviewers. Without a reviewer the apply job runs at once. That is why step 3.11 comes before any identity exists, and why the one-account variant of GUIDE.md 3.0 names you as the reviewer of each deployment environment.
- A new identity can take a minute to be known to role assignments. If `az role assignment create` answers `PrincipalNotFound`, wait and run it again.
- The variables `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` live in each environment, never at repository level.
- A plan's record count is compared with the unit's own figure in the project's REFERENCE.md 7.11 for the pipeline's parameters file. The sweep figures there use the verify parameters file, which adds records, so the two can differ by those.
- A preview never checks that the thing a resource points at still exists. Before a unit's first deployment, every declared resource that targets another resource is checked against live, and one whose target is gone becomes an existing reference first. Otherwise the plan says NoChange and Azure refuses the write with `ResourceNotFound`.
- A second run of a unit at the same commit shows NoChange on the plan, the first check and the second check. That is the proof that the unit is a true mirror.
- Each deployment leaves a record named `mirror-UNIT-COMMIT` in the deployment history of its scope, a failed one included.

## The steps, in order

| Step | What it does | Demo (GUIDE.md) | Project (PIPELINE.md) |
|---|---|---|---|
| 3.1 to 3.2 | Check the GitHub plan and the approvers team | The two accounts | The enterprise and the two teams |
| 3.3 to 3.10 | The repository, CODEOWNERS, the push of the folder, the Actions settings, the three rulesets, secret scanning | The test repository, master | IT's repository, master |
| 3.11 | The environments, with reviewers and Prevent self-review on the deployment ones, and the branch rule `master` on every one but `mirror-reader` | 5 environments | 25 environments |
| 3.12 | The identity resource group, its lock, the secrets vault with public access off, its audit log, the private endpoint | `rg-demo-identities`, `kv-demo-mirror-secrets` | `rg-mirror-identities`, `kv-mirror-secrets` in the platform subscription |
| 3.13 | The custom roles, one file and one `az role definition create` each, then their IDs read back | 7 roles | 9 roles |
| 3.14 | The reader identity with Reader and Mirror What-If Reader, read back | `id-mirror-reader` | `id-mirror-reader` on 11 subscriptions and the Tenant Root Group |
| 3.15 | The deploy identity with Contributor, Resource Policy Contributor, Mirror Lock Writer and the conditioned Role Based Access Control Administrator, the govern identity with User Access Administrator and Mirror Deployment Operator, one `az role assignment create` per assignment, each read back | 3 identities | 23 identities |
| 3.16 | The subject prefix, `gh api repos/OWNER/REPOSITORY/actions/oidc/customization/sub` | | |
| 3.17 | One federated credential per environment, with the prefix plus `:environment:NAME`, the issuer and the audience, listed back | 5 credentials | 25 credentials |
| 3.18 to 3.19 | `AZURE_CLIENT_ID` and `AZURE_TENANT_ID` set per environment with `gh variable set --env`, then compared with the identities and their credentials | | |
| 3.20 | The repository variable `MIRROR_PIPELINE_ENABLED` set to `true` | | |
| 3.21 | The validate workflow on a push, five jobs green, no Azure sign-in | | |
| 3.22 | The drift workflow, the reader's first sign-in through `mirror-reader-dispatch` | | |
| 3.23 | The pilot, a plan with Run workflow and `apply` off, then a run with `apply` on, the reviewer's approval, the apply with its second check, the evidence artifact | `pilot-empty-rg` | `pilot-empty-rg` in `FDM-RSG-PILOT-UKS-001` |
| 4 | Every other unit, smallest first, each with a plan, an approval, the apply and the second check, the privileged units through `apply-privileged` and the smaller team | Waves 1 to 6 | Budgets and privileged units first, then the subscription units, FDMGroup group by group, the VPN gateways last in their window |

## Reading a failed run

1. In GitHub, open Actions, mirror-deploy-unit, the run, then the apply job. The gate step's log prints its exit code (0 deployed and checked, 1 the gate refused, 2 a set-up or identity problem, 3 the deployment ran and failed or its second check failed) and the last lines of the deploy script. The job summary holds the plan verdict. The artifacts `evidence-deploy-UNIT` and `reviewed-plan-UNIT` hold the previews as JSON.
2. In Azure, open the deployment record `mirror-UNIT-COMMIT`. In the portal that is the subscription or resource group, Deployments, the failed record, Operation details, which names the resource and the error code. From the CLI it is `az deployment sub show --name mirror-UNIT-COMMIT --subscription ID --query properties.error`, or `az deployment group show` with `--resource-group` for a resource group unit.
3. The project's PIPELINE.md section 7 maps each message to its cause and fix, and REFERENCE.md section 4 is the rollback after exit 3.
4. A retry is a new run at the fixed commit. A re-run of the failed run never deploys.

## Removing an identity and its roles

In this order, each delete by ID, and nothing else is touched: the lock off the identity group, each role assignment of the identity, the identity, the role definitions the setup created, the policy assignment on the group, the lock back. On the GitHub side, the environment's variables, the environment and its branch rule. GUIDE.md section 6 has the demo's commands, PIPELINE.md 7.1 the project's.
