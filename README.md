# demo-bicep-deploy

This repository runs a production deployment pipeline for Bicep on a small, made-up estate. The workflows, the
helper script, the deploy gate and the checks are the same files a production estate uses. Only the estate is
different. It has seven units in one Azure subscription and one tenant, in the pipeline's two tiers, and every
resource in it is free.

The units, in the order they deploy:

| Wave | Unit | Tier | What it deploys |
|---|---|---|---|
| 0 | `pilot-empty-rg` | Production | An empty template into the resource group `rg-demo-pilot`. It proves the sign-in, the roles, the approval and the evidence without touching a resource. |
| 1 | `rg-demo-network` | Production | The network security group `nsg-demo` and the virtual network `vnet-demo` with one subnet, `snet-default`. Also a lock, a policy assignment and a Reader role assignment on the group. |
| 2 | `rg-demo-routing` | Production | The route table `rt-demo`, the application security group `asg-demo` and the Automation account `aa-demo-secrets` with its credential `demo-cred`. |
| 3 | `demo-subscription` | Production | The four resource groups and the Defender plan for virtual machines, declared in `infra/subscriptions/demo/main.bicep`. No deployment step enables it, and the drift check reads it when it is enabled. |
| 4 | `demo-privileged` | Privileged | The Owner role assignment on `rg-demo-network` and the custom role `Demo Reader Plus`. |
| 5 | `demo-tenant-management-group` | Privileged | The management group `mg-demo` under the Tenant Root Group. |
| 6 | `demo-tenant-governance` | Privileged | A Reader role assignment on `mg-demo`. |

The tier decides who deploys a unit. A production unit has no `tier` field in `deploy/units.json`. It deploys with the
identity `id-mirror-deploy-demo` after an approval in the environment `mirror-production-demo`. A privileged unit has
`"tier": "privileged"` and holds the role assignments of Owner, User Access Administrator and Role Based Access Control
Administrator and the custom role definitions. `demo-privileged` deploys with `id-mirror-govern-demo` after an approval in
`mirror-privileged-demo`. The two tenant units deploy with `id-mirror-govern-tenant` after an approval in
`mirror-privileged-tenant`. A fourth identity, `id-mirror-reader`, takes every preview and writes nothing. Every unit
is disabled when the demo starts. Step 2 of STEPS.md disables the seven units in the committed `deploy/units.json`.

GUIDE.md has the set-up and the demo, step by step: the identities and their roles, the GitHub settings, the first pull
request, the plan, the approval, the deployment, the second check and the drift check.

STEPS.md is the page to follow when you run the demo. It lists what must exist first and then every step in order, with the
exact command, what you should see and what to do if you do not. GUIDE.md holds the detail behind each step.

A merge into `master` starts no run and deploys nothing. The pull request's preview shows what the merge would change, and
a deployment starts only with **Run workflow** on `master`. The drift check, `mirror-drift`, starts the same way, and every
Monday at 05:00 UTC once the repository variable `MIRROR_DRIFT_SCHEDULE_ENABLED` is `true`. Its `report` job keeps one GitHub
issue up to date. It opens the issue when a run finds drift or cannot check a unit, adds a comment when the findings change
and closes the issue when a run finds every unit clean.

## What is where

| Path | What it holds |
|---|---|
| `infra/subscriptions/demo/` | The Bicep code of the subscription. One file per resource group, every resource written out in full, and `privileged.bicep` for the privileged unit. |
| `infra/tenant/` | The Bicep code of the two tenant units, the management group and the role assignment on it. |
| `deploy/units.json` | The deployment units, their tier and order, the subscription, the tenant and the people who may run the scripts by hand. |
| `deploy/boundaries.json` | The fields the gate accepts or stops on, the held resources and the expected Ignore records. Here it holds four inert boundaries on the private endpoint's zone group, two expected Ignore patterns and no hold. |
| `pipelines/pilot/empty-rg.bicep` | The empty template of the pilot unit. |
| `scripts/` | The deploy gate (`deploy-unit.ps1`), the preflight, the duplicate check, the drift check and the read-only sweeps. |
| `.github/workflows/` | The four workflows: `mirror-validate`, `mirror-pr`, `mirror-deploy-unit` and `mirror-drift`. |
| `.github/scripts/` | The pipeline's helper script and its offline tests. |

Nothing runs until the repository variable `MIRROR_PIPELINE_ENABLED` is set to `true`, as GUIDE.md shows.
