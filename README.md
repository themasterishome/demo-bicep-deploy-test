# demo-bicep-deploy

This repository runs a production deployment pipeline for Bicep on a small, made-up estate. The workflows, the
helper script, the deploy gate and the checks are the same files a production estate uses. Only the estate is
different. It has three units in one Azure subscription, and every resource in it is free.

The units, in the order they deploy:

| Wave | Unit | What it deploys |
|---|---|---|
| 0 | `pilot-empty-rg` | An empty template into the resource group `rg-demo-pilot`. It proves the sign-in, the roles, the approval and the evidence without touching a resource. |
| 1 | `rg-demo-network` | The network security group `nsg-demo` and the virtual network `vnet-demo` with one subnet, `snet-default`. |
| 2 | `rg-demo-routing` | The route table `rt-demo` and the application security group `asg-demo`. |

The resource groups themselves are declared in `infra/subscriptions/demo/main.bicep`, the unit `demo-subscription`,
which is deployed by hand. Every unit starts disabled in `deploy/units.json`.

GUIDE.md has the set-up and the demo, step by step: the identities, the GitHub settings, the first pull request,
the plan, the approval, the deployment, the second check and the drift check.

## What is where

| Path | What it holds |
|---|---|
| `infra/subscriptions/demo/` | The Bicep code of the estate. One file per resource group, every resource written out in full. |
| `deploy/units.json` | The deployment units, their order, the subscription and the identities that may deploy. |
| `deploy/boundaries.json` | The fields the gate accepts or stops on, the held resources and the expected Ignore records. All three lists are empty here. |
| `pipelines/pilot/empty-rg.bicep` | The empty template of the pilot unit. |
| `scripts/` | The deploy gate (`deploy-unit.ps1`), the preflight, the duplicate check, the drift check and the read-only sweeps. |
| `.github/workflows/` | The four workflows: `mirror-validate`, `mirror-pr`, `mirror-deploy-unit` and `mirror-drift`. |
| `.github/scripts/` | The pipeline's helper script and its offline tests. |

Nothing runs until the repository variable `MIRROR_PIPELINE_ENABLED` is set to `true`, as GUIDE.md shows.
