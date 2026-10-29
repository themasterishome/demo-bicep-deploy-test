#!/bin/bash
# Read-only measurement with a subscription-scope what-if for the other subscriptions and one
# more unit:
#   demo-subscription             the demo subscription's resource groups (main.bicep with
#                                 parameters.bicepparam). The resources inside those groups are measured per
#                                 resource group with whatif-rg-sweep.sh instead, so they show here as Ignore.
# The three tenant-kind units are previewed by hand. Identity is checked before each Azure call. Nothing is
# deployed.
#
# For each subscription preview (the subscriptions in SUBS and demo-subscription) the sweep also lists the live resource groups and
# writes NO-RECORD <name> <group> to status.txt for a group the preview has no record of. Such a group is declared
# nowhere in the code, so no preview and no drift check would ever show its resources.
#
# Run it with bash, from Git Bash on Windows or a shell on Linux, as
#   bash scripts/whatif-sub-sweep.sh <outdir> [name ...]      no names = demo-subscription
# (the file is also marked executable in git, so scripts/whatif-sub-sweep.sh ... works on Linux as well).
# Then summarize with pwsh -File scripts/summarize-whatif.ps1 -Dir <outdir> [-Detail] (powershell -File on
# Windows PowerShell).
set -u
set -o pipefail
# The expected sign-in and tenant come from the environment, so no account is written into the script.
# The script refuses to start, before any Azure call, when either is missing. A person runs a sweep by hand
# with their own sign-in name, typed out rather than read back from the CLI.
#   export MIRROR_EXPECTED_USER=<your sign-in name>   export MIRROR_TENANT_ID=<tenant ID>
USER_EXPECTED="${MIRROR_EXPECTED_USER:?set MIRROR_EXPECTED_USER to your own sign-in name, exactly as az account show --query user.name prints it}"
TENANT="${MIRROR_TENANT_ID:?set MIRROR_TENANT_ID to the tenant ID the estate subscriptions belong to}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BASE="$REPO/infra/subscriptions"
OUT="${1:?usage: bash scripts/whatif-sub-sweep.sh <outdir> [name ...]}"; shift
# Resolve to an absolute path before the loop cd's into each subscription folder, so a
# relative <outdir> still points at the same place for status.txt and the JSON output.
mkdir -p "$OUT" && OUT="$(cd "$OUT" && pwd)" || exit 1
# Each preview compiles the code with the Bicep version the Azure CLI uses, and the CLI installs the newest release
# when none is installed. The code is measured with Bicep 0.48.1, so the sweep refuses any other version before its
# first Azure call and keeps what the CLI reported in bicep.txt. Change it together with BICEP_VERSION in the
# workflows.
az bicep version 2>&1 | tr -d '\r' > "$OUT/bicep.txt"
if ! grep -qE 'version 0\.48\.1( |$)' "$OUT/bicep.txt"; then
  echo "BICEP-VERSION-FAIL" >> "$OUT/status.txt"
  echo "az bicep version does not report Bicep 0.48.1 (see $OUT/bicep.txt), so the sweep stops" >&2
  exit 1
fi
declare -A SUBS=()
# The one more unit, as <subscription ID>|<parameters file under infra/subscriptions>|<compare groups>, the
# same subscriptions and files deploy/units.json gives them.
DEMO=6117ea3e-9dcc-49d8-8b4b-3616d8a5c252
declare -A EXTRA=(
  [demo-subscription]="$DEMO|demo/parameters.bicepparam|yes"
)
check_identity() {
  local me tn
  me=$(az account show --subscription "$1" --query user.name -o tsv 2>/dev/null | tr -d '\r')
  tn=$(az account show --subscription "$1" --query tenantId -o tsv 2>/dev/null | tr -d '\r')
  [ "$me" = "$USER_EXPECTED" ] && [ "$tn" = "$TENANT" ]
}
if [ $# -eq 0 ]; then
  set -- demo-subscription
fi
for s in "$@"; do
  # The name is checked first, because under set -u an unknown name would stop the script inside
  # check_identity instead of being recorded and skipped.
  if [ -n "${SUBS[$s]:-}" ]; then
    SUB="${SUBS[$s]}"; DIR="$BASE/$s"; GROUPS_CHECK=yes
    # parameters.verify.bicepparam, where present, also
    # switches on what the deployable parameters.bicepparam leaves out: the budgets, which have their own
    # unit, and the modules main.bicep calls from a group's .deploy-excluded.bicep file. So the sweep still
    # previews them. Each verify file must set only parameters main.bicep declares, or it does not build.
    PARAMS=parameters.bicepparam; [ -f "$DIR/parameters.verify.bicepparam" ] && PARAMS=parameters.verify.bicepparam
  elif [ -n "${EXTRA[$s]:-}" ]; then
    IFS='|' read -r SUB PFILE GROUPS_CHECK <<< "${EXTRA[$s]}"
    DIR="$BASE/$(dirname "$PFILE")"; PARAMS="$(basename "$PFILE")"
  else
    echo "UNKNOWN-SUB $s" >> "$OUT/status.txt"; continue
  fi
  check_identity "$SUB" || { echo "IDENTITY-FAIL $s" >> "$OUT/status.txt"; continue; }
  cd "$DIR" || { echo "NO-DIR $s" >> "$OUT/status.txt"; continue; }
  # --location must match deploymentLocation in deploy/units.json. Change both together.
  # With ProviderNoRbac the preview checks read permission only, so a person with Reader and Mirror What-If
  # Reader can run the sweep.
  az deployment sub what-if --subscription "$SUB" --location uksouth --name "whatif-$(date +%s)" \
     --parameters "$PARAMS" --result-format FullResourcePayloads --validation-level ProviderNoRbac \
     --no-pretty-print -o json \
     > "$OUT/$s.json" 2> "$OUT/$s.err"
  rc=$?
  echo "$rc $s" >> "$OUT/status.txt"
  # A subscription preview has one record per resource group main.bicep declares, with the group's own resource ID.
  # Each live group without that record is written as NO-RECORD. A failed or empty preview is not compared, because
  # every group would show. The live list is kept in <name>.groups.txt. A subscription can have no resource group
  # at all, so only a failed list is GROUP-LIST-FAIL, with the reason in <name>.groups.err.
  [ "$GROUPS_CHECK" = yes ] && [ "$rc" -eq 0 ] && [ -s "$OUT/$s.json" ] || continue
  check_identity "$SUB" || { echo "IDENTITY-FAIL $s groups" >> "$OUT/status.txt"; continue; }
  if ! az group list --subscription "$SUB" --query "[].name" -o tsv 2> "$OUT/$s.groups.err" | tr -d '\r' > "$OUT/$s.groups.txt"; then
    echo "GROUP-LIST-FAIL $s" >> "$OUT/status.txt"; continue
  fi
  while read -r g; do
    [ -n "$g" ] || continue
    grep -qiF "\"resourceId\": \"/subscriptions/$SUB/resourceGroups/$g\"" "$OUT/$s.json" || echo "NO-RECORD $s $g" >> "$OUT/status.txt"
  done < "$OUT/$s.groups.txt"
done
echo DONE >> "$OUT/status.txt"
