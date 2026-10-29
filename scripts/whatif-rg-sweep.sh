#!/bin/bash
# Read-only measurement with a resource-group-scope what-if for the demo subscription, one RG at a time.
# Identity is verified for the target subscription before every Azure call (the CLI default may be another
# account). Nothing is deployed.
#
# Run it with bash, from Git Bash on Windows or a shell on Linux, from anywhere (the file is also marked
# executable in git, so scripts/whatif-rg-sweep.sh ... works on Linux as well).
#   bash scripts/whatif-rg-sweep.sh <outdir> [slug ...]      no slugs = every resource-groups/*.bicepparam
# A slug is a resource group file's name without .bicep, for example rg-demo-network or
# rg-demo-network.deploy-excluded. Only a resource group file with a .bicepparam next to it is previewed.
# Four files in that folder have none and are left out. The two *.vpn-gateways.bicep files are modules of
# network-gateways.bicep (unit demo-vpn-gateways), which is previewed at subscription scope on its own.
# networkwatchers.bicep is a module of main.bicep, previewed with the demo-subscription unit, and
# rg-demo-web.hash-excluded.bicep holds a name with '#' that what-if cannot preview.
# Then summarize the results.
#   pwsh -File scripts/summarize-whatif.ps1 -Dir <outdir> [-Detail]   (powershell -File on Windows PowerShell)
#
# Traps this script already handles: az emits CRLF on Windows (a stray \r in an RG name breaks
# the request URL with "400 Invalid URL"), and deployment names must not contain newlines.
set -u
set -o pipefail
SUB=6117ea3e-9dcc-49d8-8b4b-3616d8a5c252
# The expected sign-in and tenant come from the environment, so no account is written into the script.
# The script refuses to start, before any Azure call, when either is missing. A person runs a sweep by hand
# with their own sign-in name, typed out rather than read back from the CLI.
#   export MIRROR_EXPECTED_USER=<your sign-in name>   export MIRROR_TENANT_ID=<tenant ID>
USER_EXPECTED="${MIRROR_EXPECTED_USER:?set MIRROR_EXPECTED_USER to your own sign-in name, exactly as az account show --query user.name prints it}"
TENANT="${MIRROR_TENANT_ID:?set MIRROR_TENANT_ID to the tenant ID the estate subscriptions belong to}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
RGDIR="$REPO/infra/subscriptions/demo/resource-groups"
OUT="${1:?usage: bash scripts/whatif-rg-sweep.sh <outdir> [slug ...]}"; shift
# Resolve to an absolute path before the script cd's into the resource-group folder,
# so a relative <outdir> still points at the same place for status.txt and the JSON output.
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

check_identity() {
  local me tn
  me=$(az account show --subscription "$SUB" --query user.name -o tsv 2>/dev/null | tr -d '\r')
  tn=$(az account show --subscription "$SUB" --query tenantId -o tsv 2>/dev/null | tr -d '\r')
  if [ "$me" != "$USER_EXPECTED" ] || [ "$tn" != "$TENANT" ]; then
    echo "IDENTITY MISMATCH ($me / $tn), so the script refuses to call Azure" >&2
    return 1
  fi
}

check_identity || exit 1
# The identity check reads only the CLI's local sign-in cache, so an expired sign-in or a missing read permission
# first shows here. An empty or failed list would turn every resource group into NO-RG and still end in DONE, so the
# sweep stops with GROUP-LIST-FAIL instead. The reason is in rgs.err.
if ! az group list --subscription "$SUB" --query "[].name" -o tsv 2> "$OUT/rgs.err" | tr -d '\r' > "$OUT/rgs.txt" \
   || [ ! -s "$OUT/rgs.txt" ]; then
  echo "GROUP-LIST-FAIL" >> "$OUT/status.txt"
  echo "az group list failed or returned no resource group (see $OUT/rgs.err), so the sweep stops" >&2
  exit 1
fi

# A slug matches its live RG name case-insensitively, with '_' and '-' ignored (Rg_Demo_Web == rg-demo-web)
norm() { echo "$1" | tr -d '_-' | tr 'A-Z' 'a-z'; }

cd "$RGDIR" || exit 1
if [ $# -eq 0 ]; then
  set -- $(ls *.bicepparam | sed 's/\.bicepparam$//')
fi

for slug in "$@"; do
  # A slug given by hand is accepted with or without its .bicepparam extension.
  slug="${slug%.bicepparam}"
  if [ ! -f "$slug.bicepparam" ]; then echo "NO-PARAMS $slug" >> "$OUT/status.txt"; continue; fi
  rg=""
  while read -r n; do
    # <slug>.deploy-excluded is the second resource group file of the same resource group
    if [ "$(norm "$n")" = "$(norm "${slug%.deploy-excluded}")" ]; then rg="$n"; break; fi
  done < "$OUT/rgs.txt"
  if [ -z "$rg" ]; then echo "NO-RG $slug" >> "$OUT/status.txt"; continue; fi
  check_identity || { echo "IDENTITY-FAIL $slug" >> "$OUT/status.txt"; continue; }
  # With ProviderNoRbac the preview checks read permission only, so a person with Reader and Mirror What-If
  # Reader can run the sweep.
  # The default level would also demand write permission on every resource in the resource group file.
  az deployment group what-if --subscription "$SUB" --resource-group "$rg" --name "whatif-$(date +%s)" \
     --parameters "$slug.bicepparam" --result-format FullResourcePayloads --validation-level ProviderNoRbac \
     --no-pretty-print -o json \
     > "$OUT/$slug.json" 2> "$OUT/$slug.err"
  echo "$? $slug rg=$rg" >> "$OUT/status.txt"
done
echo "DONE" >> "$OUT/status.txt"
